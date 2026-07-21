import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/models/session.dart';
import 'package:hooplab/services/recording_mode_storage.dart';
import 'package:hooplab/services/session_storage.dart';
import 'package:hooplab/utils/court.dart';
import 'package:hooplab/utils/court_calibration.dart';
import 'package:hooplab/utils/make_detector.dart';
import 'package:hooplab/utils/shot_detector.dart';
import 'package:hooplab/utils/shot_predictor.dart';
import 'package:hooplab/utils/shot_quality_evaluator.dart';
import 'package:hooplab/utils/shooting_form_analyzer.dart';
import 'package:hooplab/widgets/clean_video_player.dart';
import 'package:hooplab/widgets/trajectory_overlay.dart';
import 'package:hooplab/utils/trajectory_prediction.dart';
import 'package:hooplab/utils/shooting_pose_detector.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class ViewerPage extends StatefulWidget {
  final String? videoPath;
  const ViewerPage({super.key, this.videoPath});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  bool isAnalyzing = false;
  bool isUploading = false;
  String analysisStatus = '';
  late Clip clip;

  // Clean video player
  final GlobalKey<CleanVideoPlayerState> _videoPlayerKey = GlobalKey();
  Duration _currentVideoPosition = Duration.zero;
  Duration? _sliderSeekPosition; // Track slider position separately
  Timer? _sliderSeekDebouncer;
  StreamSubscription? analysisSubscription;
  YOLO? yoloModel;
  ShootingPoseDetector? poseDetector;
  int totalFramesToProcess = 0;
  int framesProcessed = 0;
  int totalDetections = 0;
  int shootingFramesDetected = 0; // Track frames with shooting motion
  int currentShotIndex = 0; // Track which shot we're viewing
  bool _isCancelled = false; // Track if extraction is cancelled
  Directory? _framesDir; // Temp dir for extracted frames, cleaned up after analysis

  // Locks onto the player who first held the ball; tracked via bbox IoU across
  // frames so pose detection stays on the same person after the ball leaves.
  Rect? _shooterBbox;

  // Detection settings. There is one prescribed recording angle (half-court /
  // sideline corner, camera aimed at the rim), so there is no mode to choose.
  bool showPoseSkeleton = false; // Toggle to show pose bones

  // Video handled by CleanVideoPlayer

  // Clean display - just show ball trajectory
  @override
  void initState() {
    super.initState();
    initializeYoloModel();
    initializeVideoPlayer();
    initializeClip();
  }

  // Video listener handled by CleanVideoPlayer

  // Video position tracking handled by CleanVideoPlayer callback


  Future<Map<String, dynamic>?> extractVideoFrames() async {
    try {
      debugPrint('🎬 Starting local frame extraction with video_thumbnail...');

      if (mounted) {
        setState(() {
          isUploading = true;
          analysisStatus = 'Extracting frames locally...';
        });
      }

      final videoFile = File(widget.videoPath!);
      if (!videoFile.existsSync()) {
        debugPrint('❌ Video file does not exist: ${widget.videoPath}');
        return null;
      }

      // Get actual video metadata using ProVideoEditor
      debugPrint('📊 Getting video metadata using ProVideoEditor...');

      final video = EditorVideo.file(widget.videoPath!);
      final metadata = await ProVideoEditor.instance.getMetadata(video);

      final videoDurationSeconds = metadata.duration.inSeconds.toDouble();
      final videoWidth = metadata.resolution.width.toInt();
      final videoHeight = metadata.resolution.height.toInt();

      debugPrint(
        '📊 Video metadata: ${videoWidth}x$videoHeight, ${videoDurationSeconds}s',
      );

      // Get video FPS using FFprobe
      debugPrint('📊 Getting video FPS with FFprobe...');
      final probeSession = await FFprobeKit.getMediaInformation(
        widget.videoPath!,
      );
      final mediaInfo = probeSession.getMediaInformation();

      // Extract FPS from media info
      double videoFPS = 30.0; // Default fallback
      if (mediaInfo != null) {
        final streams = mediaInfo.getStreams();
        for (final stream in streams) {
          final streamType = stream.getType();
          if (streamType == 'video') {
            final fpsString = stream.getAverageFrameRate();
            if (fpsString != null && fpsString.isNotEmpty) {
              // FPS comes as fraction like "30000/1001" or "30/1"
              final parts = fpsString.split('/');
              if (parts.length == 2) {
                final num = double.tryParse(parts[0]) ?? 30.0;
                final den = double.tryParse(parts[1]) ?? 1.0;
                videoFPS = num / den;
              }
            }
            break;
          }
        }
      }

      debugPrint('🎬 Video native FPS: ${videoFPS.toStringAsFixed(2)}');

      // Calculate frame extraction parameters using native FPS
      final videoDurationMs = metadata.duration.inMilliseconds;
      final targetFPS = videoFPS; // Use native FPS for perfect frame extraction
      final totalFramesToExtract = (videoDurationSeconds * targetFPS).ceil();
      final segmentDuration = videoDurationMs / totalFramesToExtract;

      debugPrint(
        '🎯 Extracting $totalFramesToExtract frames at native ${targetFPS.toStringAsFixed(2)}fps',
      );

      // Update progress
      if (mounted) {
        setState(() {
          analysisStatus = 'Extracting frames...';
          totalFramesToProcess = totalFramesToExtract;
          framesProcessed = 0;
        });
      }

      // Check if cancelled before expensive operation
      if (_isCancelled) {
        debugPrint('❌ Frame extraction cancelled');
        return null;
      }

      // Create temporary directory for frames
      _framesDir?.deleteSync(recursive: true); // Clean up any previous run
      _framesDir = Directory.systemTemp.createTempSync('hooplab_frames');
      final framesDir = _framesDir!;

      // Extract frames using FFmpeg (MUCH faster!)
      debugPrint('🚀 Extracting frames with FFmpeg at ${targetFPS}fps...');

      final outputPattern = p.join(framesDir.path, 'frame_%06d.jpg');

      // FFmpeg command: extract frames at target FPS
      final ffmpegCommand =
          '-i "${widget.videoPath}" -vf fps=$targetFPS -q:v 2 "$outputPattern"';

      debugPrint('📹 FFmpeg command: $ffmpegCommand');

      final session = await FFmpegKit.execute(ffmpegCommand);
      final returnCode = await session.getReturnCode();

      if (!ReturnCode.isSuccess(returnCode)) {
        debugPrint('❌ FFmpeg failed with return code: $returnCode');
        final output = await session.getOutput();
        debugPrint('FFmpeg output: $output');
        return null;
      }

      // Check if cancelled after extraction
      if (_isCancelled) {
        debugPrint('❌ Frame extraction cancelled after FFmpeg');
        return null;
      }

      // Get list of extracted frames
      final extractedFiles =
          framesDir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.jpg'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));

      debugPrint('🎉 FFmpeg extracted ${extractedFiles.length} frames');

      // Update total frames to actual count
      if (mounted) {
        setState(() {
          totalFramesToProcess = extractedFiles.length;
          framesProcessed = extractedFiles.length;
        });
      }

      // Build frame data from extracted files
      List<Map<String, dynamic>> frameData = [];

      for (int i = 0; i < extractedFiles.length; i++) {
        final frameFile = extractedFiles[i];
        final timestamp = i / targetFPS; // Time in seconds

        frameData.add({
          'frame_index': i,
          'extracted_index': i,
          'timestamp': timestamp,
          'filename': p.basename(frameFile.path),
          'path': frameFile.path,
          'file_size': await frameFile.length(),
        });

        if (i % 20 == 0) {
          debugPrint('✅ Frame $i at ${timestamp.toStringAsFixed(2)}s');
        }
      }

      final extractedFramesCount = frameData.length;
      debugPrint('🎉 Successfully extracted $extractedFramesCount frames');

      // Build metadata response similar to server format
      final responseMetadata = {
        'fps': videoDurationMs > 0
            ? (totalFramesToExtract * 1000.0) / videoDurationMs
            : 30.0,
        'total_frames': totalFramesToExtract,
        'extracted_frames': extractedFramesCount,
        'frame_interval': segmentDuration,
        'width': videoWidth,
        'height': videoHeight,
        'frames_directory': framesDir.path,
        'frames': frameData,
      };

      debugPrint(
        '📋 Frame extraction complete: $extractedFramesCount frames ready for analysis',
      );

      return responseMetadata;
    } catch (e) {
      debugPrint('❌ Error in local frame extraction: $e');
      if (mounted) {
        _showErrorDialog(
          'Frame Extraction Failed',
          'Failed to extract frames locally: $e',
        );
      }
      return null;
    } finally {
      if (mounted) {
        setState(() {
          isUploading = false;
          analysisStatus = '';
        });
      }
    }
  }

  void _showErrorDialog(String title, String message) {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _segmentShots() {
    if (clip.frames.isEmpty) return;

    // The detector (and every downstream scorer) is tuned to the camera rig the
    // user selected in Settings — tripod (level, true geometry) vs on-the-ground
    // (tilted up, foreshortened vertical). It segments on the ball's approach to
    // a rim, uses pose / "shoot" motion only to rescue ambiguous shots, and
    // falls back to motion windows so it never silently detects nothing.
    final mode = recordingModeNotifier.value;
    debugPrint('🏀 Detecting shots (${mode.storageKey} rig)...');
    final windows = ShotDetector.detect(
      clip.frames,
      config: ShotDetectorConfig.forMode(mode),
    );

    final shots = <Shot>[];
    for (final w in windows) {
      final shotFrames = clip.frames.sublist(w.startIndex, w.endIndex + 1);

      // Refine the target hoop per shot (direction-of-travel handles multi-hoop
      // scenes), falling back to the rim the detector locked onto.
      final targetHoop = _findTargetHoop(shotFrames) ?? w.hoop;

      final ballPositions = <Offset>[];
      for (final f in shotFrames) {
        final b = f.detections.where((d) => d.isBall).firstOrNull;
        if (b != null) ballPositions.add(b.center);
      }

      final shot = Shot(
        id: shots.length,
        frames: shotFrames,
        startTime: shotFrames.first.timestamp,
        endTime: shotFrames.last.timestamp,
        hoopPosition: targetHoop,
      );

      // Score only when we have a hoop and enough of an arc; otherwise the shot
      // is still surfaced (unscored) rather than dropped.
      if (targetHoop != null && ballPositions.length >= 3) {
        final hoopBBox =
            _computeHoopBBoxForTarget(shotFrames, targetHoop) ?? w.hoopBBox;
        _scoreShot(shot, ballPositions, targetHoop, hoopBBox, mode);
      }

      shots.add(shot);
    }

    setState(() {
      clip.shots = shots;
      currentShotIndex = shots.isNotEmpty ? 0 : -1;
    });

    debugPrint('🏀 Shot detection complete: ${shots.length} shot(s)');
  }

  /// Score a segmented shot: MAKE/MISS + accuracy from the model's "made"
  /// label (preferred) or rim-crossing geometry, plus an independent
  /// shooting-form quality score. Populates [shot] in place. Shared by both
  /// segmentation paths so scoring stays identical.
  void _scoreShot(
    Shot shot,
    List<Offset> ballPositions,
    Offset targetHoop,
    BoundingBox? hoopBBox,
    RecordingMode mode,
  ) {
    final hoopRadius = hoopBBox != null ? hoopBBox.width / 2 : 30.0;

    // Make/miss from several independent signals (made label, ball through the
    // rim opening, net-occlusion swish, rim crossing) so clean makes register
    // even when the Y-axis crossing geometry can't see them. This is the same
    // detection used live and is intentionally camera-independent — a make is a
    // make regardless of the rig — so no per-mode config is applied here.
    final finalResult = MakeDetector.detect(
      frames: shot.frames,
      ballPoints: ballPositions,
      rimCenter: targetHoop,
      rimBBox: hoopBBox,
      rimRadius: hoopRadius,
    );

    // Shooting-form quality, independent of whether the shot went in. The arc /
    // release-angle bands are shifted for the ground rig, whose upward tilt
    // makes every arc read flatter on screen.
    final quality = ShotQualityEvaluator.evaluateShotQuality(
      ballTrajectory: ballPositions,
      hoopPosition: targetHoop,
      hoopRadius: hoopRadius,
      profile: ShotArcProfile.forMode(mode),
    );

    // Body mechanics (arm angles + knee bend) from the shooter's pose track.
    // Measured in 3D so the same posture reads consistently regardless of where
    // on the court the shooter stands relative to the camera.
    final shooterPoses = <Pose>[];
    for (final f in shot.frames) {
      final p = f.poses;
      if (p != null && p.isNotEmpty) shooterPoses.add(p.first);
    }
    final form = ShootingFormAnalyzer.analyze(shooterPoses);

    shot.accuracy = finalResult.accuracy;
    final verdict = finalResult.made ? 'MAKE' : 'MISS';
    debugPrint('🏀 Shot ${shot.id}: $verdict via ${finalResult.method} '
        '(${finalResult.accuracy.toStringAsFixed(0)}%)');
    if (form.hasData) {
      debugPrint('🧍 Form: set=${form.setElbowAngle?.round()}° '
          'release=${form.releaseElbowAngle?.round()}° '
          'knee=${form.kneeBendAngle?.round()}° '
          'depth=${form.usedDepth} score=${form.postureScore?.round()}');
    }

    // Lead with body-mechanics cues (arm/knees — what the shooter can actually
    // change), then the ball-flight cues.
    final cues = <String>[...form.cues, ...quality.cues];

    // Blend the flight-quality score with the posture score when we have both.
    final hasFlight = quality.overallScore > 0;
    double? combinedScore;
    if (hasFlight && form.postureScore != null) {
      combinedScore = quality.overallScore * 0.5 + form.postureScore! * 0.5;
    } else if (hasFlight) {
      combinedScore = quality.overallScore;
    } else if (form.postureScore != null) {
      combinedScore = form.postureScore;
    }

    final feedbackText = cues.isNotEmpty ? cues.join(' • ') : null;
    shot.formScore = combinedScore;
    shot.feedback = feedbackText;
    shot.prediction =
        feedbackText != null ? '$verdict • $feedbackText' : verdict;

    // Release-time prediction: from the launch arc only (before the outcome is
    // visible), so we can tell the shooter "that's going in / that's short" the
    // instant the ball leaves the hand.
    final ballTimes = <double>[];
    final ballPts = <Offset>[];
    for (final f in shot.frames) {
      final b = f.detections.where((d) => d.isBall).firstOrNull;
      if (b != null) {
        ballPts.add(b.center);
        ballTimes.add(f.timestamp);
      }
    }
    final prediction = ShotPredictor.predictFromRelease(
      ballPoints: ballPts,
      timestamps: ballTimes,
      rimCenter: targetHoop,
      rimRadius: hoopRadius,
      config: ShotPredictorConfig.forMode(mode),
    );
    if (prediction.isKnown) {
      shot.predictedMake = prediction.willMake;
      shot.predictedAccuracy = prediction.accuracy;
    }

    // Shot location: find the shooter's on-floor position (foot anchor), then
    // place it on the court. Uncalibrated (Tier 0) uses the rim's known width as
    // a scale reference; a free-throw calibration can upgrade this later without
    // re-analysing, since the foot anchor is stored on the shot.
    final rimWidth = hoopBBox != null ? hoopBBox.width.abs() : hoopRadius * 2;
    final footAnchor =
        FootAnchorEstimator.estimate(shot.frames, rimWidth: rimWidth);
    shot.footAnchor = footAnchor;
    shot.rimWidth = rimWidth;
    final loc = CourtCalibration.none
        .locate(footAnchor, rimCenter: targetHoop, rimWidth: rimWidth);
    if (loc != null) {
      shot.courtPosition = loc.courtFeet;
      shot.zone = loc.zone.storageKey;
      debugPrint('📍 Shot ${shot.id} zone=${loc.zone.label} '
          'court=(${loc.courtFeet.dx.toStringAsFixed(1)}, '
          '${loc.courtFeet.dy.toStringAsFixed(1)})ft');
    }

    if (finalResult.confidence != ShotConfidence.high) {
      debugPrint(
        '⚠️ Shot ${shot.id} ${finalResult.confidence} confidence (${finalResult.method})',
      );
    }
  }

  /// Find the target hoop based on which hoop the ball gets closest to
  /// during the shot frames (handles multiple hoops in frame)
  Offset? _findTargetHoop(List<FrameData> shotFrames) {
    if (shotFrames.isEmpty) return null;

    // Collect all unique hoop positions across shot frames
    Map<String, List<Offset>> hoopPositions = {};

    for (final frame in shotFrames) {
      final hoopDetections = frame.detections
          .where((d) => d.isRim)
          .toList();

      for (final hoop in hoopDetections) {
        final hoopPos = Offset(hoop.bbox.centerX, hoop.bbox.centerY);

        // Group hoops by proximity (within 50 pixels = same hoop)
        bool foundGroup = false;
        for (final key in hoopPositions.keys) {
          final existingPositions = hoopPositions[key]!;
          final avgPos = _averageOffset(existingPositions);

          if ((hoopPos - avgPos).distance < 50) {
            existingPositions.add(hoopPos);
            foundGroup = true;
            break;
          }
        }

        if (!foundGroup) {
          hoopPositions['hoop_${hoopPositions.length}'] = [hoopPos];
        }
      }
    }

    if (hoopPositions.isEmpty) {
      debugPrint('❌ No hoops detected in shot frames');
      return null;
    }

    debugPrint('🎯 Found ${hoopPositions.length} unique hoop(s) in shot');

    // If only one hoop, easy choice
    if (hoopPositions.length == 1) {
      final positions = hoopPositions.values.first;
      return _averageOffset(positions);
    }

    // Multiple hoops: use rim crossing to identify which one the ball went
    // through. "Minimum proximity" fails here because a central background
    // hoop can have a small min-distance even if the ball never crossed it.
    //
    // Instead, run calculateShotAccuracyFromRimCrossing for each candidate.
    // A confirmed rim crossing (high/medium confidence) means the ball
    // actually passed through that hoop's plane. Low/insufficient confidence
    // means only a proximity estimate — ball never crossed that rim.
    final ballPositions = <Offset>[];
    for (final frame in shotFrames) {
      final ball = frame.detections
          .where((d) => d.isBall)
          .firstOrNull;
      if (ball != null) {
        ballPositions.add(Offset(ball.bbox.centerX, ball.bbox.centerY));
      }
    }

    if (ballPositions.length >= 3) {
      Offset? bestHoop;
      double bestAccuracy = -1;
      bool bestHasRimCrossing = false;

      for (final entry in hoopPositions.entries) {
        final avgHoopPos = _averageOffset(entry.value);
        final bbox = _computeHoopBBoxForTarget(shotFrames, avgHoopPos);
        final radius = bbox != null ? bbox.width / 2 : 30.0;

        final result = TrajectoryPredictor.calculateShotAccuracyFromRimCrossing(
          ballPoints: List.from(ballPositions),
          hoopPosition: avgHoopPos,
          hoopBBox: bbox,
          hoopRadius: radius,
          // No frames: static bbox, no dynamic tracking during hoop selection
        );

        final hasRimCrossing = result.confidence == ShotConfidence.high ||
            result.confidence == ShotConfidence.medium;

        debugPrint(
          '  Hoop at (${avgHoopPos.dx.toInt()}, ${avgHoopPos.dy.toInt()}): '
          'accuracy=${result.accuracy.toStringAsFixed(1)}% '
          'confidence=${result.confidence} rimCrossing=$hasRimCrossing',
        );

        // Priority: confirmed rim crossing > proximity estimate.
        // Within the same tier, higher accuracy wins.
        if (!bestHasRimCrossing && hasRimCrossing) {
          bestHasRimCrossing = true;
          bestAccuracy = result.accuracy;
          bestHoop = avgHoopPos;
        } else if (bestHasRimCrossing == hasRimCrossing &&
            result.accuracy > bestAccuracy) {
          bestAccuracy = result.accuracy;
          bestHoop = avgHoopPos;
        }
      }

      // Only trust the rim-crossing result if it was a confirmed crossing.
      // A proximity estimate (no confirmed crossing) is unreliable from the
      // diagonal corner angle — fall through to direction-of-travel instead.
      if (bestHoop != null && bestHasRimCrossing) {
        debugPrint(
          '✅ Target hoop selected by rim crossing: '
          '(${bestHoop.dx.toInt()}, ${bestHoop.dy.toInt()})',
        );
        return bestHoop;
      }

      // TIER 2: Direction of travel.
      // The ball always moves toward the target hoop regardless of view angle.
      // Dot product of (travel direction) · (vector from last ball pos to hoop)
      // is positive for the target hoop and negative (or smaller) for hoops
      // behind/beside the ball's path.  This is the same logic used in the
      // trajectory overlay to draw the red ring on the correct hoop.
      final firstBall = ballPositions.first;
      final lastBall = ballPositions.last;
      final travelDx = lastBall.dx - firstBall.dx;
      final travelDy = lastBall.dy - firstBall.dy;
      final travelMagSq = travelDx * travelDx + travelDy * travelDy;

      if (travelMagSq > 100) {
        Offset? dirHoop;
        double bestDirAlignment = double.negativeInfinity;

        for (final entry in hoopPositions.entries) {
          final avgHoopPos = _averageOffset(entry.value);
          final toHoopDx = avgHoopPos.dx - lastBall.dx;
          final toHoopDy = avgHoopPos.dy - lastBall.dy;
          final alignment = travelDx * toHoopDx + travelDy * toHoopDy;

          debugPrint(
            '  Direction check — hoop at (${avgHoopPos.dx.toInt()}, '
            '${avgHoopPos.dy.toInt()}): alignment=${alignment.toStringAsFixed(0)}',
          );

          if (alignment > bestDirAlignment) {
            bestDirAlignment = alignment;
            dirHoop = avgHoopPos;
          }
        }

        if (dirHoop != null && bestDirAlignment > 0) {
          debugPrint(
            '✅ Target hoop selected by direction of travel: '
            '(${dirHoop.dx.toInt()}, ${dirHoop.dy.toInt()})',
          );
          return dirHoop;
        }
      }

      // TIER 3: Endpoint proximity.
      // Direction was ambiguous (ball barely moved). Fall back to which hoop
      // the ball's final positions are closest to.
      final endStart = (ballPositions.length * 0.7).round().clamp(
        0,
        ballPositions.length - 1,
      );
      final endPositions = ballPositions.sublist(endStart);

      String? endpointHoopKey;
      double endpointClosestAvg = double.infinity;

      for (final hoopKey in hoopPositions.keys) {
        final avgHoopPos = _averageOffset(hoopPositions[hoopKey]!);
        double sumDist = 0;
        for (final pos in endPositions) {
          sumDist += (pos - avgHoopPos).distance;
        }
        final avgDist = sumDist / endPositions.length;

        debugPrint(
          '  Endpoint check — hoop at (${avgHoopPos.dx.toInt()}, '
          '${avgHoopPos.dy.toInt()}): avg endpoint dist=${avgDist.toStringAsFixed(1)}px',
        );

        if (avgDist < endpointClosestAvg) {
          endpointClosestAvg = avgDist;
          endpointHoopKey = hoopKey;
        }
      }

      if (endpointHoopKey != null) {
        final targetPos = _averageOffset(hoopPositions[endpointHoopKey]!);
        debugPrint(
          '✅ Target hoop selected by endpoint proximity: '
          '(${targetPos.dx.toInt()}, ${targetPos.dy.toInt()})',
        );
        return targetPos;
      }
    }

    // TIER 4: All-frame minimum proximity — last resort fallback.
    debugPrint('⚠️ Falling back to all-frame proximity-based hoop selection');
    Map<String, double> minDistances = {};

    for (final hoopKey in hoopPositions.keys) {
      final hoopPositionsList = hoopPositions[hoopKey]!;
      final avgHoopPos = _averageOffset(hoopPositionsList);
      double minDistance = double.infinity;

      for (final frame in shotFrames) {
        final ballDetections = frame.detections
            .where((d) => d.isBall)
            .toList();

        if (ballDetections.isNotEmpty) {
          final ballPos = Offset(
            ballDetections.first.bbox.centerX,
            ballDetections.first.bbox.centerY,
          );
          final distance = (ballPos - avgHoopPos).distance;
          if (distance < minDistance) minDistance = distance;
        }
      }
      minDistances[hoopKey] = minDistance;
    }

    String? targetHoopKey;
    double closestDistance = double.infinity;

    for (final entry in minDistances.entries) {
      debugPrint(
        '  Hoop ${entry.key}: min distance = ${entry.value.toStringAsFixed(1)}px',
      );
      if (entry.value < closestDistance) {
        closestDistance = entry.value;
        targetHoopKey = entry.key;
      }
    }

    if (targetHoopKey != null) {
      final targetHoopPositions = hoopPositions[targetHoopKey]!;
      final targetPos = _averageOffset(targetHoopPositions);
      debugPrint(
        '✅ Target hoop selected by proximity: '
        '(${targetPos.dx.toInt()}, ${targetPos.dy.toInt()})',
      );
      return targetPos;
    }

    return null;
  }

  /// Compute the average bounding box for a specific hoop directly from a
  /// list of frames. Filters to detections within 100px of [targetHoopPos]
  /// so background hoops don't pollute the result.
  BoundingBox? _computeHoopBBoxForTarget(
    List<FrameData> frames,
    Offset targetHoopPos,
  ) {
    double sumX1 = 0, sumY1 = 0, sumX2 = 0, sumY2 = 0;
    int count = 0;

    for (final frame in frames) {
      for (final d in frame.detections) {
        if (!d.isRim) {
          continue;
        }

        final center = Offset(d.bbox.centerX, d.bbox.centerY);
        if ((center - targetHoopPos).distance > 100) continue;

        sumX1 += d.bbox.x1;
        sumY1 += d.bbox.y1;
        sumX2 += d.bbox.x2;
        sumY2 += d.bbox.y2;
        count++;
      }
    }

    if (count == 0) return null;
    return BoundingBox(
      x1: sumX1 / count,
      y1: sumY1 / count,
      x2: sumX2 / count,
      y2: sumY2 / count,
    );
  }

  /// Calculate average of a list of offsets
  Offset _averageOffset(List<Offset> offsets) {
    if (offsets.isEmpty) return Offset.zero;

    double sumX = 0, sumY = 0;
    for (final offset in offsets) {
      sumX += offset.dx;
      sumY += offset.dy;
    }

    return Offset(sumX / offsets.length, sumY / offsets.length);
  }

  /// Get average hoop bounding box for a frame range
  /// Check if current shot has ended and auto-advance to next shot
  void _checkShotAutoAdvance(Duration position) {
    if (clip.shots.isEmpty ||
        currentShotIndex < 0 ||
        currentShotIndex >= clip.shots.length) {
      return;
    }

    final currentShot = clip.shots[currentShotIndex];
    final currentTimeSec = position.inMilliseconds / 1000.0;

    // Check if we've passed the end of the current shot (with small buffer)
    if (currentTimeSec > currentShot.endTime + 0.5) {
      // Move to next shot
      final nextIndex =
          (currentShotIndex + 1) %
          clip.shots.length; // Loop back to 0 after last shot

      setState(() {
        currentShotIndex = nextIndex;
      });

      // Seek to start of next shot
      final nextShot = clip.shots[nextIndex];
      //safeSeekTo(Duration(milliseconds: (nextShot.startTime * 1000).round()));
      _videoPlayerKey.currentState?.seekTo(
        Duration(milliseconds: (nextShot.startTime * 1000).round()),
      );

      debugPrint(
        '🔄 Auto-advanced to shot ${nextIndex + 1}/${clip.shots.length}',
      );
    }
  }

  void _deleteCurrentShot() {
    if (clip.shots.isEmpty ||
        currentShotIndex < 0 ||
        currentShotIndex >= clip.shots.length) {
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Shot'),
        content: Text(
          'Delete shot ${currentShotIndex + 1}? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() {
                clip.shots.removeAt(currentShotIndex);

                // Adjust currentShotIndex after deletion
                if (clip.shots.isEmpty) {
                  currentShotIndex = -1;
                } else if (currentShotIndex >= clip.shots.length) {
                  currentShotIndex = clip.shots.length - 1;
                }

                debugPrint(
                  '🗑️ Shot deleted. ${clip.shots.length} shots remaining',
                );
              });
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void initializeClip() {
    clip = Clip(
      id: "1",
      name: "Test Clip",
      videoPath: widget.videoPath!,
      frames: [],
    );
  }

  void initializeVideoPlayer() {
    // Video player initialization handled by CleanVideoPlayer widget
  }

  void initializeYoloModel() async {
    try {
      yoloModel = YOLO(
        modelPath: 'best_float16',
        task: YOLOTask.detect,
        useMultiInstance: true,
      );
      await yoloModel!.loadModel();
      debugPrint('✅ YOLO model loaded successfully');
    } catch (e, st) {
      debugPrint('❌ Error initializing YOLO: $e');
      debugPrint('$st');
    }

    try {
      poseDetector = ShootingPoseDetector(
        options: PoseDetectorOptions(
          mode: PoseDetectionMode.single,
          model: PoseDetectionModel.base,
        ),
      );
      debugPrint('✅ ML Kit pose detector initialized');
    } catch (e, st) {
      debugPrint('❌ Error initializing pose detector: $e');
      debugPrint('$st');
    }
  }

  @override
  void dispose() {
    _isCancelled = true; // Cancel any ongoing frame extraction
    _sliderSeekDebouncer?.cancel();
    analysisSubscription?.cancel();
    poseDetector?.dispose();
    try {
      _framesDir?.deleteSync(recursive: true);
    } catch (_) {}
    super.dispose();
  }

  Rect? _selectShooterBbox(List<Rect> personBoxes, Offset? ballPosition) {
    if (personBoxes.isEmpty) return _shooterBbox;

    if (_shooterBbox == null) {
      // Not locked yet — wait for ball to appear, then pick the person whose
      // box contains (or is closest to) the ball.
      if (ballPosition == null) return null;
      Rect? best;
      double bestDist = double.infinity;
      for (final person in personBoxes) {
        if (person.contains(ballPosition)) {
          _shooterBbox = person;
          debugPrint('🔒 Shooter locked (ball inside person box)');
          return person;
        }
        final d = (person.center - ballPosition).distance;
        if (d < bestDist) {
          bestDist = d;
          best = person;
        }
      }
      // Only lock if the ball is near the person (roughly within 1 person-width)
      if (best != null && bestDist < best.width * 1.5) {
        _shooterBbox = best;
        debugPrint('🔒 Shooter locked (nearest to ball, ${bestDist.toStringAsFixed(0)}px)');
        return best;
      }
      return null;
    }

    // Already locked — pick person box with highest IoU to previous shooter box.
    Rect? best;
    double bestIoU = 0;
    for (final person in personBoxes) {
      final iou = _iou(person, _shooterBbox!);
      if (iou > bestIoU) {
        bestIoU = iou;
        best = person;
      }
    }
    if (best != null && bestIoU > 0.1) {
      _shooterBbox = best;
      return best;
    }
    // No overlap — likely brief occlusion. Keep last-known bbox.
    return _shooterBbox;
  }

  double _iou(Rect a, Rect b) {
    final ix1 = a.left > b.left ? a.left : b.left;
    final iy1 = a.top > b.top ? a.top : b.top;
    final ix2 = a.right < b.right ? a.right : b.right;
    final iy2 = a.bottom < b.bottom ? a.bottom : b.bottom;
    final iw = ix2 - ix1;
    final ih = iy2 - iy1;
    if (iw <= 0 || ih <= 0) return 0;
    final inter = iw * ih;
    final union = a.width * a.height + b.width * b.height - inter;
    return union <= 0 ? 0 : inter / union;
  }

  Future<({String path, Offset origin})?> _cropAroundBbox(
    String framePath,
    Rect bbox,
  ) async {
    try {
      final bytes = await File(framePath).readAsBytes();
      final decoded = img.decodeJpg(bytes);
      if (decoded == null) return null;

      // Pad 30% around the person so MLKit sees head + feet + limbs at full extension.
      const padRatio = 0.3;
      final padX = bbox.width * padRatio;
      final padY = bbox.height * padRatio;
      final left = (bbox.left - padX).clamp(0, decoded.width.toDouble()).toInt();
      final top = (bbox.top - padY).clamp(0, decoded.height.toDouble()).toInt();
      final right = (bbox.right + padX).clamp(0, decoded.width.toDouble()).toInt();
      final bottom = (bbox.bottom + padY).clamp(0, decoded.height.toDouble()).toInt();
      final cropW = right - left;
      final cropH = bottom - top;
      if (cropW < 32 || cropH < 32) return null;

      final cropped = img.copyCrop(
        decoded,
        x: left,
        y: top,
        width: cropW,
        height: cropH,
      );
      final jpg = img.encodeJpg(cropped, quality: 90);

      final dir = _framesDir?.path ?? Directory.systemTemp.path;
      final outPath = p.join(dir, 'shooter_crop.jpg');
      await File(outPath).writeAsBytes(jpg, flush: true);
      return (path: outPath, origin: Offset(left.toDouble(), top.toDouble()));
    } catch (e) {
      debugPrint('❌ Crop failed: $e');
      return null;
    }
  }

  void _showAnalysisCompleteSnackbar() {
    if (!mounted) return;
    final total = clip.shots.length;
    final makes = clip.shots
        .where((s) => s.prediction?.startsWith('MAKE') ?? false)
        .length;
    final misses = total - makes;
    final pct = total > 0 ? (makes / total * 100).toStringAsFixed(0) : '—';

    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        content: Text(
          total == 0
              ? 'Analysis complete · no shots detected'
              : 'Analysis complete · $total shot${total == 1 ? '' : 's'} · '
                  '$makes made · $misses missed · $pct%',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        action: total == 0
            ? null
            : SnackBarAction(
                label: 'Save',
                onPressed: _promptSaveSession,
              ),
      ),
    );
  }

  SavedShot _toSavedShot(Shot shot) {
    // shot.prediction is "MAKE • feedback…" or "MISS • feedback…"; strip to bare verdict.
    String? verdict;
    if (shot.prediction != null) {
      final p = shot.prediction!;
      if (p.startsWith('MAKE')) {
        verdict = 'MAKE';
      } else if (p.startsWith('MISS')) {
        verdict = 'MISS';
      }
    }
    return SavedShot(
      id: shot.id,
      startTime: shot.startTime,
      endTime: shot.endTime,
      prediction: verdict,
      accuracy: shot.accuracy,
      formScore: shot.formScore,
      feedback: shot.feedback,
      predictedMake: shot.predictedMake,
      predictedAccuracy: shot.predictedAccuracy,
      ballTrajectory: shot.ballTrajectory,
      hoopPosition: shot.hoopPosition,
      footAnchor: shot.footAnchor,
      courtPosition: shot.courtPosition,
      zone: shot.zone,
      rimWidth: shot.rimWidth,
    );
  }

  String _defaultSessionName() {
    final now = DateTime.now();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final min = now.minute.toString().padLeft(2, '0');
    final ampm = now.hour < 12 ? 'AM' : 'PM';
    return '${months[now.month - 1]} ${now.day} · $hour:$min $ampm';
  }

  Future<void> _promptSaveSession() async {
    if (clip.shots.isEmpty) return;

    final makes = clip.shots.where((s) => s.prediction?.startsWith('MAKE') ?? false).length;
    final total = clip.shots.length;
    final controller = TextEditingController(text: _defaultSessionName());

    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Save session'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$makes / $total made'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Session name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(dialogCtx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogCtx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty) return;

    final now = DateTime.now();
    final session = Session(
      id: now.microsecondsSinceEpoch.toString(),
      createdAt: now,
      updatedAt: now,
      videoPath: widget.videoPath ?? '',
      name: name,
      shots: clip.shots.map(_toSavedShot).toList(),
    );
    await SessionStorage.save(session);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved "$name" · $makes/$total made'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  ShootingPoseResult _shiftPoseResult(ShootingPoseResult r, Offset origin) {
    Pose shift(Pose p) => Pose(
      landmarks: {
        for (final e in p.landmarks.entries)
          e.key: PoseLandmark(
            type: e.value.type,
            x: e.value.x + origin.dx,
            y: e.value.y + origin.dy,
            z: e.value.z,
            likelihood: e.value.likelihood,
          ),
      },
    );
    return ShootingPoseResult(
      isShootingMotion: r.isShootingMotion,
      poses: r.poses.map(shift).toList(),
      shootingConfidence: r.shootingConfidence,
      shootingPose: r.shootingPose == null ? null : shift(r.shootingPose!),
      shootingDuration: r.shootingDuration,
    );
  }

  Stream<FrameData> analyzeVideoFrames() async* {
    if (yoloModel == null) {
      debugPrint('❌ YOLO model not loaded');
      return;
    }

    final Map<String, dynamic>? frameResponse = await extractVideoFrames();

    if (frameResponse == null || _isCancelled) {
      debugPrint("❌ Frame extraction failed or cancelled");
      return;
    }

    /*
         data['frame_data'].append({
                'frame_index': frame_idx,
                'extracted_index': extracted_count,
                'timestamp': timestamp,
                'frame_bytes': frame_bytes
            })

              data = {
        "fps": fps,
        "total_frames": total_frames,
        "extracted_frames": 0,
        "frame_interval": frame_interval,
        "width": width,
        "height": height,
        'frame_data': []
    }
          */

    // Video metadata handled by CleanVideoPlayer

    for (int idx = 0; idx < frameResponse['extracted_frames']; idx += 1) {
      // Check if cancelled during analysis
      if (_isCancelled) {
        debugPrint('❌ Analysis cancelled during YOLO processing');
        return;
      }

      try {
        final frameNumber = idx;
        final frameInfo = frameResponse['frames'][idx];
        final preciseTimestampMs = (frameInfo['timestamp'] as double) * 1000;

        debugPrint(
          '\n🎯 Processing frame #$frameNumber at ${preciseTimestampMs}ms...',
        );

        // Use the direct path from frame info
        final framePath = frameInfo['path'] as String;
        final frameBytes = await File(framePath).readAsBytes();

        // Set total frames on first iteration and reset progress counter
        if (idx == 0) {
          totalFramesToProcess = frameResponse['extracted_frames'];
          framesProcessed = 0;
        }

        // Run YOLO ball/hoop detection first to get ball position
        final results = await yoloModel!.predict(
          frameBytes,
          confidenceThreshold: 0.25,
        );

        // Extract ball position + all person boxes from YOLO results
        Offset? ballPosition;
        final personBoxes = <Rect>[];
        if (results.containsKey('boxes') && results['boxes'] is List) {
          final boxes = results['boxes'] as List;
          for (var box in boxes) {
            if (box is Map) {
              final className =
                  box['class_id']?.toString() ?? box['class']?.toString() ?? '';
              final x1 = (box['x1'] ?? 0).toDouble();
              final y1 = (box['y1'] ?? 0).toDouble();
              final x2 = (box['x2'] ?? 0).toDouble();
              final y2 = (box['y2'] ?? 0).toDouble();
              final lower = className.toLowerCase();
              if (lower.contains('ball')) {
                ballPosition ??= Offset((x1 + x2) / 2, (y1 + y2) / 2);
              } else if (lower.contains('person')) {
                personBoxes.add(Rect.fromLTRB(x1, y1, x2, y2));
              }
            }
          }
        }

        // Pick the shooter box for this frame — lock on first ball-holding
        // frame, then track by IoU so we stay on the same player.
        final Rect? shooterBbox = _selectShooterBbox(personBoxes, ballPosition);

        // Run MLKit pose on a padded crop around the shooter — full frames
        // downscale the player too small for the model to resolve keypoints.
        // Landmarks come back in crop-local space; shift by crop origin so the
        // overlay draws on top of the player in full-frame coordinates.
        ShootingPoseResult? poseResult;
        if (shooterBbox != null && poseDetector != null) {
          final crop = await _cropAroundBbox(framePath, shooterBbox);
          if (crop != null) {
            final inputImage = InputImage.fromFilePath(crop.path);
            poseResult = _shiftPoseResult(
              await poseDetector!.detectShootingPose(inputImage),
              crop.origin,
            );
            try {
              await File(crop.path).delete();
            } catch (_) {}
          }
        }

        debugPrint(
          '🏃 Pose detection: shooterLocked=${_shooterBbox != null}, '
          'isShootingMotion=${poseResult?.isShootingMotion ?? false}, '
          'confidence=${poseResult?.shootingConfidence.toStringAsFixed(2) ?? "0.00"}',
        );

        // Parse detections from YOLO results
        final frameDetections = <Detection>[];
        int detectionsInFrame = 0;

        try {
          if (results.containsKey('boxes') && results['boxes'] is List) {
            final boxes = results['boxes'] as List;
            debugPrint('📦 Found ${boxes.length} boxes in results');

            for (var box in boxes) {
              if (box is Map) {
                final x1 = (box['x1'] ?? 0).toDouble();
                final y1 = (box['y1'] ?? 0).toDouble();
                final x2 = (box['x2'] ?? 0).toDouble();
                final y2 = (box['y2'] ?? 0).toDouble();
                final confidence = (box['confidence'] ?? 0).toDouble();
                final className =
                    box['class_id']?.toString() ??
                    box['class']?.toString() ??
                    'unknown';

                if (confidence > 0.3) {
                  final detection = Detection(
                    trackId: detectionsInFrame,
                    bbox: BoundingBox(x1: x1, y1: y1, x2: x2, y2: y2),
                    confidence: confidence,
                    timestamp: preciseTimestampMs / 1000.0,
                    label: className,
                  );
                  frameDetections.add(detection);
                  detectionsInFrame++;

                  debugPrint(
                    '✅ Detection: $className (${(confidence * 100).toStringAsFixed(1)}%) at ($x1, $y1, $x2, $y2)',
                  );
                }
              }
            }
          }
        } catch (e) {
          debugPrint('❌ Error parsing results: $e');
        }

        totalDetections += detectionsInFrame;
        framesProcessed++;

        debugPrint(
          '📊 Frame #$frameNumber summary: $detectionsInFrame detections (Total: $totalDetections)',
        );

        // The model has a dedicated "shoot" class — a direct, essentially-free
        // shooting signal (it comes out of the same YOLO pass). Fuse it with
        // ML Kit pose so shot segmentation still fires when the skeleton is
        // unclear. This can only ever ADD shooting frames, never remove them.
        double shootConfidence = 0.0;
        for (final d in frameDetections) {
          if (d.isShoot && d.confidence > shootConfidence) {
            shootConfidence = d.confidence;
          }
        }
        final poseShooting = poseResult?.isShootingMotion ?? false;
        final poseConfidence = poseResult?.shootingConfidence ?? 0.0;
        final isShooting = poseShooting || shootConfidence >= 0.45;
        final shootingConfidence =
            poseConfidence > shootConfidence ? poseConfidence : shootConfidence;

        final frameData = FrameData(
          frameNumber: frameNumber,
          timestamp: preciseTimestampMs / 1000.0,
          detections: frameDetections,
          isShootingMotion: isShooting,
          shootingConfidence: shootingConfidence,
          poses: poseResult?.poses, // Store pose data for visualization
        );

        yield frameData;
      } catch (e) {
        debugPrint('❌ Error processing frame at ${e}ms: $e');
      }
    }

    debugPrint('\n🏁 Analysis complete:');
    debugPrint('  Frames processed: $framesProcessed');
    debugPrint('  Total detections: $totalDetections');
    debugPrint(
      '  Average detections per frame: ${totalDetections / framesProcessed.clamp(1, double.infinity)}',
    );

    // Clean up temp frames directory
    try {
      _framesDir?.deleteSync(recursive: true);
      _framesDir = null;
    } catch (e) {
      debugPrint('⚠️ Failed to clean up temp frames: $e');
    }
  }

  Widget _buildVideoPlayerWithOverlay() {
    // Determine which frames to show in overlay
    List<FrameData> overlayFrames = [];
    Shot? currentShot;

    if (clip.shots.isNotEmpty &&
        currentShotIndex >= 0 &&
        currentShotIndex < clip.shots.length) {
      // Show only current shot's trajectory
      currentShot = clip.shots[currentShotIndex];
      overlayFrames = currentShot.frames;
    } else if (clip.frames.isNotEmpty) {
      // Fallback to all frames if no shots segmented
      overlayFrames = clip.frames;
    }

    return CleanVideoPlayer(
      key: _videoPlayerKey,
      videoPath: widget.videoPath!,
      onPositionChanged: (position) {
        if (!mounted) return;

        // Schedule the setState call for the next frame to avoid calling during build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _currentVideoPosition = position;
            });

            // Auto-advance to next shot when current shot ends
            _checkShotAutoAdvance(position);
          }
        });
      },
      overlay: overlayFrames.isNotEmpty
          ? TrajectoryOverlay(
              frames: overlayFrames,
              currentVideoPosition: _currentVideoPosition,
              videoSize:
                  _videoPlayerKey.currentState?.videoSize ??
                  const Size(1920, 1080),
              showPoseSkeleton: showPoseSkeleton,
              predictedMake: currentShot?.predictedMake,
              predictedAccuracy: currentShot?.predictedAccuracy,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Shot Analysis"),
        elevation: 0,
        actions: [
          // Pose skeleton toggle (only show after analysis with pose data)
          if (clip.frames.isNotEmpty && clip.frames.any((f) => f.poses != null))
            IconButton(
              icon: Icon(
                showPoseSkeleton
                    ? Icons.accessibility
                    : Icons.accessibility_outlined,
                color: showPoseSkeleton ? Colors.green : Colors.white,
              ),
              onPressed: () {
                setState(() {
                  showPoseSkeleton = !showPoseSkeleton;
                });
              },
              tooltip: showPoseSkeleton
                  ? 'Hide Pose Skeleton'
                  : 'Show Pose Skeleton',
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Video player — fixed height so it's always clearly visible
              // and never gets crushed by the controls below.
              SizedBox(
                width: double.infinity,
                height: (MediaQuery.of(context).size.height * 0.42)
                    .clamp(220.0, 480.0),
                child: ColoredBox(
                  color: Colors.black,
                  child: _buildVideoPlayerWithOverlay(),
                ),
              ),

              // Control panel — scrolls so it never overflows the screen.
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Camera-rig reminder (only before analysis). Analysis is
                    // tuned to the rig selected in Settings, so show which one
                    // is active and how to set it up.
                    if (!isAnalyzing && clip.frames.isEmpty) ...[
                      ValueListenableBuilder<RecordingMode>(
                        valueListenable: recordingModeNotifier,
                        builder: (context, mode, _) => Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.blue.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.videocam_outlined,
                                  color: Colors.blue, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Analyzing for: ${mode.label}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      mode.setupTip,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    // Analysis button
                    if (!isAnalyzing && clip.frames.isEmpty)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () async {
                            setState(() {
                              isAnalyzing = true;
                              _isCancelled = false; // Reset cancellation flag
                              clip.frames.clear();
                              clip.shots.clear();
                              totalDetections = 0;
                              shootingFramesDetected = 0;
                              framesProcessed = 0;
                              currentShotIndex = 0;
                              _shooterBbox = null; // Re-lock shooter each run
                            });

                            final subscription = analyzeVideoFrames().listen(
                              (frameData) {
                                if (mounted) {
                                  setState(() {
                                    clip.frames.add(frameData);
                                    // totalDetections and framesProcessed already
                                    // incremented in analyzeVideoFrames()
                                    if (frameData.isShootingMotion) {
                                      shootingFramesDetected++;
                                    }
                                    analysisStatus =
                                        'Analyzing... $framesProcessed/$totalFramesToProcess';
                                  });
                                }
                              },
                              onDone: () {
                                if (mounted) {
                                  setState(() {
                                    isAnalyzing = false;
                                  });
                                  _segmentShots();
                                  _showAnalysisCompleteSnackbar();
                                }
                              },
                              onError: (error) {
                                debugPrint('❌ Analysis error: $error');
                                if (mounted) {
                                  setState(() {
                                    isAnalyzing = false;
                                  });
                                }
                              },
                            );
                            analysisSubscription = subscription;
                          },
                          icon: const Icon(Icons.analytics),
                          label: const Text("Analyze Shot"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1565C0),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),

                    // Analysis in progress
                    if (isAnalyzing) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.blue.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Analyzing frames...',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                        ),
                                      ),
                                      Text(
                                        '$framesProcessed frames • $totalDetections detections',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    _isCancelled = true;
                                    analysisSubscription?.cancel();
                                    setState(() {
                                      isAnalyzing = false;
                                    });
                                  },
                                  child: const Text("Stop"),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // Pose detection indicator
                            Row(
                              children: [
                                Icon(
                                  Icons.accessibility_new,
                                  size: 16,
                                  color: shootingFramesDetected > 0
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  shootingFramesDetected > 0
                                      ? 'Pose detection: $shootingFramesDetected shooting frames detected 🏀'
                                      : 'Pose detection: active (no shooting motion yet)',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: shootingFramesDetected > 0
                                        ? Colors.green[700]
                                        : Colors.grey[600],
                                    fontWeight: shootingFramesDetected > 0
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Analysis complete - show results
                    if (!isAnalyzing && clip.frames.isNotEmpty) ...[
                      // Multi-shot navigation and prediction
                      if (clip.shots.isNotEmpty) ...[
                        _SessionSummary(shots: clip.shots),
                        const SizedBox(height: 12),
                        // Shot selector with navigation
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.grey[100],
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.grey[300]!,
                              width: 1,
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  IconButton(
                                    onPressed: currentShotIndex > 0
                                        ? () {
                                            setState(() {
                                              currentShotIndex--;
                                              // Seek to shot start
                                              _videoPlayerKey.currentState?.seekTo(
                                                Duration(
                                                  milliseconds:
                                                      (clip
                                                                  .shots[currentShotIndex]
                                                                  .startTime *
                                                              1000)
                                                          .round(),
                                                ),
                                              );
                                            });
                                          }
                                        : null,
                                    icon: const Icon(Icons.arrow_back),
                                    color: const Color(0xFF1565C0),
                                    iconSize: 28,
                                  ),
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              'Shot ${currentShotIndex + 1} of ${clip.shots.length}',
                                              style: const TextStyle(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            // Delete button
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete_outline,
                                                size: 20,
                                              ),
                                              color: Colors.red,
                                              padding: EdgeInsets.zero,
                                              constraints:
                                                  const BoxConstraints(),
                                              onPressed: () {
                                                _deleteCurrentShot();
                                              },
                                              tooltip: 'Delete this shot',
                                            ),
                                          ],
                                        ),
                                        Text(
                                          '${clip.shots[currentShotIndex].startTime.toStringAsFixed(1)}s - ${clip.shots[currentShotIndex].endTime.toStringAsFixed(1)}s',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    onPressed:
                                        currentShotIndex < clip.shots.length - 1
                                        ? () {
                                            setState(() {
                                              currentShotIndex++;
                                              // Seek to shot start
                                              _videoPlayerKey.currentState?.seekTo(
                                                Duration(
                                                  milliseconds:
                                                      (clip
                                                                  .shots[currentShotIndex]
                                                                  .startTime *
                                                              1000)
                                                          .round(),
                                                ),
                                              );
                                            });
                                          }
                                        : null,
                                    icon: const Icon(Icons.arrow_forward),
                                    color: const Color(0xFF1565C0),
                                    iconSize: 28,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),

                              // Current shot result: verdict + accuracy + form
                              if (clip.shots[currentShotIndex].accuracy != null)
                                _ShotResultCard(
                                  shot: clip.shots[currentShotIndex],
                                ),
                            ],
                          ),
                        ),
                      ],
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                setState(() {
                                  clip.frames.clear();
                                  clip.shots.clear();
                                  totalDetections = 0;
                                  shootingFramesDetected = 0;
                                  framesProcessed = 0;
                                  currentShotIndex = 0;
                                  _shooterBbox = null;
                                });
                              },
                              icon: const Icon(Icons.refresh),
                              label: const Text("Re-analyze"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey[600],
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: clip.shots.isEmpty
                                  ? null
                                  : _promptSaveSession,
                              icon: const Icon(Icons.save_rounded),
                              label: const Text("Save Session"),
                              style: ElevatedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Compact one-line analysis footnote.
                      Text(
                        '${clip.frames.length} frames · $totalDetections detections'
                        '${shootingFramesDetected > 0 ? " · $shootingFramesDetected shooting" : ""}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.5),
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),

                    // Video position and controls
                    if (clip.frames.isNotEmpty) ...[
                      // Video seek slider
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            Slider(
                              value:
                                  (_sliderSeekPosition ?? _currentVideoPosition)
                                      .inMilliseconds
                                      .toDouble()
                                      .clamp(
                                        0.0,
                                        (_videoPlayerKey
                                                .currentState
                                                ?.duration
                                                .inMilliseconds ?? 0)
                                            .toDouble(),
                                      ),
                              max:
                                  (_videoPlayerKey
                                          .currentState
                                          ?.duration
                                          .inMilliseconds ?? 0)
                                      .toDouble(),
                              onChanged: (value) {
                                final newPosition = Duration(
                                  milliseconds: value.round(),
                                );

                                // Update slider position immediately for responsive UI
                                setState(() {
                                  _sliderSeekPosition = newPosition;
                                });

                                // Debounce the actual seek to avoid overwhelming video decoder
                                _sliderSeekDebouncer?.cancel();
                                _sliderSeekDebouncer = Timer(
                                  const Duration(milliseconds: 150),
                                  () {
                                    _videoPlayerKey.currentState?.seekTo(
                                      newPosition,
                                    );
                                    setState(() {
                                      _sliderSeekPosition =
                                          null; // Clear override
                                    });
                                  },
                                );
                              },
                              onChangeEnd: (value) {
                                // Immediately seek when user releases slider
                                _sliderSeekDebouncer?.cancel();
                                final newPosition = Duration(
                                  milliseconds: value.round(),
                                );
                                _videoPlayerKey.currentState?.seekTo(
                                  newPosition,
                                );
                                setState(() {
                                  _sliderSeekPosition = null;
                                });
                              },
                              activeColor: const Color(0xFF1565C0),
                              inactiveColor: Colors.grey,
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '${_currentVideoPosition.inSeconds}s',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  '${(_videoPlayerKey.currentState?.duration.inSeconds ?? 0)}s',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            onPressed: () {
                              // Skip back 1 second
                              final newPosition = Duration(
                                milliseconds:
                                    (_currentVideoPosition.inMilliseconds -
                                            1000)
                                        .clamp(0, double.infinity)
                                        .round(),
                              );
                              _videoPlayerKey.currentState?.seekTo(newPosition);
                            },
                            icon: const Icon(Icons.replay_10),
                            color: const Color(0xFF1565C0),
                            iconSize: 32,
                            tooltip: 'Back 1s',
                          ),

                          IconButton(
                            onPressed: () {
                              final playerState = _videoPlayerKey.currentState;
                              //playerState?.play();
                              if (playerState != null) {
                                if (playerState.isPlaying) {
                                  playerState.pause();
                                } else {
                                  playerState.play();
                                }
                              }
                            },
                            icon:
                                _videoPlayerKey.currentState?.isPlaying == true
                                ? const Icon(Icons.pause)
                                : const Icon(Icons.play_arrow),
                            color: const Color(0xFF1565C0),
                            iconSize: 40,
                          ),
                          IconButton(
                            onPressed: () {
                              // Skip forward 1 second
                              final maxDuration =
                                  _videoPlayerKey
                                      .currentState
                                      ?.duration
                                      .inMilliseconds ??
                                  10000;
                              final newPosition = Duration(
                                milliseconds:
                                    (_currentVideoPosition.inMilliseconds +
                                            1000)
                                        .clamp(0, maxDuration.toDouble())
                                        .round(),
                              );
                              _videoPlayerKey.currentState?.seekTo(newPosition);
                            },
                            icon: const Icon(Icons.forward_10),
                            color: const Color(0xFF1565C0),
                            iconSize: 32,
                            tooltip: 'Forward 1s',
                          ),
                          IconButton(
                            onPressed: () {
                              _videoPlayerKey.currentState?.seekTo(
                                Duration.zero,
                              );
                            },
                            icon: const Icon(Icons.restart_alt),
                            color: const Color(0xFF1565C0),
                            iconSize: 32,
                            tooltip: 'Restart',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                  ),
                ),
              ),
            ],
          ),
          // Loading overlay when analyzing
          if (isAnalyzing || isUploading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Card(
                  margin: const EdgeInsets.all(32),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Show linear progress bar if we have total frames
                        if (totalFramesToProcess > 0) ...[
                          SizedBox(
                            width: 200,
                            child: LinearProgressIndicator(
                              value: framesProcessed / totalFramesToProcess,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '$framesProcessed / $totalFramesToProcess frames',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[700],
                            ),
                          ),
                        ] else
                          const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          analysisStatus.isNotEmpty
                              ? analysisStatus
                              : 'Extracting and analyzing frames...',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Result card for a single shot: MAKE/MISS verdict, accuracy %, and the
/// shooting-form feedback. Color scales red→green with accuracy.
class _ShotResultCard extends StatelessWidget {
  final Shot shot;
  const _ShotResultCard({required this.shot});

  @override
  Widget build(BuildContext context) {
    final accuracy = shot.accuracy ?? 0;
    final tint = Color.lerp(Colors.red, Colors.green, accuracy / 100)!;
    final isMake = shot.isMake;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [tint.withValues(alpha: 0.2), tint.withValues(alpha: 0.05)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint, width: 3),
      ),
      child: Column(
        children: [
          // At-release prediction, shown first — it's what we knew the moment
          // the ball left the shooter's hands.
          if (shot.predictedMake != null) ...[
            _predictionBadge(shot.predictedMake!, shot.predictedAccuracy),
            const SizedBox(height: 12),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isMake ? Icons.check_circle : Icons.cancel,
                color: isMake ? Colors.green : Colors.red,
                size: 22,
              ),
              const SizedBox(width: 6),
              Text(
                isMake ? 'MAKE' : 'MISS',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                  color: isMake ? Colors.green : Colors.red,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${accuracy.toStringAsFixed(1)}%',
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.bold,
              color: tint,
            ),
          ),
          Text(
            'Shot accuracy',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          if (shot.predictedMake != null) ...[
            const SizedBox(height: 6),
            Text(
              _agreementText(shot.predictedMake!, isMake),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: Colors.grey[700],
              ),
            ),
          ],
          if (shot.formScore != null) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.sports_basketball, size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                Text(
                  'Form ${shot.formScore!.toStringAsFixed(0)}/100',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (shot.feedback != null) ...[
              const SizedBox(height: 8),
              _FormCues(feedback: shot.feedback!),
            ],
          ],
        ],
      ),
    );
  }

  Widget _predictionBadge(bool predictedMake, double? predictedAccuracy) {
    final color = predictedMake ? Colors.green : Colors.orange;
    final pct = predictedAccuracy != null
        ? ' · ${predictedAccuracy.round()}%'
        : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.my_location, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            'At release: ${predictedMake ? "GOING IN" : "OFF TARGET"}$pct',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// A short note on whether the release prediction matched the outcome.
  String _agreementText(bool predictedMake, bool made) {
    if (predictedMake == made) {
      return made
          ? 'Predicted make — clean release'
          : 'Predicted miss — release was off';
    }
    return predictedMake
        ? 'Good release — rimmed out'
        : 'Got the bounce — release looked off';
  }
}

