/// How the phone is physically set up to film a session — the two supported
/// camera rigs. This is a *geometry* setting, not a court-position one: the
/// player still films from roughly the same spot, but the way the ball's flight
/// projects onto the screen is very different between the two rigs, so the whole
/// shot-analysis pipeline (segmentation, make detection, arc/form scoring,
/// release prediction) is tuned per mode.
enum RecordingMode {
  /// Phone perpendicular to the floor (screen vertical), elevated on a tripod
  /// near rim height and aimed level across the court. The ball's arc and the
  /// rim opening project close to their true geometry: vertical rim-crossing is
  /// reliable and on-screen release angles are close to the real angles.
  tripod,

  /// Phone resting low — on (or near) the ground — tilted up toward the rim.
  /// The upward tilt foreshortens the vertical axis: arcs look flatter, the rim
  /// opening reads as a thin ellipse, and the ball approaches the rim more
  /// head-on (lingering/occluding near it). Scoring compensates for all of this.
  ground,
}

extension RecordingModeInfo on RecordingMode {
  /// Full label for pickers.
  String get label => switch (this) {
        RecordingMode.tripod => 'Tripod (elevated)',
        RecordingMode.ground => 'On the ground',
      };

  /// Compact label for chips / inline badges.
  String get shortLabel => switch (this) {
        RecordingMode.tripod => 'Tripod',
        RecordingMode.ground => 'Ground',
      };

  /// One-line explanation of the rig and what it means for analysis.
  String get description => switch (this) {
        RecordingMode.tripod =>
          'Phone upright on a tripod near rim height, aimed level across the '
              'court. Cleanest arcs and rim geometry.',
        RecordingMode.ground =>
          'Phone resting low and tilted up toward the rim. The upward angle '
              'flattens arcs on screen, so scoring compensates.',
      };

  /// Actionable setup tip shown on the record screens.
  String get setupTip => switch (this) {
        RecordingMode.tripod =>
          'Mount the phone on a tripod around waist–chest height, screen '
              'vertical, aimed level at the rim.',
        RecordingMode.ground =>
          'Rest the phone low (lean it on a bottle or bag), tilted up so the '
              'whole rim and your release stay in frame.',
      };

  /// Stable key used for persistence.
  String get storageKey => switch (this) {
        RecordingMode.tripod => 'tripod',
        RecordingMode.ground => 'ground',
      };

  /// Parse a persisted [storageKey] back to a mode, defaulting to [tripod].
  static RecordingMode fromStorageKey(String key) => switch (key.trim()) {
        'ground' => RecordingMode.ground,
        _ => RecordingMode.tripod,
      };
}
