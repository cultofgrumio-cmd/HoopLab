import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The single, prescribed recording position for HoopLab.
///
/// Every shot is meant to be captured from **one** spot: where the half-court
/// line meets a sideline, with the phone aimed across the court at the rim.
/// Standardising on this diagonal corner angle is what lets the shot detector
/// run a single tuned configuration instead of guessing between camera setups.
///
/// This widget renders a small top-down court schematic marking that spot and
/// the sight-line to the rim, with an optional caption. Reuse it anywhere the
/// user is about to record (method picker, in-app camera, live workout).
class RecordingAngleGuide extends StatelessWidget {
  /// Show the one-line "stand here" caption beneath the diagram.
  final bool showCaption;

  /// Render on a dark (camera) background — flips text/line colours to light.
  final bool onDark;

  const RecordingAngleGuide({
    super.key,
    this.showCaption = true,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = onDark ? Colors.orangeAccent : theme.colorScheme.primary;
    final line = onDark
        ? Colors.white.withValues(alpha: 0.7)
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final textColor = onDark
        ? Colors.white
        : theme.colorScheme.onSurface.withValues(alpha: 0.85);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 1.5,
          child: CustomPaint(
            painter: _CourtGuidePainter(
              accent: accent,
              lineColor: line,
              labelColor: textColor,
              fill: onDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : theme.colorScheme.primary.withValues(alpha: 0.04),
            ),
          ),
        ),
        if (showCaption) ...[
          const SizedBox(height: 10),
          Text(
            'Stand where the half-court line meets the sideline and '
            'aim the camera across the court at the rim.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: textColor,
              height: 1.3,
            ),
          ),
        ],
      ],
    );
  }
}

class _CourtGuidePainter extends CustomPainter {
  final Color accent;
  final Color lineColor;
  final Color labelColor;
  final Color fill;

  _CourtGuidePainter({
    required this.accent,
    required this.lineColor,
    required this.labelColor,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Top-down half court: baseline (with rim) along the TOP, half-court line
    // along the BOTTOM, sidelines down the left/right. The player records from
    // the bottom-left corner (half-court ∩ sideline), aiming up at the rim.
    const pad = 14.0;
    final court = Rect.fromLTRB(
      pad,
      pad,
      size.width - pad,
      size.height - pad,
    );

    final courtPaint = Paint()..color = fill;
    final linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    final rrect = RRect.fromRectAndRadius(court, const Radius.circular(6));
    canvas.drawRRect(rrect, courtPaint);
    canvas.drawRRect(rrect, linePaint);

    // Half-court line (bottom edge) emphasised.
    final halfLinePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4;
    canvas.drawLine(
      Offset(court.left, court.bottom),
      Offset(court.right, court.bottom),
      halfLinePaint,
    );

    // Rim + backboard at the top-centre of the baseline.
    final rim = Offset(court.center.dx, court.top + 10);
    final backboardPaint = Paint()
      ..color = lineColor
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(rim.dx - 16, court.top + 3),
      Offset(rim.dx + 16, court.top + 3),
      backboardPaint,
    );
    final rimPaint = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6;
    canvas.drawCircle(rim, 5, rimPaint);

    // Restricted-area arc for a touch of court realism.
    final arcPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawArc(
      Rect.fromCircle(center: rim, radius: 22),
      0,
      math.pi,
      false,
      arcPaint,
    );

    // Camera / recording spot at the bottom-left corner.
    final cam = Offset(court.left + 6, court.bottom - 6);

    // Dashed sight-line from the camera to the rim.
    _drawDashedLine(canvas, cam, rim, accent, dash: 6, gap: 4, width: 1.8);

    // Camera marker: filled dot + a small lens cone aimed at the rim.
    final dir = (rim - cam);
    final len = dir.distance == 0 ? 1.0 : dir.distance;
    final unit = Offset(dir.dx / len, dir.dy / len);
    final normal = Offset(-unit.dy, unit.dx);
    final tip = cam + unit * 13;
    final baseL = cam + normal * 6;
    final baseR = cam - normal * 6;
    final conePaint = Paint()..color = accent.withValues(alpha: 0.9);
    final cone = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(baseL.dx, baseL.dy)
      ..lineTo(baseR.dx, baseR.dy)
      ..close();
    canvas.drawPath(cone, conePaint);
    canvas.drawCircle(cam, 5, Paint()..color = accent);
    canvas.drawCircle(cam, 5, Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4);

    // Labels.
    _label(canvas, 'Rim', Offset(rim.dx + 10, rim.dy - 6), labelColor);
    _label(canvas, 'You', Offset(cam.dx + 10, cam.dy - 4), accent);
    _label(
      canvas,
      'half-court line',
      Offset(court.center.dx, court.bottom + 1),
      labelColor,
      align: TextAlign.center,
      anchorCenter: true,
      fontSize: 8.5,
    );
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset a,
    Offset b,
    Color color, {
    double dash = 6,
    double gap = 4,
    double width = 1.5,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = Offset((b.dx - a.dx) / total, (b.dy - a.dy) / total);
    double drawn = 0;
    while (drawn < total) {
      final start = a + dir * drawn;
      final end = a + dir * math.min(drawn + dash, total);
      canvas.drawLine(start, end, paint);
      drawn += dash + gap;
    }
  }

  void _label(
    Canvas canvas,
    String text,
    Offset at,
    Color color, {
    TextAlign align = TextAlign.left,
    bool anchorCenter = false,
    double fontSize = 9.5,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = anchorCenter ? Offset(at.dx - tp.width / 2, at.dy) : at;
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _CourtGuidePainter old) =>
      old.accent != accent ||
      old.lineColor != lineColor ||
      old.labelColor != labelColor ||
      old.fill != fill;
}
