import 'dart:ui';

class Clip {
  String id;
  String name;
  String video_path;
  VideoInfo? videoInfo;
  List<FrameData> frames;

  Clip({
    required this.id,
    required this.name,
    required this.video_path,
    this.videoInfo,
    required this.frames,
  });

  factory Clip.fromJson(Map<String, dynamic> json) {
    return Clip(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      video_path: json['video_path'] ?? '',
      videoInfo: json['videoInfo'] != null 
          ? VideoInfo.fromJson(json['videoInfo']) 
          : null,
      frames: (json['frames'] as List<dynamic>?)
          ?.map((frame) => FrameData.fromJson(frame))
          .toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'video_path': video_path,
      'videoInfo': videoInfo?.toJson(),
      'frames': frames.map((frame) => frame.toJson()).toList(),
    };
  }
}

class VideoInfo {
  double fps;
  int totalFrames;
  double duration;
  int width;
  int height;

  VideoInfo({
    required this.fps,
    required this.totalFrames,
    required this.duration,
    required this.width,
    required this.height,
  });

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    return VideoInfo(
      fps: (json['fps'] ?? 0).toDouble(),
      totalFrames: json['total_frames'] ?? 0,
      duration: (json['duration'] ?? 0).toDouble(),
      width: json['width'] ?? 0,
      height: json['height'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fps': fps,
      'total_frames': totalFrames,
      'duration': duration,
      'width': width,
      'height': height,
    };
  }
}

class FrameData {
  int frameNumber;
  double timestamp;
  List<Detection> detections;

  FrameData({
    required this.frameNumber,
    required this.timestamp,
    required this.detections,
  });

  factory FrameData.fromJson(Map<String, dynamic> json) {
    return FrameData(
      frameNumber: json['frame_number'] ?? 0,
      timestamp: (json['timestamp'] ?? 0).toDouble(),
      detections: (json['detections'] as List<dynamic>?)
          ?.map((detection) => Detection.fromJson(detection))
          .toList() ?? [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'frame_number': frameNumber,
      'timestamp': timestamp,
      'detections': detections.map((detection) => detection.toJson()).toList(),
    };
  }
}

class Detection {
  int trackId;
  BoundingBox bbox;
  double confidence;
  double timestamp;

  Detection({
    required this.trackId,
    required this.bbox,
    required this.confidence,
    required this.timestamp,
  });

  factory Detection.fromJson(Map<String, dynamic> json) {
    List<dynamic> bboxList = json['bbox'] ?? [];
    return Detection(
      trackId: json['track_id'] ?? 0,
      bbox: BoundingBox.fromList(bboxList),
      confidence: (json['confidence'] ?? 0).toDouble(),
      timestamp: (json['timestamp'] ?? 0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'track_id': trackId,
      'bbox': bbox.toList(),
      'confidence': confidence,
      'timestamp': timestamp,
    };
  }
}

class BoundingBox {
  double x1;
  double y1;
  double x2;
  double y2;

  BoundingBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  factory BoundingBox.fromList(List<dynamic> bbox) {
    return BoundingBox(
      x1: (bbox.isNotEmpty ? bbox[0] : 0).toDouble(),
      y1: (bbox.length > 1 ? bbox[1] : 0).toDouble(),
      x2: (bbox.length > 2 ? bbox[2] : 0).toDouble(),
      y2: (bbox.length > 3 ? bbox[3] : 0).toDouble(),
    );
  }

  List<double> toList() {
    return [x1, y1, x2, y2];
  }

  // Helper properties
  double get width => x2 - x1;
  double get height => y2 - y1;
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;
  
  // Convert to Rect for UI purposes
  Rect toRect() {
    return Rect.fromLTRB(x1, y1, x2, y2);
  }
}

// Keep the old Point class for backward compatibility if needed
class Point {
  double x;
  double y;
  double width;
  double height;
  double timeStamp;

  Point(this.x, this.y, this.width, this.height, this.timeStamp);

  // Convert from Detection to Point for backward compatibility
  factory Point.fromDetection(Detection detection) {
    return Point(
      detection.bbox.x1,
      detection.bbox.y1,
      detection.bbox.width,
      detection.bbox.height,
      detection.timestamp,
    );
  }
}