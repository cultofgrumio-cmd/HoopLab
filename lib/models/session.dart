import 'dart:ui';

class SavedShot {
  final int id;
  final double startTime;
  final double endTime;
  final String? prediction;
  final double? accuracy;
  final double? formScore;
  final String? feedback;
  final bool? predictedMake;
  final double? predictedAccuracy;
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
    this.predictedMake,
    this.predictedAccuracy,
    required this.ballTrajectory,
    this.hoopPosition,
  });

  /// Whether the release-time prediction matched the actual make/miss outcome.
  /// Null when either signal is missing.
  bool? get predictionCorrect {
    if (predictedMake == null || prediction == null) return null;
    return predictedMake! == (prediction == 'MAKE');
  }

  factory SavedShot.fromJson(Map<String, dynamic> json) {
    return SavedShot(
      id: json['id'] ?? 0,
      startTime: (json['start_time'] ?? 0).toDouble(),
      endTime: (json['end_time'] ?? 0).toDouble(),
      prediction: json['prediction'],
      accuracy: json['accuracy']?.toDouble(),
      formScore: json['form_score']?.toDouble(),
      feedback: json['feedback'],
      predictedMake: json['predicted_make'],
      predictedAccuracy: json['predicted_accuracy']?.toDouble(),
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
        'predicted_make': predictedMake,
        'predicted_accuracy': predictedAccuracy,
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

  /// Shots the release-time predictor expected to go in.
  int get predictedMakes => shots.where((s) => s.predictedMake == true).length;

  /// Shots where the prediction and the actual outcome are both known.
  int get gradedPredictions =>
      shots.where((s) => s.predictionCorrect != null).length;

  /// Of the graded predictions, how many the predictor got right.
  int get correctPredictions =>
      shots.where((s) => s.predictionCorrect == true).length;

  /// How often the release prediction matched the outcome (null if none graded).
  double? get predictionAccuracy => gradedPredictions > 0
      ? correctPredictions / gradedPredictions * 100
      : null;

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