/// Renders the ` • `-joined form feedback as a left-aligned bulleted list so
/// longer, specific coaching cues stay readable.
class _FormCues extends StatelessWidget {
  final String feedback;
  const _FormCues({required this.feedback});

  @override
  Widget build(BuildContext context) {
    final cues = feedback
        .split(' • ')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    if (cues.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cue in cues)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5, right: 6),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[500],
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    cue,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: Colors.grey[800],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SessionSummary extends StatelessWidget {
  final List<Shot> shots;
  const _SessionSummary({required this.shots});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final total = shots.length;
    final makes = shots
        .where((s) => s.prediction?.startsWith('MAKE') ?? false)
        .length;
    final misses = total - makes;
    final pct = total > 0 ? makes / total * 100 : 0.0;
    final pctColor = total == 0
        ? cs.onSurface.withValues(alpha: 0.4)
        : pct >= 50
            ? Colors.green
            : pct >= 30
                ? Colors.orange
                : Colors.red;

    // Release-prediction accuracy across the session (predicted vs actual).
    final graded = shots
        .where((s) => s.predictedMake != null && s.accuracy != null)
        .toList();
    final correct = graded
        .where((s) => s.predictedMake == s.isMake)
        .length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _SummaryStat(label: 'Shots', value: '$total'),
              _SummaryStat(label: 'Makes', value: '$makes', color: Colors.green),
              _SummaryStat(label: 'Misses', value: '$misses', color: Colors.red),
              _SummaryStat(
                label: 'Make %',
                value: '${pct.toStringAsFixed(0)}%',
                color: pctColor,
              ),
            ],
          ),
          if (graded.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.my_location, size: 13, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  'Release prediction: $correct/${graded.length} correct'
                  ' (${(correct / graded.length * 100).toStringAsFixed(0)}%)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _SummaryStat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: color ?? theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
          ),
        ),
      ],
    );
  }
}
