import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooplab/models/session.dart';
import 'package:hooplab/utils/court.dart';

/// Which overlay the shot map is currently showing.
enum CourtView { zones, heatmap, markers }

extension CourtViewInfo on CourtView {
  String get label => switch (this) {
        CourtView.zones => 'Sections',
        CourtView.heatmap => 'Heat map',
        CourtView.markers => 'Shots',
      };
}

/// Draws a regulation half court and one of three shot overlays:
///   * [CourtView.zones] — each section shaded by field-goal %, labelled with
///     makes/attempts,
///   * [CourtView.heatmap] — an additive density splat of where shots came from,
///   * [CourtView.markers] — one dot per shot (green make / red miss).
///
/// All positions come from [SavedShot.courtPosition] (court feet, basket at the
/// origin) via [CourtRenderMetrics], so the overlay always lines up with the
/// drawn court regardless of how the shots were located.
class CourtPainter extends CustomPainter {
  final List<SavedShot> shots;
  final Map<CourtZone, ZoneStat> zoneStats;
  final CourtView view;
  final Color lineColor;
  final Color courtFill;
  final Color labelColor;

  CourtPainter({
    required this.shots,
    required this.zoneStats,
    required this.view,
    required this.lineColor,
    required this.courtFill,
    required this.labelColor,
  });

  double _ppf(Size size) => size.width / CourtRenderMetrics.worldWidth;

