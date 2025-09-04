import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hooplab/models/clip.dart';
import 'package:video_player/video_player.dart';

import 'package:http/http.dart' as http;
import 'package:ultralytics_yolo/yolo.dart';
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
  late YOLO yolo;
  Timer? frameTimer;
  StreamSubscription? analysisSubscription;

  int curFrame = 0;
  double videoDuration = 0.0;
  bool seeking = false;

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

  Future<void> initializeYOLO() async {
    yolo = YOLO(modelPath: 'assets/best.pt', task: YOLOTask.detect);
    await yolo.loadModel();
  }

  Stream<Map<String, dynamic>> inference() async* {
    int videoLength = videoController.value.duration.inMilliseconds
        .toDouble()
        .round();
    int parts = (videoLength / 5).floor();
    List<int> partList = List.generate(parts, (i) => i * 5);

    for (var timeMs in partList) {
      final byteList = await VideoThumbnail.thumbnailData(
        timeMs: timeMs,
        video: widget.videoPath!,
        imageFormat: ImageFormat.PNG,
        maxHeight: videoController.value.size.height
            .toInt(), // specify the height of the thumbnail, let the width auto-scaled to keep the source aspect ratio
        quality: 75,
      );

      if (byteList != null) {
        final prediction = await yolo.predict(byteList);
        yield prediction;
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
    initializeYOLO();
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
