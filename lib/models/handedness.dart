/// The player's shooting hand. Surfaced as a toggle in Settings so on-screen
/// guidance and form analysis can be oriented to the correct side (e.g. which
/// side the release should come from).
enum Handedness { right, left }

extension HandednessInfo on Handedness {
  /// Full label for pickers.
  String get label => switch (this) {
        Handedness.right => 'Right-handed',
        Handedness.left => 'Left-handed',
      };

  /// Compact label for chips / inline badges.
  String get shortLabel => switch (this) {
        Handedness.right => 'Right',
        Handedness.left => 'Left',
      };

  /// Stable key used for persistence.
  String get storageKey => switch (this) {
        Handedness.right => 'right',
        Handedness.left => 'left',
      };

  /// Parse a persisted [storageKey] back to a hand, defaulting to [right].
  static Handedness fromStorageKey(String key) => switch (key.trim()) {
        'left' => Handedness.left,
        _ => Handedness.right,
      };
}
