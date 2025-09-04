import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooplab/models/clip.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;

// Custom painter for drawing basketball detections
class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  final Size videoSize;
  final Size widgetSize;
  final double aspectRatio;
  final List<FrameData> allFrames;
  final int currentFrame;
  final bool showTrajectories;

  DetectionPainter({
    required this.detections,
    required this.videoSize,
    required this.widgetSize,
    required this.aspectRatio,
    required this.allFrames,
    required this.currentFrame,
    this.showTrajectories = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (videoSize.width == 0 || videoSize.height == 0) return;

    // Calculate the actual video display area within the widget
    final widgetAspectRatio = size.width / size.height;
    final videoAspectRatio = aspectRatio;

    double videoDisplayWidth, videoDisplayHeight;
    double offsetX = 0, offsetY = 0;

    if (widgetAspectRatio > videoAspectRatio) {
      // Widget is wider than video - video will have pillarboxing (black bars on sides)
      videoDisplayHeight = size.height;
      videoDisplayWidth = videoDisplayHeight * videoAspectRatio;
      offsetX = (size.width - videoDisplayWidth) / 2;
    } else {
      // Widget is taller than video - video will have letterboxing (black bars on top/bottom)
      videoDisplayWidth = size.width;
      videoDisplayHeight = videoDisplayWidth / videoAspectRatio;
      offsetY = (size.height - videoDisplayHeight) / 2;
    }

    // Calculate scale factors from video coordinates to display coordinates
    final scaleX = videoDisplayWidth / videoSize.width;
    final scaleY = videoDisplayHeight / videoSize.height;

    // Draw trajectories first (so they appear behind current detections)
    if (showTrajectories) {
      _drawTrajectories(canvas, scaleX, scaleY, offsetX, offsetY);
    }

    // Draw current frame detections
    _drawCurrentDetections(canvas, size, scaleX, scaleY, offsetX, offsetY);
  }

  void _drawTrajectories(Canvas canvas, double scaleX, double scaleY, double offsetX, double offsetY) {
    // Group detections by track ID
    Map<int, List<Offset>> trajectories = {};
    
    // Collect all detection positions for each track
    for (final frame in allFrames) {
      if (frame.frameNumber > currentFrame) continue; // Only show past and current
      
      for (final detection in frame.detections) {
        final trackId = detection.trackId;
        final centerX = (detection.bbox.centerX * scaleX) + offsetX;
        final centerY = (detection.bbox.centerY * scaleY) + offsetY;
        
        trajectories.putIfAbsent(trackId, () => []);
        trajectories[trackId]!.add(Offset(centerX, centerY));
      }
    }
    
    // Draw trajectory lines for each track
    for (final entry in trajectories.entries) {
      final trackId = entry.key;
      final points = entry.value;
      
      if (points.length < 2) continue; // Need at least 2 points to draw a line
      
      final color = _getTrackColor(trackId);
      final trajectoryPaint = Paint()
        ..color = color.withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      
      // Draw lines between consecutive points
      for (int i = 0; i < points.length - 1; i++) {
        canvas.drawLine(points[i], points[i + 1], trajectoryPaint);
      }
      
      // Draw small circles at each trajectory point
      final pointPaint = Paint()
        ..color = color.withOpacity(0.4)
        ..style = PaintingStyle.fill;
      
      for (final point in points) {
        canvas.drawCircle(point, 2, pointPaint);
      }
    }
  }

  void _drawCurrentDetections(Canvas canvas, Size size, double scaleX, double scaleY, double offsetX, double offsetY) {
    if (detections.isEmpty) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (int i = 0; i < detections.length; i++) {
      final detection = detections[i];

      // Get color based on track ID
      final color = _getTrackColor(detection.trackId);
      paint.color = color;

      // Scale and offset bounding box coordinates
      final rect = Rect.fromLTRB(
        (detection.bbox.x1 * scaleX) + offsetX,
        (detection.bbox.y1 * scaleY) + offsetY,
        (detection.bbox.x2 * scaleX) + offsetX,
        (detection.bbox.y2 * scaleY) + offsetY,
      );

      // Draw bounding box
      canvas.drawRect(rect, paint);

      // Draw confidence and track ID
      final text = '🏀 ${detection.trackId} (${(detection.confidence * 100).toStringAsFixed(0)}%)';
      textPainter.text = TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black87,
        ),
      );
      textPainter.layout();

      // Position text above the bounding box
      final textOffset = Offset(
        rect.left,
        (rect.top - textPainter.height - 4).clamp(0.0, size.height - textPainter.height),
      );
      textPainter.paint(canvas, textOffset);

      // Draw center point (larger and more prominent than trajectory points)
      final centerPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(rect.center, 5, centerPaint);
      
      // Draw white outline on center point for better visibility
      final outlinePaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawCircle(rect.center, 5, outlinePaint);
    }
  }

  Color _getTrackColor(int trackId) {
    final colors = [
      Colors.red,
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.cyan,
      Colors.pink,
      Colors.yellow,
    ];
    return colors[trackId % colors.length];
  }

  @override
  bool shouldRepaint(DetectionPainter oldDelegate) {
    return detections != oldDelegate.detections ||
           videoSize != oldDelegate.videoSize ||
           widgetSize != oldDelegate.widgetSize ||
           aspectRatio != oldDelegate.aspectRatio ||
           allFrames != oldDelegate.allFrames ||
           currentFrame != oldDelegate.currentFrame ||
           showTrajectories != oldDelegate.showTrajectories;
  }
}

