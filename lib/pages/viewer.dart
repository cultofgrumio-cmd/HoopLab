import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:hooplab/models/clip.dart';
import 'package:hooplab/utils/image_utils.dart';
import 'package:video_player/video_player.dart';


import 'package:http/http.dart' as http;
import 'package:video_thumbnail/video_thumbnail.dart';

class ViewerPage extends StatefulWidget {
  String? videoPath;
  ViewerPage({super.key, this.videoPath});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  bool isAnalyzing = false;
  late Clip clip;
  late VideoPlayerController videoController;
  OrtSession? session;
  Timer? frameTimer;
  StreamSubscription? analysisSubscription;

  int curFrame = 0;
  double videoDuration = 0.0;
  bool seeking = false;
  
  // ONNX Runtime instance
  final ort = OnnxRuntime();

  // Stream<Map<String, dynamic>>? fetchData() {
  //   // var endpoint = Uri.parse('http://127.0.0.1:8000/analyze');
  //   var endpoint = Uri.parse('http://192.168.1.10:8000/analyze');
  //   File videoFile = File(widget.videoPath!);
  //   var request = http.MultipartRequest('POST', endpoint);
  //   request.files.add(
  //     http.MultipartFile(
  //       'file',
  //       videoFile.readAsBytes().asStream(),
  //       videoFile.lengthSync(),
  //       filename: videoFile.path.split("/").last,
  //     ),
  //   );
  //   var response = request.send();
  //   return response.asStream().asyncExpand((response) {
  //     return response.stream
  //         .transform(utf8.decoder)
  //         .transform(const LineSplitter())
  //         .map((line) => json.decode(line) as Map<String, dynamic>);
  //   });
  // }

  Future<void> initializeONNX() async {
    try {
      // Load the ONNX model
      session = await ort.createSessionFromAsset('assets/2.onnx');
      print('ONNX model loaded successfully');
    } catch (e) {
      print('Error loading ONNX model: $e');
      rethrow;
    }
  }

  Future<List<dynamic>> runInference(Uint8List imageBytes) async {
    if (session == null) throw Exception('ONNX session not initialized');

    try {
      // Reduce image size before processing
      final thumbnail = await VideoThumbnail.thumbnailData(
        video: widget.videoPath!,
        imageFormat: ImageFormat.JPEG, // JPEG uses less memory than PNG
        maxWidth: 640, // limit width
        maxHeight: 640, // limit height
        quality: 50, // reduce quality to save memory
      );
      
      if (thumbnail == null) throw Exception('Failed to create thumbnail');

      // Preprocess the image
      final inputImage = await preprocessImage(thumbnail);
      
      // Create input tensor with reduced memory footprint
      final input = await OrtValue.fromList(
        inputImage,
        [1, 3, 640, 640],
      );

      try {
        // Run inference
        final outputs = await session!.run({'images': input});
        final outputTensor = outputs.values.first;
        final shape = await outputTensor.shape;
        final outputData = await outputTensor.asList();
        
        // Clean up
        await input.dispose();
        
        return outputData;
      } finally {
        // Ensure tensor is released even if inference fails
        await input.dispose();
      }
    } catch (e) {
      print('Inference error: $e');
      rethrow;
    }
  }

  void analyzeFrame(Uint8List frameBytes) async {
    try {
      // Preprocess image to match model input requirements
      final inputTensor = await preprocessImage(frameBytes);
      
      // Create input tensor for ONNX Runtime
      final input = await OrtValue.fromList(
        inputTensor, 
        [1, 3, 640, 640] // NCHW format
      );
      
      // Run inference
      final inputs = {'images': input}; // Check your model's input name
      final outputs = await session!.run(inputs);
      
      // Get output - YOLO models typically output [1, n_boxes, n_values]
      final output = outputs.values.first;
      final outputData = await output.asList();

      print(outputData);
      
      if (outputData.isEmpty) {
        print('No detections found');
        return;
      }

      // Process detections
      // TODO: Parse according to your YOLO model's output format
      // Typically: [x, y, w, h, confidence, class1_conf, class2_conf, ...]
      
      setState(() {
        // Update UI with detections
        // ...
      });

    } catch (e) {
      print('Analysis error: $e');
    }
  }

