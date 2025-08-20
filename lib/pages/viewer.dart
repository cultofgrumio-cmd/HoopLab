import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooplab/models/clip.dart';
import 'package:video_player/video_player.dart';

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
  Timer? frameTimer;

  void initializeVideoPlayer() {
    videoController = VideoPlayerController.asset("assets/video.mp4")
      ..initialize().then((_) {
        setState(() {});
      });
  }

  @override
  void initState() {
    initializeVideoPlayer();
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void AnalyzeFrames() async {
    videoController.play();
  }

  @override
  Widget build(BuildContext context) {
    if (!videoController.value.isInitialized) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: Text("Viewer")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AspectRatio(
              aspectRatio: videoController.value.aspectRatio,
              child: VideoPlayer(videoController),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                if (isAnalyzing) {
                  videoController.pause();
                  setState(() {
                    isAnalyzing = false;
                  });
                } else {
                  AnalyzeFrames();
                  setState(() {
                    isAnalyzing = true;
                  });
                }
              },
              child: Text(isAnalyzing ? "Stop Analysis" : "Start Analysis"),
            ),
          ],
        ),
      ),
    );
  }
}
