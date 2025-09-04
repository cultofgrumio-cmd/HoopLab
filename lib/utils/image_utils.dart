import 'dart:typed_data';
import 'package:image/image.dart' as img;

Future<Float32List> preprocessImage(Uint8List imageBytes) async {
  // Decode image
  final image = img.decodeImage(imageBytes);
  if (image == null) throw Exception('Failed to decode image');
  
  // Resize to 640x640
  final resized = img.copyResize(image, width: 640, height: 640);
  
  // Convert to float32 and normalize to [0,1]
  final inputTensor = Float32List(1 * 3 * 640 * 640);
  var idx = 0;
  
  // Convert BGR to RGB and normalize
  for (var y = 0; y < 640; y++) {
    for (var x = 0; x < 640; x++) {
      final pixel = resized.getPixel(x, y);
      
      // Get RGB values and normalize to [0,1]
      inputTensor[idx] = pixel.r.toDouble() / 255.0;
      inputTensor[idx + 640 * 640] = pixel.g.toDouble() / 255.0;
      inputTensor[idx + 2 * 640 * 640] = pixel.b.toDouble() / 255.0;
      idx++;
    }
  }
  
  return inputTensor;
}
