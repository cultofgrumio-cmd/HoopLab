import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/utils/shot_quality_evaluator.dart';
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
import 'package:path/path.dart' as p;

class ViewerPage extends StatefulWidget {
  final String? videoPath;
  ViewerPage({super.key, this.videoPath});

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
  int curFrame = 0;
  int currentShotIndex = 0; // Track which shot we're viewing
  bool _isCancelled = false; // Track if extraction is cancelled
  Directory? _framesDir; // Temp dir for extracted frames, cleaned up after analysis

  // Detection mode settings
  bool useCourtMode =
      false; // false = backboard mode, true = court/sideways mode
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
        '📊 Video metadata: ${videoWidth}x${videoHeight}, ${videoDurationSeconds}s',
      );

      // Get video FPS using FFprobe
      debugPrint('📊 Getting video FPS with FFprobe...');
      final probeSession = await FFprobeKit.getMediaInformation(
        widget.videoPath!,
      );
      final mediaInfo = await probeSession.getMediaInformation();

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
        '📋 Frame extraction complete: ${extractedFramesCount} frames ready for analysis',
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

  List<Detection> _getCurrentFrameDetections(int frameIndex) {
    if (clip.frames.isEmpty ||
        frameIndex < 0 ||
        frameIndex >= clip.frames.length) {
      return [];
    }

    return clip.frames[frameIndex].detections;
  }

  // Keep the old method for compatibility
  List<Detection> getCurrentFrameDetections() {
    return _getCurrentFrameDetections(curFrame);
  }

  void _segmentShots() {
    if (clip.frames.isEmpty) return;

    // User explicitly chose court mode - force pose-based detection
    if (useCourtMode) {
      final hasPoseData = clip.frames.any((f) => f.isShootingMotion);
      if (hasPoseData) {
        debugPrint('🏀 Starting POSE-BASED shot segmentation (Court Mode)...');
        _segmentShotsWithPose();
      } else {
        debugPrint('⚠️ Court mode selected but no shooting motion detected!');
        debugPrint(
          '📊 Pose detection may need adjustment or video has no visible person shooting',
        );
        // Still try legacy as fallback
        _segmentShotsLegacy();
      }
      return;
    }

    // Backboard mode - use legacy detection
    debugPrint(
      '🏀 Starting shot segmentation with up/down regions (Backboard Mode)...',
    );
    _segmentShotsLegacy();
  }

  /// Legacy shot segmentation using ball trajectory only
  void _segmentShotsLegacy() {
    final shots = <Shot>[];
    List<FrameData> currentShotFrames = [];
    List<Offset> currentShotBallPositions = [];

    bool inUpRegion = false;
    bool inDownRegion = false;
    int upFrameIndex = 0;
    int downFrameIndex = 0;

    int consecutiveNoBallFrames = 0;

    // Find hoop position
    Offset? hoopPosition = _findHoopPosition();

    if (hoopPosition == null) {
      debugPrint('❌ No hoop detected, cannot segment shots');
      return;
    }

    // Compute average hoop bbox so region thresholds scale with actual video
    final hoopBBox = _getAverageHoopBBox(0, clip.frames.length - 1, null);
    debugPrint(
      '📐 Hoop bbox for region detection: ${hoopBBox?.width.toStringAsFixed(1) ?? "default"}w '
      'x ${hoopBBox?.height.toStringAsFixed(1) ?? "default"}h',
    );

    for (int i = 0; i < clip.frames.length; i++) {
      final frame = clip.frames[i];
      final ballDetections = frame.detections
          .where((d) => d.label.toLowerCase().contains('ball'))
          .toList();

      if (ballDetections.isNotEmpty) {
        final ball = ballDetections.first;
        final ballPos = Offset(ball.bbox.centerX, ball.bbox.centerY);

        consecutiveNoBallFrames = 0;
        currentShotBallPositions.add(ballPos);

        // Check if ball enters "UP" region (around backboard, above hoop)
        if (!inUpRegion &&
            _isInUpRegion(ballPos, hoopPosition, ball.bbox, hoopBox: hoopBBox)) {
          inUpRegion = true;
          upFrameIndex = i;
          currentShotFrames = [frame];
          debugPrint('🏀 Ball in UP region at frame $i (${frame.timestamp}s)');
        }

        // If already in up region, keep adding frames
        if (inUpRegion && !inDownRegion) {
          currentShotFrames.add(frame);
        }

        // Check if ball enters "DOWN" region (below the net)
        if (inUpRegion &&
            !inDownRegion &&
            _isInDownRegion(ballPos, hoopPosition, ball.bbox, hoopBox: hoopBBox)) {
          inDownRegion = true;
          downFrameIndex = i;
          debugPrint(
            '🏀 Ball in DOWN region at frame $i (${frame.timestamp}s)',
          );
        }

        // Shot complete: went from UP → DOWN
        if (inUpRegion && inDownRegion && upFrameIndex < downFrameIndex) {
          if (currentShotFrames.length >= 10) {
            // Select the hoop the ball was actually aimed at (handles
            // multi-hoop scenes where a background hoop was detected first).
            final targetHoop =
                _findTargetHoop(currentShotFrames) ?? hoopPosition;

            final shot = Shot(
              id: shots.length,
              frames: List.from(currentShotFrames),
              startTime: currentShotFrames.first.timestamp,
              endTime: currentShotFrames.last.timestamp,
              hoopPosition: targetHoop,
            );

            // Calculate shot accuracy
            final ballTrajectory = currentShotBallPositions;
            if (ballTrajectory.length >= 3) {
              // Get hoop bounding box filtered to the target hoop only
              final hoopBBox = _getAverageHoopBBox(
                upFrameIndex,
                downFrameIndex,
                null,
                targetHoopPosition: targetHoop,
              );

              // Calculate accuracy percentage with dynamic hoop tracking
              final accuracyResult =
                  TrajectoryPredictor.calculateShotAccuracyFromRimCrossing(
                    ballPoints: ballTrajectory,
                    hoopPosition: targetHoop,
                    hoopBBox: hoopBBox,
                    hoopRadius: hoopBBox != null ? hoopBBox.width / 2 : 30.0,
                    frames: currentShotFrames,
                  );

              // "made" label from model overrides rim crossing when present
              final madeResult = TrajectoryPredictor.checkMadeDetection(
                currentShotFrames,
                targetHoop,
              );

              final finalResult = madeResult ?? accuracyResult;
              shot.accuracy = finalResult.accuracy;
              shot.prediction = finalResult.accuracy > 50.0 ? "MAKE" : "MISS";

              // Log confidence level
              if (finalResult.confidence != ShotConfidence.high) {
                debugPrint(
                  '⚠️ Shot ${shot.id} has ${finalResult.confidence} confidence: ${finalResult.reason}',
                );
              }
            }

            shots.add(shot);
            debugPrint(
              '✅ Shot ${shot.id} completed: Accuracy=${shot.accuracy?.toStringAsFixed(1) ?? "N/A"}% '
              '(${currentShotFrames.length} frames)',
            );
          }

          // Reset for next shot
          inUpRegion = false;
          inDownRegion = false;
          currentShotFrames = [];
          currentShotBallPositions = [];
        }
      } else {
        consecutiveNoBallFrames++;

        // Reset if no ball detected for too long
        if (consecutiveNoBallFrames > 15) {
          inUpRegion = false;
          inDownRegion = false;
          currentShotFrames = [];
          currentShotBallPositions = [];
        }
      }
    }

    setState(() {
      clip.shots = shots;
      currentShotIndex = shots.isNotEmpty ? 0 : -1;
    });

    debugPrint(
      '🏀 Legacy shot segmentation complete: ${shots.length} shots detected',
    );
  }

  /// Enhanced shot segmentation using pose detection data
  /// Only tracks ball trajectory when someone is in shooting motion
  void _segmentShotsWithPose() {
    final shots = <Shot>[];
    List<FrameData> currentShotFrames = [];
    List<Offset> currentShotBallPositions = [];

    bool inShootingMotion = false;
    int shootingStartFrame = 0;
    int consecutiveNonShootingFrames = 0;

    // Find hoop position
    Offset? hoopPosition = _findHoopPosition();

    if (hoopPosition == null) {
      debugPrint('❌ No hoop detected, cannot segment shots');
      return;
    }

    for (int i = 0; i < clip.frames.length; i++) {
      final frame = clip.frames[i];

      // Check if someone is in shooting motion
      if (frame.isShootingMotion && frame.shootingConfidence > 0.6) {
        consecutiveNonShootingFrames = 0;

        // Start tracking a new shot
        if (!inShootingMotion) {
          inShootingMotion = true;
          shootingStartFrame = i;
          currentShotFrames = [];
          currentShotBallPositions = [];
          debugPrint(
            '🏃 Shooting motion started at frame $i (${frame.timestamp}s)',
          );
        }

        // Add frame to current shot
        currentShotFrames.add(frame);

        // Track ball position during shooting motion
        final ballDetections = frame.detections
            .where((d) => d.label.toLowerCase().contains('ball'))
            .toList();

        if (ballDetections.isNotEmpty) {
          final ball = ballDetections.first;
          final ballPos = Offset(ball.bbox.centerX, ball.bbox.centerY);
          currentShotBallPositions.add(ballPos);
        }
      } else {
        // Not in shooting motion
        if (inShootingMotion) {
          consecutiveNonShootingFrames++;

          // Keep adding frames for a bit after shooting motion ends
          // (to capture the full arc and landing)
          if (consecutiveNonShootingFrames <= 20) {
            currentShotFrames.add(frame);

            // Continue tracking ball
            final ballDetections = frame.detections
                .where((d) => d.label.toLowerCase().contains('ball'))
                .toList();

            if (ballDetections.isNotEmpty) {
              final ball = ballDetections.first;
              final ballPos = Offset(ball.bbox.centerX, ball.bbox.centerY);
              currentShotBallPositions.add(ballPos);
            }
          } else {
            // Shooting motion ended, save the shot
            if (currentShotFrames.length >= 10 &&
                currentShotBallPositions.length >= 5) {
              // Find target hoop based on ball proximity during this shot
              final targetHoop =
                  _findTargetHoop(currentShotFrames) ?? hoopPosition;

              final shot = Shot(
                id: shots.length,
                frames: List.from(currentShotFrames),
                startTime: currentShotFrames.first.timestamp,
                endTime: currentShotFrames.last.timestamp,
                hoopPosition: targetHoop,
              );

              // Calculate shot accuracy using the specific hoop this shot
              // was aimed at (not the global first-found hoop).
              final hoopBBox = _getAverageHoopBBox(
                shootingStartFrame,
                i - 1,
                null,
                targetHoopPosition: targetHoop,
              );
              final hoopRadius = hoopBBox != null ? hoopBBox.width / 2 : 30.0;

              // Use rim crossing detection to determine if shot went in
              final rimCrossingResult =
                  TrajectoryPredictor.calculateShotAccuracyFromRimCrossing(
                    ballPoints: currentShotBallPositions,
                    hoopPosition: targetHoop,
                    hoopBBox: hoopBBox,
                    hoopRadius: hoopRadius,
                    frames: currentShotFrames,
                  );

              // Secondary check: "made" label from model is direct visual
              // evidence the ball went through the hoop — overrides rim
              // crossing when present (especially useful in sideways view
              // where Y-axis crossing geometry is unreliable).
              final madeResult = TrajectoryPredictor.checkMadeDetection(
                currentShotFrames,
                targetHoop,
              );

              // Also evaluate shot quality/form for additional feedback
              final qualityResult = ShotQualityEvaluator.evaluateShotQuality(
                ballTrajectory: currentShotBallPositions,
                hoopPosition: targetHoop,
                hoopRadius: hoopRadius,
              );

              // Use "made" detection if available, otherwise fall back to
              // rim crossing geometry.
              final finalResult = madeResult ?? rimCrossingResult;
              shot.accuracy = finalResult.accuracy;

              // Prediction: MAKE/MISS based on final result + quality feedback
              if (finalResult.accuracy > 50.0) {
                shot.prediction = "MAKE • ${qualityResult.feedback}";
              } else {
                shot.prediction = "MISS • ${qualityResult.feedback}";
              }

              debugPrint('🏀 SHOT ACCURACY: ${shot.accuracy}');

              shots.add(shot);
              debugPrint(
                '✅ Pose-based shot ${shot.id} completed: '
                'Accuracy=${shot.accuracy?.toStringAsFixed(1) ?? "N/A"}% '
                '(${currentShotFrames.length} frames, ${currentShotBallPositions.length} ball positions)',
              );
            } else {
              debugPrint(
                '⚠️ Discarded short shot: ${currentShotFrames.length} frames, '
                '${currentShotBallPositions.length} ball positions',
              );
            }

            // Reset for next shot
            inShootingMotion = false;
            currentShotFrames = [];
            currentShotBallPositions = [];
            consecutiveNonShootingFrames = 0;
          }
        }
      }
    }

    // Handle last shot if still in progress
    if (inShootingMotion && currentShotFrames.length >= 10) {
      final lastTargetHoop =
          _findTargetHoop(currentShotFrames) ?? hoopPosition;

      final shot = Shot(
        id: shots.length,
        frames: List.from(currentShotFrames),
        startTime: currentShotFrames.first.timestamp,
        endTime: currentShotFrames.last.timestamp,
        hoopPosition: lastTargetHoop,
      );

      if (currentShotBallPositions.length >= 5) {
        final hoopBBox = _getAverageHoopBBox(
          shootingStartFrame,
          clip.frames.length - 1,
          null,
          targetHoopPosition: lastTargetHoop,
        );
        final hoopRadius = hoopBBox != null ? hoopBBox.width / 2 : 30.0;

        final rimCrossingResult =
            TrajectoryPredictor.calculateShotAccuracyFromRimCrossing(
              ballPoints: currentShotBallPositions,
              hoopPosition: lastTargetHoop,
              hoopBBox: hoopBBox,
              hoopRadius: hoopRadius,
              frames: currentShotFrames,
            );

        final madeResult = TrajectoryPredictor.checkMadeDetection(
          currentShotFrames,
          lastTargetHoop,
        );

        final qualityResult = ShotQualityEvaluator.evaluateShotQuality(
          ballTrajectory: currentShotBallPositions,
          hoopPosition: lastTargetHoop,
          hoopRadius: hoopRadius,
        );

        final finalResult = madeResult ?? rimCrossingResult;
        shot.accuracy = finalResult.accuracy;
        if (finalResult.accuracy > 50.0) {
          shot.prediction = "MAKE • ${qualityResult.feedback}";
        } else {
          shot.prediction = "MISS • ${qualityResult.feedback}";
        }
      }

      shots.add(shot);
    }

    setState(() {
      clip.shots = shots;
      currentShotIndex = shots.isNotEmpty ? 0 : -1;
    });

    debugPrint(
      '🏀 Pose-based shot segmentation complete: ${shots.length} shots detected',
    );
  }

  /// Check if ball is in the "UP" region (around backboard, above hoop)
  bool _isInUpRegion(
    Offset ballPos,
    Offset hoopPos,
    BoundingBox ballBox, {
    BoundingBox? hoopBox,
  }) {
    // Define UP region boundaries based on reference implementation
    // X: 4x hoop width on each side
    // Y: 2x hoop height above, to 0.5x below hoop center
    final hoopWidth = hoopBox?.width ?? 60.0;
    final hoopHeight = hoopBox?.height ?? 30.0;

    final x1 = hoopPos.dx - (4 * hoopWidth);
    final x2 = hoopPos.dx + (4 * hoopWidth);
    final y1 = hoopPos.dy - (2 * hoopHeight);
    final y2 = hoopPos.dy - (0.5 * hoopHeight);

    return ballPos.dx > x1 &&
        ballPos.dx < x2 &&
        ballPos.dy > y1 &&
        ballPos.dy < y2;
  }

  /// Check if ball is in the "DOWN" region (below the net)
  bool _isInDownRegion(
    Offset ballPos,
    Offset hoopPos,
    BoundingBox ballBox, {
    BoundingBox? hoopBox,
  }) {
    // Define DOWN region: below the bottom of the hoop
    final hoopHeight = hoopBox?.height ?? 30.0;
    final downThreshold = hoopPos.dy + (0.5 * hoopHeight);

    return ballPos.dy > downThreshold;
  }

  /// Find hoop position (legacy - just returns first hoop found)
  Offset? _findHoopPosition() {
    for (final frame in clip.frames) {
      final hoopDetections = frame.detections
          .where(
            (d) =>
                d.label.toLowerCase().contains('hoop') ||
                d.label.toLowerCase().contains('rim') ||
                d.label.toLowerCase().contains('basket'),
          )
          .toList();

      if (hoopDetections.isNotEmpty) {
        final hoop = hoopDetections.first;
        return Offset(hoop.bbox.centerX, hoop.bbox.centerY);
      }
    }
    return null;
  }

  /// Find the target hoop based on which hoop the ball gets closest to
  /// during the shot frames (handles multiple hoops in frame)
  Offset? _findTargetHoop(List<FrameData> shotFrames) {
    if (shotFrames.isEmpty) return null;

    // Collect all unique hoop positions across shot frames
    Map<String, List<Offset>> hoopPositions = {};

    for (final frame in shotFrames) {
      final hoopDetections = frame.detections
          .where(
            (d) =>
                d.label.toLowerCase().contains('hoop') ||
                d.label.toLowerCase().contains('rim') ||
                d.label.toLowerCase().contains('basket'),
          )
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
          .where((d) => d.label.toLowerCase().contains('ball'))
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
      // A proximity estimate (no confirmed crossing) is unreliable in
      // sideways/court view — fall through to direction-of-travel instead.
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

    // TIER 3: All-frame minimum proximity — last resort fallback.
    debugPrint('⚠️ Falling back to all-frame proximity-based hoop selection');
    Map<String, double> minDistances = {};

    for (final hoopKey in hoopPositions.keys) {
      final hoopPositionsList = hoopPositions[hoopKey]!;
      final avgHoopPos = _averageOffset(hoopPositionsList);
      double minDistance = double.infinity;

      for (final frame in shotFrames) {
        final ballDetections = frame.detections
            .where((d) => d.label.toLowerCase().contains('ball'))
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
        if (!d.label.toLowerCase().contains('hoop') &&
            !d.label.toLowerCase().contains('rim') &&
            !d.label.toLowerCase().contains('basket')) continue;

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
  BoundingBox? _getAverageHoopBBox(
    int startFrame,
    int endFrame,
    Map<int, Offset>? hoopMap, {
    Offset? targetHoopPosition,
  }) {
    double sumX1 = 0, sumY1 = 0, sumX2 = 0, sumY2 = 0;
    int count = 0;

    final end = endFrame < clip.frames.length
        ? endFrame
        : clip.frames.length - 1;

    for (int i = startFrame; i <= end; i++) {
      final frame = clip.frames[i];
      final hoopDetections = frame.detections.where(
        (d) =>
            d.label.toLowerCase().contains('hoop') ||
            d.label.toLowerCase().contains('rim') ||
            d.label.toLowerCase().contains('basket') ||
            d.label == '3',
      );

      for (final hoop in hoopDetections) {
        // When a target hoop is known, skip detections that belong to other
        // hoops (i.e. background hoops more than 100px away).
        if (targetHoopPosition != null) {
          final center = Offset(hoop.bbox.centerX, hoop.bbox.centerY);
          if ((center - targetHoopPosition).distance > 100) continue;
        }
        sumX1 += hoop.bbox.x1;
        sumY1 += hoop.bbox.y1;
        sumX2 += hoop.bbox.x2;
        sumY2 += hoop.bbox.y2;
        count++;
      }
    }

    if (count > 0) {
      return BoundingBox(
        x1: sumX1 / count,
        y1: sumY1 / count,
        x2: sumX2 / count,
        y2: sumY2 / count,
      );
    }

    return null;
  }

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
      video_path: widget.videoPath!,
      frames: [],
    );
  }

  void initializeVideoPlayer() {
    // Video player initialization handled by CleanVideoPlayer widget
  }

  void initializeYoloModel() async {
    try {
      // Initialize YOLO for ball/hoop detection
      yoloModel = YOLO(
        modelPath: 'best_float16',
        task: YOLOTask.detect,
        useMultiInstance: true,
      );
      await yoloModel!.loadModel();
      debugPrint('✅ YOLO model loaded successfully');

      // Initialize ML Kit pose detector for shooting motion detection
      poseDetector = ShootingPoseDetector(
        options: PoseDetectorOptions(
          mode: PoseDetectionMode.stream,
          model: PoseDetectionModel.accurate,
        ),
      );
      debugPrint('✅ ML Kit pose detector initialized');
    } catch (e) {
      debugPrint('❌ Error initializing models: $e');
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

    for (int idx = 0; idx < frameResponse!['extracted_frames']; idx += 1) {
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

        // Extract ball position from YOLO results for pose correlation
        Offset? ballPosition;
        if (results.containsKey('boxes') && results['boxes'] is List) {
          final boxes = results['boxes'] as List;
          for (var box in boxes) {
            if (box is Map) {
              final className =
                  box['class_id']?.toString() ?? box['class']?.toString() ?? '';
              if (className.toLowerCase().contains('ball')) {
                final x1 = (box['x1'] ?? 0).toDouble();
                final y1 = (box['y1'] ?? 0).toDouble();
                final x2 = (box['x2'] ?? 0).toDouble();
                final y2 = (box['y2'] ?? 0).toDouble();
                ballPosition = Offset((x1 + x2) / 2, (y1 + y2) / 2);
                break;
              }
            }
          }
        }

        // Run pose detection with ball position for multi-person scenarios
        final inputImage = InputImage.fromFilePath(framePath);
        final poseResult = await poseDetector?.detectShootingPose(
          inputImage,
          ballPosition: ballPosition,
        );

        debugPrint(
          '🏃 Pose detection: isShootingMotion=${poseResult?.isShootingMotion ?? false}, '
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
          '📊 Frame #$frameNumber summary: ${detectionsInFrame} detections (Total: $totalDetections)',
        );

        final frameData = FrameData(
          frameNumber: frameNumber,
          timestamp: preciseTimestampMs / 1000.0,
          detections: frameDetections,
          isShootingMotion: poseResult?.isShootingMotion ?? false,
          shootingConfidence: poseResult?.shootingConfidence ?? 0.0,
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

    if (clip.shots.isNotEmpty &&
        currentShotIndex >= 0 &&
        currentShotIndex < clip.shots.length) {
      // Show only current shot's trajectory
      overlayFrames = clip.shots[currentShotIndex].frames;
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
              isCourtMode: useCourtMode,
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
              // Video player section (takes most of the screen)
              Expanded(
                child: Container(
                  color: Colors.black,
                  child: Center(child: _buildVideoPlayerWithOverlay()),
                ),
              ),

              // Control panel
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Detection mode selector (only show before analysis)
                    if (!isAnalyzing && clip.frames.isEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.blue.withOpacity(0.3),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Detection Mode',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: RadioListTile<bool>(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: const Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '🏀 Backboard View',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          'Backboard visible',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                    value: false,
                                    groupValue: useCourtMode,
                                    onChanged: (value) {
                                      setState(() {
                                        useCourtMode = value!;
                                      });
                                    },
                                  ),
                                ),
                                Expanded(
                                  child: RadioListTile<bool>(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: const Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '🏃 Court/Sideways',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          'Uses pose detection',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    ),
                                    value: true,
                                    groupValue: useCourtMode,
                                    onChanged: (value) {
                                      setState(() {
                                        useCourtMode = value!;
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
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
                          color: Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.blue.withOpacity(0.3),
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
                                          color: Colors.grey[800],
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

                              // Current shot accuracy display
                              if (clip.shots[currentShotIndex].accuracy != null)
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Color.lerp(
                                          Colors.red,
                                          Colors.green,
                                          clip
                                                  .shots[currentShotIndex]
                                                  .accuracy! /
                                              100,
                                        )!.withValues(alpha: 0.2),
                                        Color.lerp(
                                          Colors.red,
                                          Colors.green,
                                          clip
                                                  .shots[currentShotIndex]
                                                  .accuracy! /
                                              100,
                                        )!.withValues(alpha: 0.05),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Color.lerp(
                                        Colors.red,
                                        Colors.green,
                                        clip.shots[currentShotIndex].accuracy! /
                                            100,
                                      )!,
                                      width: 3,
                                    ),
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Icons.track_changes,
                                            color: Color.lerp(
                                              Colors.red,
                                              Colors.green,
                                              clip
                                                      .shots[currentShotIndex]
                                                      .accuracy! /
                                                  100,
                                            ),
                                            size: 24,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Shot Accuracy',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Colors.grey[700],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '${clip.shots[currentShotIndex].accuracy!.toStringAsFixed(1)}%',
                                        style: TextStyle(
                                          fontSize: 36,
                                          fontWeight: FontWeight.bold,
                                          color: Color.lerp(
                                            Colors.red,
                                            Colors.green,
                                            clip
                                                    .shots[currentShotIndex]
                                                    .accuracy! /
                                                100,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            clip.frames.clear();
                            clip.shots.clear();
                            totalDetections = 0;
                            framesProcessed = 0;
                            currentShotIndex = 0;
                          });
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text("Re-analyze"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[600],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Analysis summary with pose detection info
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.green.withOpacity(0.3),
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.check_circle,
                                  color: Colors.green[700],
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${clip.frames.length} frames analyzed',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[800],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$totalDetections ball/hoop detections',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                            if (shootingFramesDetected > 0) ...[
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.accessibility_new,
                                    color: Colors.green[700],
                                    size: 16,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$shootingFramesDetected frames with shooting motion detected',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.green[700],
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ] else ...[
                              const SizedBox(height: 4),
                              Text(
                                'No shooting motion detected (using legacy detection)',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange[700],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),

                    // Video position and controls
                    if (clip.frames.isNotEmpty) ...[
                      Text(
                        'Video position: ${_currentVideoPosition.inSeconds}s',
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 8),

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
                                                .inMilliseconds)!
                                            .toDouble(),
                                      ),
                              max:
                                  (_videoPlayerKey
                                          .currentState
                                          ?.duration
                                          .inMilliseconds)!
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
