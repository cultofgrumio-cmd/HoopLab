import 'dart:ui';

import 'package:hooplab/utils/court.dart';
import 'package:hooplab/utils/court_calibration.dart';

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
  final Offset? footAnchor; // Shooter's on-floor position (image pixels)
  final Offset? courtPosition; // Shot origin in court feet (basket at origin)
  final String? zone; // CourtZone.name the shot was taken from
  final double? rimWidth; // Rim bbox width in image pixels (scale reference)

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
    this.footAnchor,
    this.courtPosition,
    this.zone,
    this.rimWidth,
  });

  /// True when this shot was scored a make.
  bool get isMake => prediction == 'MAKE';

  /// The parsed [CourtZone], or null if the shot was never located.
  CourtZone? get courtZone => CourtZoneInfo.fromStorageKey(zone);

  /// A copy with a recomputed location (used when calibration is upgraded).
  SavedShot withLocation({Offset? courtPosition, String? zone}) => SavedShot(
        id: id,
        startTime: startTime,
        endTime: endTime,
        prediction: prediction,
        accuracy: accuracy,
        formScore: formScore,
        feedback: feedback,
        predictedMake: predictedMake,
        predictedAccuracy: predictedAccuracy,
        ballTrajectory: ballTrajectory,
        hoopPosition: hoopPosition,
        footAnchor: footAnchor,
        courtPosition: courtPosition,
        zone: zone,
        rimWidth: rimWidth,
      );

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
      hoopPosition: _readOffset(json['hoop_position']),
      footAnchor: _readOffset(json['foot_anchor']),
      courtPosition: _readOffset(json['court_position']),
      zone: json['zone'] as String?,
      rimWidth: (json['rim_width'] as num?)?.toDouble(),
    );
  }

  static Offset? _readOffset(dynamic o) => o == null
      ? null
      : Offset((o['dx'] as num).toDouble(), (o['dy'] as num).toDouble());

  static Map<String, double>? _writeOffset(Offset? o) =>
      o == null ? null : {'dx': o.dx, 'dy': o.dy};

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
        'hoop_position': _writeOffset(hoopPosition),
        'foot_anchor': _writeOffset(footAnchor),
        'court_position': _writeOffset(courtPosition),
        'zone': zone,
        'rim_width': rimWidth,
      };
}

/// Aggregated make/attempt tally for one court zone.
class ZoneStat {
  final CourtZone zone;
  int makes;
  int attempts;

  ZoneStat(this.zone, {this.makes = 0, this.attempts = 0});

  double get makePercentage => attempts > 0 ? makes / attempts * 100 : 0;
}

class Session {
  final String id;
  final DateTime createdAt;
  DateTime updatedAt;
  final String videoPath;
  String name;
  List<SavedShot> shots;
  CourtCalibration calibration;

  Session({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.videoPath,
    required this.name,
    required this.shots,
    this.calibration = CourtCalibration.none,
  });

  int get totalShots => shots.length;
  int get makes => shots.where((s) => s.prediction == 'MAKE').length;
  int get misses => shots.where((s) => s.prediction == 'MISS').length;
  double get makePercentage => totalShots > 0 ? makes / totalShots * 100 : 0;

  /// Shots that carry a court location (were successfully located).
  List<SavedShot> get locatedShots =>
      shots.where((s) => s.courtPosition != null && s.courtZone != null).toList();

  /// Make/attempt tally per zone, over located shots only. Zones with no shots
  /// are omitted.
  Map<CourtZone, ZoneStat> get zoneStats {
    final out = <CourtZone, ZoneStat>{};
    for (final s in locatedShots) {
      final z = s.courtZone!;
      final stat = out.putIfAbsent(z, () => ZoneStat(z));
      stat.attempts++;
      if (s.isMake) stat.makes++;
    }
    return out;
  }

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
      calibration: json['calibration'] != null
          ? CourtCalibration.fromJson(
              json['calibration'] as Map<String, dynamic>)
          : CourtCalibration.none,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'video_path': videoPath,
        'name': name,
        'shots': shots.map((s) => s.toJson()).toList(),
        'calibration': calibration.toJson(),
      };
}
