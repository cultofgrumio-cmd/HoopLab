import 'package:flutter/material.dart';
import 'package:hooplab/pages/camera.dart';
import 'package:hooplab/pages/viewer.dart';
import 'package:image_picker/image_picker.dart';

class MethodSelector extends StatefulWidget {
  const MethodSelector({super.key});

  @override
  State<MethodSelector> createState() => _MethodSelectorState();
}

class _MethodSelectorState extends State<MethodSelector> {
  bool _isPickerActive = false;

  Widget methodButton(String text, VoidCallback onPressed, IconData icon) {
    return Container(
      padding: EdgeInsets.all(20),
      height: 150,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(children: [
        Expanded(child: IconButton(onPressed: onPressed, icon: Icon(icon))),
        Text(text)
      ],)
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(body: Align(
        alignment: Alignment.center,
        child: Row(
          spacing: 50,
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            methodButton("Camera", () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => CameraPage()));
            }, Icons.camera_alt),
            methodButton("Gallery", () async {
              if (_isPickerActive) return;
              
              try {
                setState(() => _isPickerActive = true);
                final ImagePicker picker = ImagePicker();
                final XFile? video = await picker.pickVideo(source: ImageSource.gallery);
                if (video != null) {
                  Navigator.push(context, MaterialPageRoute(
                    builder: (context) => ViewerPage(videoPath: video.path)
                  ));
                }
              } finally {
                setState(() => _isPickerActive = false);
              }
            }, Icons.photo_library),
          ],
        ),
      ))
    );
  }
}
