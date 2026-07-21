import 'package:flutter/material.dart';
import 'package:hooplab/models/session.dart';
import 'package:hooplab/services/session_storage.dart';

class ShotLogPage extends StatefulWidget {
  final Session session;
  const ShotLogPage({super.key, required this.session});

  @override
  State<ShotLogPage> createState() => _ShotLogPageState();
}

class _ShotLogPageState extends State<ShotLogPage> {
  late List<SavedShot> _shots;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _shots = List.from(widget.session.shots);
  }

  void _deleteShot(int index) {
    setState(() {
      _shots.removeAt(index);
      _dirty = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    widget.session.shots = _shots;
    widget.session.updatedAt = DateTime.now();
    await SessionStorage.save(widget.session);
    if (mounted) {
      setState(() { _saving = false; _dirty = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session saved'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<bool> _onWillPop() async {
    if (!_dirty) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: const Text('You have unsaved changes. Leave without saving?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final makes = _shots.where((s) => s.prediction == 'MAKE').length;
    final total = _shots.length;
    final makePct = total > 0 ? makes / total * 100 : 0.0;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final leave = await _onWillPop();
        if (leave) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.session.name, overflow: TextOverflow.ellipsis),
          backgroundColor: Colors.transparent,
          foregroundColor: Theme.of(context).colorScheme.onSurface,
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
        body: Column(
          children: [
            // Summary header
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _SummaryItem(label: 'Shots', value: '$total'),
                  _Divider(),
                  _SummaryItem(label: 'Makes', value: '$makes', color: Colors.green),
                  _Divider(),
                  _SummaryItem(label: 'Misses', value: '${total - makes}', color: Colors.red),
                  _Divider(),
                  _SummaryItem(
                    label: 'Make %',
                    value: '${makePct.toStringAsFixed(0)}%',
                    color: makePct >= 50 ? Colors.green : makePct >= 30 ? Colors.orange : Colors.red,
                  ),
                ],
              ),
            ),
            // Shot list
            Expanded(
              child: _shots.isEmpty
                  ? Center(
                      child: Text(
                        'No shots remaining.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: _shots.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final shot = _shots[index];
                        return _ShotCard(
                          shotNumber: index + 1,
                          shot: shot,
                          onDelete: () => _confirmDelete(context, index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, int index) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove shot?'),
        content: Text('Remove Shot ${index + 1} from this session?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteShot(index);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _SummaryItem({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: color ?? theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      width: 1,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.15),
    );
  }
}

class _ShotCard extends StatelessWidget {
  final int shotNumber;
  final SavedShot shot;
  final VoidCallback onDelete;

  const _ShotCard({
    required this.shotNumber,
    required this.shot,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isMake = shot.prediction == 'MAKE';
    final predColor = isMake ? Colors.green : Colors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$shotNumber',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
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
                      if (shot.prediction != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: predColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            shot.prediction!,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: predColor,
                            ),
                          ),
                        ),
                      if (shot.accuracy != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${shot.accuracy!.toStringAsFixed(1)}% accuracy',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${shot.startTime.toStringAsFixed(1)}s – ${shot.endTime.toStringAsFixed(1)}s',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  if (shot.feedback != null && shot.feedback!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.sports_basketball,
                            size: 13, color: Colors.orange),
                        const SizedBox(width: 4),
                        if (shot.formScore != null)
                          Text(
                            '${shot.formScore!.toStringAsFixed(0)}/100 · ',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            shot.feedback!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
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
    );
  }
}
