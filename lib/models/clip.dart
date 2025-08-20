import 'dart:ui';

class Clip {
  String id;
  String name;
  String video_path;
  List<Point> points;

  Clip({
    required this.id,
    required this.name,
    required this.video_path,
    required this.points,
  });
}

class Point {
  double x;
  double y;
  double width;
  double height;
  double timeStamp;

  Point(this.x, this.y, this.width, this.height, this.timeStamp);
}
