import 'package:flutter/material.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/services/recording_mode_storage.dart';
import 'package:hooplab/services/theme_storage.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          _SectionHeader(title: 'Recording setup'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Tell HoopLab how your phone is set up so shot analysis can '
              'account for the camera angle.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          const _RecordingModeSelector(),

          _SectionHeader(title: 'Appearance'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) {
              return RadioGroup<ThemeMode>(
                groupValue: mode,
                onChanged: _setMode,
                child: const Column(
                  children: [
                    RadioListTile<ThemeMode>(
                      title: Text('System default'),
                      subtitle: Text('Match your device setting'),
                      value: ThemeMode.system,
                    ),
                    RadioListTile<ThemeMode>(
                      title: Text('Light'),
                      value: ThemeMode.light,
                    ),
                    RadioListTile<ThemeMode>(
                      title: Text('Dark'),
                      value: ThemeMode.dark,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'More settings coming soon',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static void _setMode(ThemeMode? mode) {
    if (mode == null) return;
    themeModeNotifier.value = mode;
    ThemeStorage.save(mode);
  }
}

/// Two selectable cards for the [RecordingMode], each with a side-view diagram,
/// label and description. Selecting one persists it immediately.
class _RecordingModeSelector extends StatelessWidget {
  const _RecordingModeSelector();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RecordingMode>(
      valueListenable: recordingModeNotifier,
      builder: (context, active, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            children: [
              for (final mode in RecordingMode.values) ...[
                _ModeCard(
                  mode: mode,
                  selected: mode == active,
                  onTap: () => RecordingModeStorage.set(mode),
                ),
                if (mode != RecordingMode.values.last)
                  const SizedBox(height: 12),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ModeCard extends StatelessWidget {
  final RecordingMode mode;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = scheme.primary;

    return Material(
      color: selected
          ? accent.withValues(alpha: 0.08)
          : scheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.7)
                  : scheme.onSurface.withValues(alpha: 0.15),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 88,
                height: 68,
                child: CustomPaint(
                  painter: _ModeDiagramPainter(
                    mode: mode,
                    accent: accent,
                    line: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            mode.label,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: selected ? accent : scheme.onSurface,
                            ),
                          ),
                        ),
                        Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: selected
                              ? accent
                              : scheme.onSurface.withValues(alpha: 0.35),
                          size: 20,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      mode.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.7),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small side-view schematic contrasting the two rigs: an upright, elevated
/// phone aimed level at the rim (tripod) vs a low phone tilted up at the rim
/// (ground). Purely illustrative.
class _ModeDiagramPainter extends CustomPainter {
  final RecordingMode mode;
  final Color accent;
  final Color line;

  _ModeDiagramPainter({
    required this.mode,
    required this.accent,
    required this.line,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final floorY = size.height - 6;
    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;

    // Floor.
    canvas.drawLine(
      Offset(4, floorY),
      Offset(size.width - 4, floorY),
      linePaint,
    );

    // Rim + backboard at the top-right.
    final rim = Offset(size.width - 12, 12);
    canvas.drawLine(
      Offset(rim.dx + 4, rim.dy - 8),
      Offset(rim.dx + 4, rim.dy + 6),
      linePaint..strokeWidth = 2, // backboard
    );
    final rimPaint = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(rim.dx - 6, rim.dy + 2),
      Offset(rim.dx + 3, rim.dy + 2),
      rimPaint,
    );

    // Phone position + orientation differ by mode.
    final Offset phoneCenter;
    final double phoneAngle; // radians, 0 = upright (perpendicular to floor)
    if (mode == RecordingMode.tripod) {
      phoneCenter = Offset(20, floorY - 34); // elevated
      phoneAngle = 0; // perpendicular to the floor
      // Tripod stand: a small triangle down to the floor.
      final standPaint = Paint()
        ..color = line
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
          Offset(phoneCenter.dx, phoneCenter.dy + 8),
          Offset(phoneCenter.dx - 7, floorY), standPaint);
      canvas.drawLine(
          Offset(phoneCenter.dx, phoneCenter.dy + 8),
          Offset(phoneCenter.dx + 7, floorY), standPaint);
      canvas.drawLine(Offset(phoneCenter.dx, phoneCenter.dy + 8),
          Offset(phoneCenter.dx, floorY), standPaint);
    } else {
      phoneCenter = Offset(20, floorY - 8); // low, near the ground
      phoneAngle = -0.9; // tilted back, aiming up
    }

    // Sight-line from the phone to the rim.
    _dashedLine(canvas, phoneCenter, rim, accent);

    // Phone body (rounded rectangle), rotated by phoneAngle.
    canvas.save();
    canvas.translate(phoneCenter.dx, phoneCenter.dy);
    canvas.rotate(phoneAngle);
    final phoneRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 11, height: 20),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(phoneRect, Paint()..color = accent);
    // Lens dot near the top of the phone (the side facing the rim).
    canvas.drawCircle(
      const Offset(0, -6),
      1.6,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
    canvas.restore();
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    const dash = 4.0, gap = 3.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    double drawn = 0;
    while (drawn < total) {
      final endDist = (drawn + dash) < total ? (drawn + dash) : total;
      canvas.drawLine(a + dir * drawn, a + dir * endDist, paint);
      drawn += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _ModeDiagramPainter old) =>
      old.mode != mode || old.accent != accent || old.line != line;
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