  Offset _pt(Size size, double xFeet, double yFeet) {
    final n = CourtRenderMetrics.normalize(Offset(xFeet, yFeet));
    return Offset(n.dx * size.width, n.dy * size.height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final court = Offset.zero & size;
    canvas.save();
    canvas.clipRect(court);

    // Court background.
    canvas.drawRect(court, Paint()..color = courtFill);

    if (view == CourtView.zones) _paintZones(canvas, size);
    _paintLines(canvas, size);
    if (view == CourtView.heatmap) _paintHeatmap(canvas, size);
    if (view == CourtView.markers) _paintMarkers(canvas, size);
    if (view == CourtView.zones) _paintZoneLabels(canvas, size);

    canvas.restore();
  }

  // ---- Court lines ----------------------------------------------------------

  void _paintLines(Canvas canvas, Size size) {
    final ppf = _ppf(size);
    final line = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final basket = _pt(size, 0, 0);

    // Court boundary + baseline (top edge) + half-court line (bottom edge).
    canvas.drawRect(Offset.zero & size, line);

    // Backboard + rim.
    final bbY = _pt(size, 0, -1.25).dy;
    canvas.drawLine(Offset(_pt(size, -3, 0).dx, bbY),
        Offset(_pt(size, 3, 0).dx, bbY), line);
    canvas.drawCircle(basket, CourtDimensions.rimRadius * ppf, line);

    // Lane (paint) + free-throw circle.
    final lane = Rect.fromPoints(
        _pt(size, -CourtDimensions.laneHalfWidth, -CourtDimensions.basketToBaseline),
        _pt(size, CourtDimensions.laneHalfWidth, CourtDimensions.freeThrowLineY));
    canvas.drawRect(lane, line);
    final ftC = _pt(size, 0, CourtDimensions.freeThrowLineY);
    canvas.drawCircle(ftC, 6 * ppf, line);

    // Restricted-area arc (lower semicircle around the basket).
    canvas.drawArc(
        Rect.fromCircle(center: basket, radius: CourtDimensions.restrictedRadius * ppf),
        0, math.pi, false, line);

    // Three-point line: two corner verticals + the arc between them.
    final apexY = CourtDimensions.cornerThreeApexY;
    for (final sx in [-1.0, 1.0]) {
      final x = sx * CourtDimensions.cornerThreeX;
      canvas.drawLine(_pt(size, x, -CourtDimensions.basketToBaseline),
          _pt(size, x, apexY), line);
    }
    final rightAngle = math.atan2(apexY, CourtDimensions.cornerThreeX);
    canvas.drawArc(
        Rect.fromCircle(center: basket, radius: CourtDimensions.threePointRadius * ppf),
        rightAngle, math.pi - 2 * rightAngle, false, line);
  }

  // ---- Zones (sections shaded by FG%) --------------------------------------

  void _paintZones(Canvas canvas, Size size) {
    for (final zone in CourtZone.values) {
      final stat = zoneStats[zone];
      if (stat == null || stat.attempts == 0) continue;
      final path = _zonePath(size, zone);
      if (path == null) continue;
      canvas.drawPath(
        path,
        Paint()..color = _fgColor(stat.makePercentage).withValues(alpha: 0.55),
      );
    }
  }

  void _paintZoneLabels(Canvas canvas, Size size) {
    zoneStats.forEach((zone, stat) {
      if (stat.attempts == 0) return;
      final anchor = _pt(size, _zoneCentroid(zone).dx, _zoneCentroid(zone).dy);
      _drawLabel(
        canvas,
        anchor,
        '${stat.makes}/${stat.attempts}',
        '${stat.makePercentage.toStringAsFixed(0)}%',
      );
    });
  }

  // ---- Heat map (additive density) -----------------------------------------

  void _paintHeatmap(Canvas canvas, Size size) {
    final radius = math.max(size.width * 0.075, 18.0);
    for (final s in shots) {
      final c = s.courtPosition;
      if (c == null) continue;
      final center = _pt(size, c.dx, c.dy);
      final shader = RadialGradient(
        colors: [
          const Color(0xFFFF7043).withValues(alpha: 0.42),
          const Color(0xFFFF7043).withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = shader
          ..blendMode = BlendMode.plus,
      );
    }
  }

  // ---- Markers (one dot per shot) ------------------------------------------

  void _paintMarkers(Canvas canvas, Size size) {
    for (final s in shots) {
      final c = s.courtPosition;
      if (c == null) continue;
      final center = _pt(size, c.dx, c.dy);
      final color = s.isMake ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
      canvas.drawCircle(center, 5.5,
          Paint()..color = Colors.white.withValues(alpha: 0.9));
      canvas.drawCircle(center, 4.5, Paint()..color = color);
    }
  }

  // ---- Zone geometry --------------------------------------------------------

  /// A filled path (pixel space) for a zone, matching [classifyZone]. Wedges are
  /// built from the basket by sampling, and the paint / restricted areas are
  /// drawn last by the caller so they sit on top of the overlapping fans.
  Path? _zonePath(Size size, CourtZone zone) {
    final ppf = _ppf(size);
    final basket = _pt(size, 0, 0);
    final r3 = CourtDimensions.threePointRadius;

    switch (zone) {
      case CourtZone.restricted:
        return _semaphore(basket, CourtDimensions.restrictedRadius * ppf);
      case CourtZone.paint:
        final lane = Path()
          ..addRect(Rect.fromPoints(
              _pt(size, -CourtDimensions.laneHalfWidth,
                  -CourtDimensions.basketToBaseline),
              _pt(size, CourtDimensions.laneHalfWidth,
                  CourtDimensions.freeThrowLineY)));
        return Path.combine(PathOperation.difference, lane,
            _semaphore(basket, CourtDimensions.restrictedRadius * ppf));
      case CourtZone.cornerLeft3:
        return Path()
          ..addRect(Rect.fromPoints(
              _pt(size, -25, -CourtDimensions.basketToBaseline),
              _pt(size, -CourtDimensions.cornerThreeX,
                  CourtDimensions.cornerThreeApexY)));
      case CourtZone.cornerRight3:
        return Path()
          ..addRect(Rect.fromPoints(
              _pt(size, CourtDimensions.cornerThreeX,
                  -CourtDimensions.basketToBaseline),
              _pt(size, 25, CourtDimensions.cornerThreeApexY)));
      case CourtZone.midLeft:
        return _wedge(basket, r3 * ppf, -95, -20);
      case CourtZone.midCenter:
        return _wedge(basket, r3 * ppf, -20, 20);
      case CourtZone.midRight:
        return _wedge(basket, r3 * ppf, 20, 95);
      case CourtZone.wingLeft3:
        return _annularWedge(basket, r3 * ppf, 45 * ppf, -95, -20);
      case CourtZone.top3:
        return _annularWedge(basket, r3 * ppf, 45 * ppf, -20, 20);
      case CourtZone.wingRight3:
        return _annularWedge(basket, r3 * ppf, 45 * ppf, 20, 95);
    }
  }

  /// Lower semicircle (half-disk) around [center].
  Path _semaphore(Offset center, double radius) {
    return Path()
      ..moveTo(center.dx - radius, center.dy)
      ..arcTo(Rect.fromCircle(center: center, radius: radius), math.pi, -math.pi,
          false)
      ..close();
  }

  /// Fan from the basket out to [radius] between two court angles (degrees from
  /// straight-out, positive toward the right).
  Path _wedge(Offset basket, double radius, double thetaMinDeg, double thetaMaxDeg,
      {int steps = 28}) {
    final path = Path()..moveTo(basket.dx, basket.dy);
    for (int i = 0; i <= steps; i++) {
      final th =
          (thetaMinDeg + (thetaMaxDeg - thetaMinDeg) * i / steps) * math.pi / 180;
      final dir = Offset(math.sin(th), math.cos(th)); // court → screen (x, y-down)
      final p = basket + dir * radius;
      path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  /// Annular sector between [inner] and [outer] radius (the beyond-arc 3 zones).
  Path _annularWedge(Offset basket, double inner, double outer,
      double thetaMinDeg, double thetaMaxDeg) {
    final big = _wedge(basket, outer, thetaMinDeg, thetaMaxDeg);
    final small = _wedge(basket, inner, thetaMinDeg, thetaMaxDeg);
    return Path.combine(PathOperation.difference, big, small);
  }

  Offset _zoneCentroid(CourtZone zone) => switch (zone) {
        CourtZone.restricted => const Offset(0, 2.2),
        CourtZone.paint => const Offset(0, 9),
        CourtZone.midLeft => const Offset(-13, 9),
        CourtZone.midCenter => const Offset(0, 19),
        CourtZone.midRight => const Offset(13, 9),
        CourtZone.cornerLeft3 => const Offset(-23.5, 3),
        CourtZone.cornerRight3 => const Offset(23.5, 3),
        CourtZone.wingLeft3 => const Offset(-18, 20),
        CourtZone.wingRight3 => const Offset(18, 20),
        CourtZone.top3 => const Offset(0, 27),
      };

  // ---- Helpers --------------------------------------------------------------

  /// FG% → red (cold) through amber to green (hot).
  Color _fgColor(double pct) {
    final t = (pct / 100).clamp(0.0, 1.0);
    if (t < 0.5) {
      return Color.lerp(const Color(0xFFD32F2F), const Color(0xFFFFB300), t / 0.5)!;
    }
    return Color.lerp(
        const Color(0xFFFFB300), const Color(0xFF2E7D32), (t - 0.5) / 0.5)!;
  }

  void _drawLabel(Canvas canvas, Offset center, String line1, String line2) {
    final tp = TextPainter(
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      text: TextSpan(children: [
        TextSpan(
          text: '$line1\n',
          style: TextStyle(
            color: labelColor,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            height: 1.1,
          ),
        ),
        TextSpan(
          text: line2,
          style: TextStyle(
            color: labelColor.withValues(alpha: 0.85),
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ]),
    )..layout();

    // Legibility plate behind the text.
    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + 10,
      height: tp.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant CourtPainter old) =>
      old.view != view ||
      old.shots != shots ||
      old.zoneStats != zoneStats ||
      old.lineColor != lineColor;
}
