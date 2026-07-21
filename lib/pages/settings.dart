import 'package:flutter/material.dart';
import 'package:hooplab/models/app_accent.dart';
import 'package:hooplab/models/handedness.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/pages/help_faq.dart';
import 'package:hooplab/pages/user_manual.dart';
import 'package:hooplab/services/handedness_storage.dart';
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

          _SectionHeader(title: 'Player'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Set your shooting hand so on-screen guidance and form analysis '
              'are oriented to the correct side.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          const _HandednessSelector(),

          _SectionHeader(title: 'Appearance'),
          const _ColorThemePicker(),
          const SizedBox(height: 4),
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
          _SectionHeader(title: 'Help & guides'),
          _NavTile(
            icon: Icons.menu_book_outlined,
            title: 'User manual',
            subtitle: 'How to set up, record and review your shots',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const UserManualPage()),
            ),
          ),
          _NavTile(
            icon: Icons.help_outline,
            title: 'Help & FAQ',
            subtitle: 'Common questions about how HoopLab works',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HelpFaqPage()),
            ),
          ),
          const SizedBox(height: 24),
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

/// Right / left shooting-hand toggle. Selecting one persists it immediately.
class _HandednessSelector extends StatelessWidget {
  const _HandednessSelector();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: ValueListenableBuilder<Handedness>(
        valueListenable: handednessNotifier,
        builder: (context, active, _) {
          return SegmentedButton<Handedness>(
            segments: const [
              ButtonSegment(
                value: Handedness.right,
                label: Text('Right-handed'),
                icon: Icon(Icons.back_hand_outlined),
              ),
              ButtonSegment(
                value: Handedness.left,
                label: Text('Left-handed'),
                icon: Icon(Icons.front_hand_outlined),
              ),
            ],
            selected: {active},
            onSelectionChanged: (selection) =>
                HandednessStorage.set(selection.first),
          );
        },
      ),
    );
  }
}

/// A row of colour swatches for choosing the app's [AppAccent]. Selecting one
/// persists it immediately and repaints the whole app via [themeAccentNotifier].
class _ColorThemePicker extends StatelessWidget {
  const _ColorThemePicker();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Color theme',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<AppAccent>(
            valueListenable: themeAccentNotifier,
            builder: (context, active, _) {
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final accent in AppAccent.values)
                    _ColorSwatch(
                      accent: accent,
                      selected: accent == active,
                      onTap: () => ThemeStorage.setAccent(accent),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final AppAccent accent;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: accent.label,
      selected: selected,
      button: true,
      child: Tooltip(
        message: accent.label,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.sample,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? scheme.onSurface
                    : scheme.onSurface.withValues(alpha: 0.15),
                width: selected ? 3 : 1,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, color: Colors.white, size: 22)
                : null,
          ),
        ),
      ),
    );
  }
}

/// A tappable settings row that navigates elsewhere (manual, FAQ).
class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
      ),
      onTap: onTap,
    );
  }
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
