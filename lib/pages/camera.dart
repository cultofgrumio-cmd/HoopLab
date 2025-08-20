import 'package:flutter/material.dart';
import 'package:camerawesome/camerawesome_plugin.dart';
import 'package:hooplab/pages/viewer.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CameraAwesomeBuilder.awesome(
        saveConfig: SaveConfig.photoAndVideo(),

        onMediaTap: (mediaCapture) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  ViewerPage(videoPath: mediaCapture.captureRequest.path),
            ),
          );
        },
      ),
    );
  }
}
