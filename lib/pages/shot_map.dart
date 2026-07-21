import 'package:flutter/material.dart';
import 'package:hooplab/models/session.dart';
import 'package:hooplab/services/session_storage.dart';
import 'package:hooplab/utils/court.dart';
import 'package:hooplab/utils/court_calibration.dart';
import 'package:hooplab/widgets/court_painter.dart';

/// Shot chart for a session: a half-court section map (makes/attempts per zone),
/// a heat map of where shots came from, and per-shot markers. An optional
/// free-throw calibration upgrades the location accuracy in place.
class ShotMapPage extends StatefulWidget {
  final Session session;
  const ShotMapPage({super.key, required this.session});

  @override
  State<ShotMapPage> createState() => _ShotMapPageState();
}

class _ShotMapPageState extends State<ShotMapPage> {
  late List<SavedShot> _shots;
  late CourtCalibration _calibration;
  CourtView _view = CourtView.zones;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _shots = List.of(widget.session.shots);
    _calibration = widget.session.calibration;
  }

  List<SavedShot> get _located =>
      _shots.where((s) => s.courtPosition != null && s.courtZone != null).toList();

  Map<CourtZone, ZoneStat> get _zoneStats {
    final out = <CourtZone, ZoneStat>{};
    for (final s in _located) {
      final stat = out.putIfAbsent(s.courtZone!, () => ZoneStat(s.courtZone!));
      stat.attempts++;
      if (s.isMake) stat.makes++;
    }
    return out;
  }

  /// Shots we can build a calibration from (have both a foot anchor and a rim).
  List<SavedShot> get _calibratable =>
      _shots.where((s) => s.footAnchor != null && s.hoopPosition != null).toList();

  void _applyCalibration(CourtCalibration cal) {
    final recomputed = _shots.map((s) {
      if (s.footAnchor == null) return s;
      final loc = cal.locate(s.footAnchor,
          rimCenter: s.hoopPosition, rimWidth: s.rimWidth);
      if (loc == null) return s;
      return s.withLocation(
          courtPosition: loc.courtFeet, zone: loc.zone.storageKey);
    }).toList();
    setState(() {
      _shots = recomputed;
      _calibration = cal;
      _dirty = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    widget.session.shots = _shots;
    widget.session.calibration = _calibration;
    widget.session.updatedAt = DateTime.now();
    await SessionStorage.save(widget.session);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Shot map saved'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final located = _located;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shot Map'),
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        elevation: 0,
        actions: [
          if (_dirty)
            _saving
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.save_rounded),
                    tooltip: 'Save',
                    onPressed: _save,
                  ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          _summaryCard(theme),
          const SizedBox(height: 12),
          _calibrationRow(theme),
          const SizedBox(height: 12),
          SegmentedButton<CourtView>(
            segments: const [
              ButtonSegment(
                  value: CourtView.zones,
                  label: Text('Sections'),
                  icon: Icon(Icons.grid_view_rounded)),
              ButtonSegment(
                  value: CourtView.heatmap,
                  label: Text('Heat'),
                  icon: Icon(Icons.whatshot_rounded)),
              ButtonSegment(
                  value: CourtView.markers,
                  label: Text('Shots'),
                  icon: Icon(Icons.scatter_plot_rounded)),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
          const SizedBox(height: 12),
          _courtCard(theme, located),
          const SizedBox(height: 10),
          _legend(theme),
        ],
      ),
    );
  }

  Widget _summaryCard(ThemeData theme) {
    final cs = theme.colorScheme;
    final total = _shots.length;
    final makes = _shots.where((s) => s.isMake).length;
    final pct = total > 0 ? makes / total * 100 : 0.0;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _stat(theme, 'Shots', '$total'),
          _divider(theme),
          _stat(theme, 'Makes', '$makes', Colors.green),
          _divider(theme),
          _stat(theme, 'Misses', '${total - makes}', Colors.red),
          _divider(theme),
          _stat(
            theme,
            'Make %',
            '${pct.toStringAsFixed(0)}%',
            pct >= 50
                ? Colors.green
                : pct >= 30
                    ? Colors.orange
                    : Colors.red,
          ),
        ],
      ),
    );
  }

  Widget _calibrationRow(ThemeData theme) {
    final cs = theme.colorScheme;
    final calibrated = _calibration.isCalibrated;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: (calibrated ? Colors.green : Colors.orange)
                .withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: (calibrated ? Colors.green : Colors.orange)
                    .withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                calibrated ? Icons.check_circle : Icons.help_outline,
                size: 14,
                color: calibrated ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Text(
                _calibration.tier.badge,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        TextButton.icon(
          onPressed: _calibratable.isEmpty ? null : _openCalibration,
          icon: const Icon(Icons.sports_basketball, size: 18),
          label: Text(calibrated ? 'Recalibrate' : 'Calibrate'),
        ),
      ],
    );
  }

  Widget _courtCard(ThemeData theme, List<SavedShot> located) {
    final isLight = theme.brightness == Brightness.light;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: located.isEmpty
            ? _emptyState(theme)
            : AspectRatio(
                aspectRatio: CourtRenderMetrics.aspectRatio,
                child: CustomPaint(
                  painter: CourtPainter(
                    shots: located,
                    zoneStats: _zoneStats,
                    view: _view,
                    courtFill: isLight
                        ? const Color(0xFFF3E5CB)
                        : const Color(0xFF20242B),
                    lineColor: isLight
                        ? const Color(0xFFB08A5A)
                        : Colors.white.withValues(alpha: 0.55),
                    labelColor: Colors.white,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: Column(
        children: [
          Icon(Icons.map_outlined,
              size: 56, color: cs.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            'No shot locations yet',
            style: theme.textTheme.titleMedium?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Locations are computed when a video is analyzed. Re-analyze this '
            'clip to place its shots on the court.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend(ThemeData theme) {
    final cs = theme.colorScheme;
    final style = theme.textTheme.bodySmall
        ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6));
    final locatedCount = _located.length;
    final note = Text(
      'Located $locatedCount of ${_shots.length} shots · '
      '${_calibration.tier.label}',
      style: style,
    );
    Widget content;
    switch (_view) {
      case CourtView.zones:
        content = Row(
          children: [
            _swatch(const Color(0xFFD32F2F)),
            Text(' cold ', style: style),
            _swatch(const Color(0xFFFFB300)),
            Text(' → ', style: style),
            _swatch(const Color(0xFF2E7D32)),
            Text(' hot (FG%)', style: style),
          ],
        );
        break;
      case CourtView.markers:
        content = Row(
          children: [
            _swatch(const Color(0xFF2E7D32)),
            Text(' make   ', style: style),
            _swatch(const Color(0xFFC62828)),
            Text(' miss', style: style),
          ],
        );
        break;
      case CourtView.heatmap:
        content = Text('Brighter = more shots taken from that spot', style: style);
        break;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [content, const SizedBox(height: 6), note],
    );
  }

  Widget _swatch(Color c) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(3),
        ),
      );

  // ---- Calibration UI -------------------------------------------------------

  Future<void> _openCalibration() async {
    final eligible = _calibratable;
    // Suggest the most free-throw-like located shot: closest to straight-on and
    // near the free-throw distance from the basket.
    SavedShot? suggested;
    double bestScore = double.infinity;
    for (final s in eligible) {
      final c = s.courtPosition;
      if (c == null) continue;
      final score =
          c.dx.abs() + (c.dy - CourtDimensions.freeThrowLineY).abs();
      if (score < bestScore) {
        bestScore = score;
        suggested = s;
      }
    }

    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Text('Calibrate with a free throw',
                    style: theme.textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'Pick the shot you took from the free-throw line. Its known '
                  'position sets the court\'s scale and orientation, making '
                  'every other shot land more accurately.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in eligible)
                      _calibrationTile(ctx, s, s == suggested),
                    if (_calibration.isCalibrated)
                      ListTile(
                        leading: const Icon(Icons.restart_alt, color: Colors.orange),
                        title: const Text('Clear calibration'),
                        subtitle: const Text('Back to the approximate map'),
                        onTap: () {
                          Navigator.pop(ctx);
                          _applyCalibration(CourtCalibration.none);
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _calibrationTile(BuildContext ctx, SavedShot s, bool suggested) {
    final zoneLabel = s.courtZone?.label ?? 'Unlocated';
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: s.isMake
            ? Colors.green.withValues(alpha: 0.15)
            : Colors.red.withValues(alpha: 0.15),
        child: Icon(
          s.isMake ? Icons.check : Icons.close,
          color: s.isMake ? Colors.green : Colors.red,
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Text('Shot ${s.id + 1}'),
          if (suggested) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text('Suggested',
                  style: TextStyle(fontSize: 11, color: Colors.blue)),
            ),
          ],
        ],
      ),
      subtitle: Text('$zoneLabel · ${s.startTime.toStringAsFixed(1)}s'),
      onTap: () {
        Navigator.pop(ctx);
        _applyCalibration(CourtCalibration.fromFreeThrow(
          freeThrowFootAnchor: s.footAnchor!,
          rimCenter: s.hoopPosition!,
        ));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Calibrated from Shot ${s.id + 1}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    );
  }

  Widget _stat(ThemeData theme, String label, String value, [Color? color]) {
    return Column(
      children: [
        Text(value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: color ?? theme.colorScheme.onSurface,
            )),
        const SizedBox(height: 2),
        Text(label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            )),
      ],
    );
  }

  Widget _divider(ThemeData theme) => Container(
        height: 32,
        width: 1,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.15),
      );
}
