import 'package:flutter/material.dart';

/// A step-by-step guide to using HoopLab, reachable from Settings. Explains the
/// full flow: set up the camera, run a live workout or record a session, then
/// review the analysis.
class UserManualPage extends StatelessWidget {
  const UserManualPage({super.key});

  static const _steps = <_Step>[
    _Step(
      icon: Icons.sports_basketball,
      title: 'What HoopLab does',
      lines: [
        'HoopLab watches your shots through your phone camera and scores them '
            'automatically — makes, misses, streaks and shooting form.',
        'You can score shots live as you shoot, or record a session and review '
            'each shot afterwards with a trajectory overlay and a form score.',
        'All analysis runs on your device. Your video never leaves your phone.',
      ],
    ),
    _Step(
      icon: Icons.videocam_outlined,
      title: 'Set up your camera',
      lines: [
        'Open Settings → Recording setup and pick how your phone is mounted:',
        'Tripod (elevated): phone upright near rim height, aimed level across '
            'the court. This gives the cleanest arcs and rim geometry.',
        'On the ground: phone resting low and tilted up at the rim. Handy when '
            'you have no tripod — scoring compensates for the angle.',
        'Stand roughly at the half-court / sideline corner so the whole rim and '
            'your release both stay in frame.',
      ],
    ),
    _Step(
      icon: Icons.podcasts,
      title: 'Run a live workout',
      lines: [
        'From the home screen choose Live Workout and point the camera at the '
            'hoop. Makes, misses, current streak and total update in real time.',
        'Tap the speaker icon to turn spoken feedback on or off, and the tune '
            'icon to choose what gets called out (make/miss, streak, total).',
        'Tap Reset to start a fresh count. Keep the rim in frame the whole time '
            'for the most reliable scoring.',
      ],
    ),
    _Step(
      icon: Icons.movie_creation_outlined,
      title: 'Record & analyze a session',
      lines: [
        'Choose Record to film a shooting session. When you stop, HoopLab finds '
            'each shot and builds a shot log.',
        'Open any shot in the viewer to see the ball trajectory, whether it was '
            'a make or a miss, and a form score for your release.',
        'Use the shot log to spot patterns — which shots fall short, drift left '
            'or right, or have inconsistent arc.',
      ],
    ),
    _Step(
      icon: Icons.history,
      title: 'Review your sessions',
      lines: [
        'Session history keeps your past workouts so you can track makes, '
            'percentage and form over time.',
        'Compare sessions to see whether a change to your shot is actually '
            'improving your numbers.',
      ],
    ),
    _Step(
      icon: Icons.tips_and_updates_outlined,
      title: 'Tips for the best results',
      lines: [
        'Keep the whole rim visible and steady — a wobbling phone hurts '
            'detection.',
        'Good, even lighting helps the model see the ball and rim.',
        'Set your shooting hand in Settings so guidance is oriented to the '
            'correct side.',
        'If makes are being missed or double-counted, double-check the Recording '
            'setup matches how the phone is actually placed.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'User manual',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'How to use HoopLab',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'A quick walkthrough of everything from setting up your phone to '
            'reviewing your shots.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),
          for (var i = 0; i < _steps.length; i++) ...[
            _StepCard(index: i + 1, step: _steps[i]),
            if (i != _steps.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _Step {
  final IconData icon;
  final String title;
  final List<String> lines;
  const _Step({required this.icon, required this.title, required this.lines});
}

class _StepCard extends StatelessWidget {
  final int index;
  final _Step step;
  const _StepCard({required this.index, required this.step});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = scheme.primary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$index',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Icon(step.icon, color: accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final line in step.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Icon(
                      Icons.circle,
                      size: 5,
                      color: scheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      line,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                        color: scheme.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