  Stream<Map<String, dynamic>> inference() async* {
    // Reduce the number of frames processed
    final interval = const Duration(milliseconds: 500); // Process 2 frames per second
    int videoLength = videoController.value.duration.inMilliseconds;
    int currentPosition = 0;

    while (currentPosition < videoLength) {
      try {
        final byteList = await VideoThumbnail.thumbnailData(
          timeMs: currentPosition,
          video: widget.videoPath!,
          imageFormat: ImageFormat.JPEG,
          maxHeight: 640, // Limit height
          quality: 50,
        );

        if (byteList != null) {
          final rawPredictions = await runInference(byteList);
          final detections = await processYoloOutput(rawPredictions);
          
          yield {
            'timestamp': currentPosition,
            'detections': detections,
          };
        }

        // Increment by interval
        currentPosition += interval.inMilliseconds;
        
        // Add a small delay to prevent memory buildup
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        print('Error processing frame at ${currentPosition}ms: $e');
        currentPosition += interval.inMilliseconds;
        continue;
      }
    }
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
    initializeONNX();
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
                      child: VideoPlayer(videoController),
                    ),
                  ),
                  const SizedBox(height: 20),

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

                        analysisSubscription = inference().listen(
                          (data) {
                            print(data);
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

                  clip.videoInfo != null
                      ? clip.videoInfo!.totalFrames > 0
                            ? Column(
                                children: [
                                  Slider(
                                    value: curFrame.toDouble(),
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
                                            (value /
                                                    (clip.videoInfo?.fps ??
                                                        30) *
                                                    1000)
                                                .toInt(),
                                      );
                                      videoController.seekTo(position);
                                      seeking = false;
                                    },
                                  ),
                                  // Detection markers overlay
                                  if (clip.frames.isNotEmpty)
                                    Container(
                                      height: 20,
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                      ),
                                      child: Stack(
                                        children: clip.frames
                                            .where(
                                              (frame) =>
                                                  frame.detections.isNotEmpty,
                                            )
                                            .map((frame) {
                                              double position =
                                                  (frame.frameNumber /
                                                      clip
                                                          .videoInfo!
                                                          .totalFrames) *
                                                  (MediaQuery.of(
                                                        context,
                                                      ).size.width -
                                                      48);
                                              return Positioned(
                                                left: position,
                                                child: Container(
                                                  width: 2,
                                                  height: 20,
                                                  color: Colors.red,
                                                ),
                                              );
                                            })
                                            .toList(),
                                      ),
                                    ),
                                  Text(
                                    'Frame: $curFrame / ${clip.videoInfo?.totalFrames ?? 0}',
                                  ),
                                ],
                              )
                            : Container()
                      : Container(),

                  // Detection count display
                  if (clip.frames.isNotEmpty)
                    Text(
                      'Total detections: ${clip.frames.fold(0, (sum, frame) => sum + frame.detections.length)}',
                    ),
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

class Detection {
  final double x, y, w, h;
  final double confidence;
  
  Detection({
    required this.x, 
    required this.y, 
    required this.w, 
    required this.h, 
    required this.confidence
  });
}

Future<List<Detection>> processYoloOutput(List<dynamic> outputData) async {
  List<Detection> detections = [];
  
  if (outputData.isEmpty) return [];
  
  // YOLOv8 output shape is [1, 5, 8400]
  var predictions = outputData[0] as List<dynamic>;
  int numBoxes = 8400;
  
  print('Processing ${predictions.length} predictions');
  
  // Create lists for each component
  List<double> boxes_x = List<double>.from(predictions[0]);
  List<double> boxes_y = List<double>.from(predictions[1]);
  List<double> boxes_w = List<double>.from(predictions[2]);
  List<double> boxes_h = List<double>.from(predictions[3]);
  List<double> confidences = List<double>.from(predictions[4]);
  
  for (int i = 0; i < numBoxes; i++) {
    double confidence = confidences[i];
    
    // Filter low confidence detections
    if (confidence > 0.25) { // Lowered threshold for testing
      detections.add(Detection(
        x: boxes_x[i],
        y: boxes_y[i],
        w: boxes_w[i],
        h: boxes_h[i],
        confidence: confidence
      ));
      
      print('Found detection: x=${boxes_x[i]}, y=${boxes_y[i]}, conf=$confidence');
    }
  }
  
  return detections;
}

// Add this class to draw the detections
class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  final Size videoSize;
  
  DetectionPainter({required this.detections, required this.videoSize});
  
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
      
    for (var detection in detections) {
      // Convert YOLO coordinates to screen coordinates
      double x = detection.x * size.width / 640; // 640 is model input size
      double y = detection.y * size.height / 640;
      double w = detection.w * size.width / 640;
      double h = detection.h * size.height / 640;
      
      canvas.drawRect(
        Rect.fromLTWH(x - w/2, y - h/2, w, h),
        paint
      );
      
      // Draw confidence text
      TextPainter(
        text: TextSpan(
          text: '${(detection.confidence * 100).toStringAsFixed(0)}%',
          style: TextStyle(
            color: Colors.red,
            fontSize: 16,
            backgroundColor: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )
        ..layout()
        ..paint(canvas, Offset(x - w/2, y - h/2 - 20));
    }
  }
  
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