class ViewerPage extends StatefulWidget {
  final String? videoPath;
  const ViewerPage({super.key, this.videoPath});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  bool isAnalyzing = false;
  late Clip clip;
  late VideoPlayerController videoController;
  Timer? frameTimer;
  StreamSubscription? analysisSubscription;

  int curFrame = 0;
  double videoDuration = 0.0;
  bool seeking = false;
  bool showTrajectories = true;

  Stream<Map<String, dynamic>>? fetchData() {
    // var endpoint = Uri.parse('http://127.0.0.1:8000/analyze');
    var endpoint = Uri.parse('http://192.168.1.10:8000/analyze');
    File videoFile = File(widget.videoPath!);
    var request = http.MultipartRequest('POST', endpoint);
    request.files.add(
      http.MultipartFile(
        'file',
        videoFile.readAsBytes().asStream(),
        videoFile.lengthSync(),
        filename: videoFile.path.split("/").last,
      ),
    );
    var response = request.send();
    return response.asStream().asyncExpand((response) {
      return response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map((line) => json.decode(line) as Map<String, dynamic>);
    });
  }

  void initializeVideoPlayer() {
    videoController = VideoPlayerController.file(File(widget.videoPath!))
      ..initialize().then((_) {
        setState(() {});
      });
  }

  @override
  void initState() {
    initializeVideoPlayer();
    clip = Clip(
      id: "1",
      name: "Test Clip",
      video_path: widget.videoPath!,
      frames: [],
    );

    videoController.addListener(() {
      if (!seeking && videoController.value.isInitialized) {
        setState(() {
          curFrame =
              (videoController.value.position.inMilliseconds /
                      1000.0 *
                      (clip.videoInfo?.fps ?? 30))
                  .toInt();
        });
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    analysisSubscription?.cancel();
    videoController.dispose();
    frameTimer?.cancel();
    super.dispose();
  }

  void AnalyzeFrames() async {
    videoController.play();
  }

  // Get detections for the current frame
  List<Detection> getCurrentFrameDetections() {
    final frameData = clip.frames.where((frame) => frame.frameNumber == curFrame).firstOrNull;
    final detections = frameData?.detections.whereType<Detection>().toList() ?? [];
    print('Current frame: $curFrame, Found frame data: ${frameData != null}, Detections: ${detections.length}');
    if (frameData != null) {
      print('Frame ${frameData.frameNumber} has ${frameData.detections.length} raw detections');
    }
    return detections;
  }

  // Get color for track ID (same as painter)
  Color _getTrackColor(int trackId) {
    final colors = [
      Colors.red,
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.cyan,
      Colors.pink,
      Colors.yellow,
    ];
    return colors[trackId % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    if (!videoController.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return SafeArea(
      child: Scaffold(
        appBar: AppBar(title: const Text("Viewer")),
        body: Stack(
          children: [
            // Main content
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    flex: 3,
                    child: AspectRatio(
                      aspectRatio: videoController.value.aspectRatio,
                      child: Stack(
                        children: [
                          VideoPlayer(videoController),
                          // Overlay for drawing detections
                          Positioned.fill(
                            child: CustomPaint(
                              painter: DetectionPainter(
                                detections: getCurrentFrameDetections(),
                                videoSize: Size(
                                  clip.videoInfo?.width.toDouble() ?? 1920,
                                  clip.videoInfo?.height.toDouble() ?? 1080,
                                ),
                                widgetSize: Size(
                                  MediaQuery.of(context).size.width - 32,
                                  (MediaQuery.of(context).size.width - 32) / videoController.value.aspectRatio,
                                ),
                                aspectRatio: videoController.value.aspectRatio,
                                allFrames: clip.frames,
                                currentFrame: curFrame,
                                showTrajectories: showTrajectories,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Frame navigation and detection info
                  if (clip.videoInfo != null && clip.videoInfo!.totalFrames > 0)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('Frame: $curFrame / ${clip.videoInfo!.totalFrames}'),
                              Text('Detections: ${getCurrentFrameDetections().length}'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              ElevatedButton.icon(
                                onPressed: curFrame > 0 ? () {
                                  setState(() {
                                    seeking = true;
                                    curFrame = curFrame - 1;
                                  });
                                  final position = Duration(
                                    milliseconds: (curFrame / (clip.videoInfo?.fps ?? 30) * 1000).toInt(),
                                  );
                                  videoController.seekTo(position).then((_) {
                                    setState(() {
                                      seeking = false;
                                    });
                                  });
                                } : null,
                                icon: const Icon(Icons.skip_previous),
                                label: const Text('Prev'),
                              ),
                              ElevatedButton.icon(
                                onPressed: () {
                                  if (videoController.value.isPlaying) {
                                    videoController.pause();
                                  } else {
                                    videoController.play();
                                  }
                                  setState(() {});
                                },
                                icon: Icon(videoController.value.isPlaying ? Icons.pause : Icons.play_arrow),
                                label: Text(videoController.value.isPlaying ? 'Pause' : 'Play'),
                              ),
                              ElevatedButton.icon(
                                onPressed: curFrame < clip.videoInfo!.totalFrames - 1 ? () {
                                  setState(() {
                                    seeking = true;
                                    curFrame = curFrame + 1;
                                  });
                                  final position = Duration(
                                    milliseconds: (curFrame / (clip.videoInfo?.fps ?? 30) * 1000).toInt(),
                                  );
                                  videoController.seekTo(position).then((_) {
                                    setState(() {
                                      seeking = false;
                                    });
                                  });
                                } : null,
                                icon: const Icon(Icons.skip_next),
                                label: const Text('Next'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 10),

                  ElevatedButton(
                    onPressed: () {
                      if (isAnalyzing) {
                        // Stop analysis
                        analysisSubscription?.cancel();
                        setState(() {
                          isAnalyzing = false;
                        });
                      } else {
                        // Start analysis
                        setState(() {
                          isAnalyzing = true;
                          clip.frames.clear(); // Clear previous results
                        });

                        analysisSubscription = fetchData()?.listen(
                          (data) {
                            if (data['type'] == "video_info") {
                              setState(() {
                                clip.videoInfo = VideoInfo.fromJson(
                                  data['data'],
                                );
                              });
                            }

                            if (data['type'] == "frame_data") {
                              try {
                                // The frame data is nested under 'data' key
                                Map<String, dynamic> frameData = data['data'] as Map<String, dynamic>;
                                
                                print('Parsing frame data: $frameData');
                                FrameData frame = FrameData.fromJson(frameData);
                                print('Parsed frame ${frame.frameNumber} with ${frame.detections.length} detections');
                                setState(() {
                                  clip.frames.add(frame);
                                });
                              } catch (e) {
                                print('Error parsing frame data: $e');
                                print('Raw data: $data');
                              }
                            }
                            ;
                          },

                          onError: (error) {
                            print('Analysis error: $error');
                            setState(() {
                              isAnalyzing = false;
                            });
                          },
                          onDone: () {
                            print('Analysis complete');
                            setState(() {
                              isAnalyzing = false;
                            });
                          },
                        );
                      }
                    },
                    child: Text(
                      isAnalyzing ? "Stop Analysis" : "Start Analysis",
                    ),
                  ),

                  const SizedBox(height: 10),

                  // Trajectory toggle button
                  ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        showTrajectories = !showTrajectories;
                      });
                    },
                    icon: Icon(showTrajectories ? Icons.timeline : Icons.timeline_outlined),
                    label: Text(showTrajectories ? 'Hide Trajectories' : 'Show Trajectories'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: showTrajectories ? Colors.blue.withOpacity(0.1) : null,
                    ),
                  ),

                  const SizedBox(height: 10),

                  clip.videoInfo != null ?
                  clip.videoInfo!.totalFrames > 0 ? 
                  Column(
                    children: [
                      Slider(
                        value: curFrame.toDouble().clamp(0, clip.videoInfo!.totalFrames - 1).toDouble(),
                        min: 0,
                        max: clip.videoInfo!.totalFrames.toDouble(),
                        divisions: clip.videoInfo!.totalFrames,
                        label: 'Frame $curFrame',
                        onChangeStart: (value) {
                          seeking = true;
                        },
                        onChanged: (value) {
                          setState(() {
                            curFrame = value.toInt();
                          });
                        },
                        onChangeEnd: (value) {
                          final position = Duration(
                              milliseconds:
                                  (value / (clip.videoInfo?.fps ?? 30) * 1000)
                                      .toInt());
                          videoController.seekTo(position);
                          seeking = false;
                        },
                      ),
                      // Detection markers overlay
                      if (clip.frames.isNotEmpty)
                        Container(
                          height: 20,
                          margin: const EdgeInsets.symmetric(horizontal: 24),
                          child: Stack(
                            children: clip.frames
                                .where((frame) => frame.detections.isNotEmpty)
                                .map((frame) {
                              double position = (frame.frameNumber / clip.videoInfo!.totalFrames) * 
                                  (MediaQuery.of(context).size.width - 48);
                              return Positioned(
                                left: position,
                                child: Container(
                                  width: 2,
                                  height: 20,
                                  color: Colors.red,
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      Text(
                          'Frame: $curFrame / ${clip.videoInfo?.totalFrames ?? 0}'),
                    ],
                  ) : Container() : Container(),

                  // Detection count display
                  if (clip.frames.isNotEmpty) ...[
                    Text(
                      'Total detections: ${clip.frames.fold(0, (sum, frame) => sum + frame.detections.length)}',
                    ),
                    const SizedBox(height: 8),
                  
                  ],
                ],
              ),
            ),

            // Analysis overlay
            if (isAnalyzing)
              Container(
                color: Colors.black.withOpacity(0.7),
                child: Center(
                  child: Card(
                    margin: const EdgeInsets.all(32.0),
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          const Text(
                            'Analyzing Video...',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (clip.videoInfo != null) ...[
                            Text(
                              'Processing: ${clip.frames.length}/${clip.videoInfo!.totalFrames} frames',
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value:
                                  clip.frames.length /
                                  clip.videoInfo!.totalFrames,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${((clip.frames.length / clip.videoInfo!.totalFrames) * 100).toStringAsFixed(1)}% Complete',
                            ),
                          ] else ...[
                            const Text('Initializing...'),
                          ],
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () {
                              analysisSubscription?.cancel();
                              setState(() {
                                isAnalyzing = false;
                              });
                            },
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
