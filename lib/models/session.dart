import 'dart:ui';

class SavedShot {
  final int id;
  final double startTime;
  final double endTime;
  final String? prediction;
  final double? accuracy;
  final double? formScore;
  final String? feedback;
  final List<Offset> ballTrajectory;
  final Offset? hoopPosition;

  const SavedShot({
    required this.id,
    required this.startTime,
    required this.endTime,
    this.prediction,
    this.accuracy,
    this.formScore,
    this.feedback,
    required this.ballTrajectory,
    this.hoopPosition,
  });

  factory SavedShot.fromJson(Map<String, dynamic> json) {
    return SavedShot(
      id: json['id'] ?? 0,
      startTime: (json['start_time'] ?? 0).toDouble(),
      endTime: (json['end_time'] ?? 0).toDouble(),
      prediction: json['prediction'],
      accuracy: json['accuracy']?.toDouble(),
      formScore: json['form_score']?.toDouble(),
      feedback: json['feedback'],
      ballTrajectory: (json['ball_trajectory'] as List<dynamic>? ?? [])
          .map((p) => Offset((p['dx'] as num).toDouble(), (p['dy'] as num).toDouble()))
          .toList(),
      hoopPosition: json['hoop_position'] != null
          ? Offset(
              (json['hoop_position']['dx'] as num).toDouble(),
              (json['hoop_position']['dy'] as num).toDouble(),
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'start_time': startTime,
        'end_time': endTime,
        'prediction': prediction,
        'accuracy': accuracy,
        'form_score': formScore,
        'feedback': feedback,
        'ball_trajectory': ballTrajectory.map((o) => {'dx': o.dx, 'dy': o.dy}).toList(),
        'hoop_position': hoopPosition != null
            ? {'dx': hoopPosition!.dx, 'dy': hoopPosition!.dy}
            : null,
      };
}

class Session {
  final String id;
  final DateTime createdAt;
  DateTime updatedAt;
  final String videoPath;
  String name;
  List<SavedShot> shots;

  Session({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.videoPath,
    required this.name,
    required this.shots,
  });

  int get totalShots => shots.length;
  int get makes => shots.where((s) => s.prediction == 'MAKE').length;
  int get misses => shots.where((s) => s.prediction == 'MISS').length;
  double get makePercentage => totalShots > 0 ? makes / totalShots * 100 : 0;

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      id: json['id'] ?? '',
      createdAt: DateTime.parse(json['created_at']),
      updatedAt: DateTime.parse(json['updated_at']),
      videoPath: json['video_path'] ?? '',
      name: json['name'] ?? '',
      shots: (json['shots'] as List<dynamic>? ?? [])
          .map((s) => SavedShot.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'video_path': videoPath,
        'name': name,
        'shots': shots.map((s) => s.toJson()).toList(),
      };
}
