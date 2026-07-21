import 'package:flutter/material.dart';

/// A basic FAQ, reachable from Settings, answering the most common "how does
/// this work / why isn't this working" questions with short, practical answers.
class HelpFaqPage extends StatelessWidget {
  const HelpFaqPage({super.key});

  static const _faqs = <_Faq>[
    _Faq(
      question: 'Why aren\'t my makes being counted?',
      answer:
          'Almost always it\'s the camera view. Keep the entire rim in frame '
          'and hold the phone steady. Stand near the sideline / half-court '
          'corner so the ball\'s path through the hoop is clearly visible, and '
          'make sure Settings → Recording setup matches how your phone is '
          'actually placed.',
    ),
    _Faq(
      question: 'Tripod or on-the-ground — which should I pick?',
      answer:
          'Pick whichever matches your real setup. Tripod (elevated) is best: '
          'the phone sits near rim height and aims level, so arcs and rim '
          'geometry look true. On-the-ground is for when you have no tripod — '
          'the phone leans low and tilts up, and HoopLab compensates for the '
          'flatter-looking arcs.',
    ),
    _Faq(
      question: 'How does make / miss detection work?',
      answer:
          'HoopLab tracks the ball and the rim frame by frame. A shot is '
          'scored when the ball approaches the rim from far away and passes '
          'through the rim region. If the ball\'s path goes through the rim '
          'ring it counts as a make; otherwise it\'s a miss. A short cooldown '
          'stops a single rattling shot from being counted twice.',
    ),
    _Faq(
      question: 'What does the form score mean?',
      answer:
          'After a recorded shot, HoopLab estimates your body pose at release '
          'and rates the mechanics of your shot — things like release timing '
          'and arc. Use it as a relative guide to keep your shot consistent, '
          'not as an absolute grade.',
    ),
    _Faq(
      question: 'Does it work indoors or at night?',
      answer:
          'Yes, as long as the ball and rim are clearly visible. Good, even '
          'lighting improves detection. Very dim gyms, heavy backlight, or a '
          'busy background behind the rim can reduce accuracy.',
    ),
    _Faq(
      question: 'Can I use it without the spoken callouts?',
      answer:
          'Yes. In Live Workout, tap the speaker icon to mute audio, or use '
          'the tune icon to choose exactly what gets called out (make/miss, '
          'streak, or total). The on-screen counters keep updating either way.',
    ),
    _Faq(
      question: 'I\'m left-handed — does that matter?',
      answer:
          'Set your shooting hand in Settings → Player. It orients on-screen '
          'guidance and form analysis to the correct side so feedback lines up '
          'with how you actually shoot.',
    ),
    _Faq(
      question: 'Is my video uploaded anywhere?',
      answer:
          'No. Shot detection and analysis run entirely on your device. Your '
          'recordings stay on your phone unless you choose to share them '
          'yourself.',
    ),
    _Faq(
      question: 'How do I change the app\'s colours or dark mode?',
      answer:
          'Open Settings → Appearance. Pick a colour theme from the swatches, '
          'and choose Light, Dark, or System default to control light/dark '
          'mode.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Help & FAQ',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'Frequently asked questions',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Quick answers to how HoopLab works and how to get the most '
            'accurate results.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          for (final faq in _faqs) _FaqTile(faq: faq),
        ],
      ),
    );
  }
}

class _Faq {
  final String question;
  final String answer;
  const _Faq({required this.question, required this.answer});
}

class _FaqTile extends StatelessWidget {
  final _Faq faq;
  const _FaqTile({required this.faq});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.15)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Removes the default divider lines so the card edges stay clean.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          iconColor: scheme.primary,
          collapsedIconColor: scheme.primary,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text(
            faq.question,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          children: [
            Text(
              faq.answer,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.4,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
