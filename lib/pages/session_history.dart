import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hooplab/models/session.dart';
import 'package:hooplab/services/session_storage.dart';
import 'package:hooplab/pages/shot_log.dart';

class SessionHistoryPage extends StatefulWidget {
  const SessionHistoryPage({super.key});

  @override
  State<SessionHistoryPage> createState() => _SessionHistoryPageState();
}

class _SessionHistoryPageState extends State<SessionHistoryPage> {
  List<Session> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sessions = await SessionStorage.loadAll();
    if (mounted) setState(() { _sessions = sessions; _loading = false; });
  }

  Future<void> _delete(Session session) async {
    await SessionStorage.delete(session.id);
    setState(() => _sessions.removeWhere((s) => s.id == session.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session History'),
        backgroundColor: Colors.transparent,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        elevation: 0,
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history, size: 64, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                      const SizedBox(height: 16),
                      Text(
                        'No saved sessions yet',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Analyze a video and tap Save to keep it.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _sessions.length + 1,
                    separatorBuilder: (_, i) => i == 0 ? const SizedBox(height: 20) : const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return _StatsHeader(sessions: _sessions);
                      }
                      final session = _sessions[index - 1];
                      return _SessionCard(
                        session: session,
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ShotLogPage(session: session),
                            ),
                          );
                          _load();
                        },
                        onDelete: () => _confirmDelete(context, session),
                      );
                    },
                  ),
                ),
    );
  }

  void _confirmDelete(BuildContext context, Session session) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text('This will remove "${session.name}" from your history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _delete(session);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final Session session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionCard({
    required this.session,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final videoExists = File(session.videoPath).existsSync();

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Video file indicator
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: videoExists
                      ? colorScheme.primaryContainer
                      : colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  videoExists ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  color: videoExists
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onErrorContainer,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDate(session.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _StatChip(
                          label: '${session.totalShots} shot${session.totalShots == 1 ? '' : 's'}',
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        if (session.totalShots > 0) ...[
                          _StatChip(
                            label: '${session.makes} made',
                            color: Colors.green,
                          ),
                          const SizedBox(width: 8),
                          _StatChip(
                            label: '${session.makePercentage.toStringAsFixed(0)}%',
                            color: _makeColor(session.makePercentage),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                color: colorScheme.onSurface.withValues(alpha: 0.4),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final min = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year} · $hour:$min $ampm';
  }

  Color _makeColor(double pct) {
    if (pct >= 50) return Colors.green;
    if (pct >= 30) return Colors.orange;
    return Colors.red;
  }
}

class _StatsHeader extends StatelessWidget {
  final List<Session> sessions;
  const _StatsHeader({required this.sessions});

  ({int makes, int shots}) _aggregate(DateTime? since) {
    int makes = 0, shots = 0;
    for (final s in sessions) {
      if (since != null && s.createdAt.isBefore(since)) continue;
      makes += s.makes;
      shots += s.totalShots;
    }
    return (makes: makes, shots: shots);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final allTime   = _aggregate(null);
    final pastYear  = _aggregate(now.subtract(const Duration(days: 365)));
    final pastMonth = _aggregate(now.subtract(const Duration(days: 30)));
    final pastWeek  = _aggregate(now.subtract(const Duration(days: 7)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Stats', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _StatCard(label: 'All Time',   makes: allTime.makes,   shots: allTime.shots)),
            const SizedBox(width: 8),
            Expanded(child: _StatCard(label: 'Past Year',  makes: pastYear.makes,  shots: pastYear.shots)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _StatCard(label: 'Past Month', makes: pastMonth.makes, shots: pastMonth.shots)),
            const SizedBox(width: 8),
            Expanded(child: _StatCard(label: 'Past Week',  makes: pastWeek.makes,  shots: pastWeek.shots)),
          ],
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final int makes;
  final int shots;
  const _StatCard({required this.label, required this.makes, required this.shots});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pct = shots > 0 ? makes / shots * 100 : null;
    final pctColor = pct == null
        ? cs.onSurface.withValues(alpha: 0.4)
        : pct >= 50 ? Colors.green : pct >= 30 ? Colors.orange : Colors.red;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.55))),
            const SizedBox(height: 6),
            Text(
              '$makes / $shots',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              pct != null ? '${pct.toStringAsFixed(1)}%' : '—',
              style: theme.textTheme.bodySmall?.copyWith(color: pctColor, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
