import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../data/printer_repository.dart';

/// Everything waiting or stuck in the print queue.
final printQueueProvider = FutureProvider<List<PrintJob>>((ref) {
  return ref.watch(printerRepositoryProvider).queue();
});

/// The print queue, beside the printer list.
///
/// Until now a failed kitchen ticket surfaced nowhere: the order saved, the
/// paper never came out, and nothing in the app said so. This is where that
/// becomes visible and can be acted on.
class PrintQueuePanel extends ConsumerStatefulWidget {
  const PrintQueuePanel({super.key});

  @override
  ConsumerState<PrintQueuePanel> createState() => _PrintQueuePanelState();
}

class _PrintQueuePanelState extends ConsumerState<PrintQueuePanel> {
  Timer? _poll;

  /// Jobs with a request in flight, so a second tap cannot double-send.
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    // A pending job is retried by a backend timer, so its status changes
    // without anything happening in the UI. Polling keeps the panel honest;
    // the query is small and local.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) ref.invalidate(printQueueProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final queue = ref.watch(printQueueProvider);
    final jobs = queue.valueOrNull ?? const <PrintJob>[];
    final stuck = jobs.where((j) => j.hasFailed).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Print queue', style: theme.textTheme.titleMedium),
            ),
            if (stuck > 0)
              _Pill(
                label: '$stuck stuck',
                colour: AppColors.danger,
                background: AppColors.dangerTint,
              ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(printQueueProvider),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Tickets waiting to print, and ones that gave up.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.md),

        Expanded(
          child: switch (queue) {
            AsyncError(:final error) => _Message(text: 'Could not load: $error'),
            // Only the very first load shows a spinner. Polling every five
            // seconds must not make the panel flicker.
            AsyncLoading() when jobs.isEmpty => const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            _ when jobs.isEmpty => const _NothingQueued(),
            _ => ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: jobs.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (_, i) => _JobCard(
                job: jobs[i],
                busy: _busy.contains(jobs[i].id),
                onRetry: () => _retry(jobs[i]),
                onCancel: () => _cancel(jobs[i]),
              ),
            ),
          },
        ),
      ],
    );
  }

  Future<void> _run(PrintJob job, Future<String?> Function() action) async {
    if (_busy.contains(job.id)) return;
    setState(() => _busy.add(job.id));

    final messenger = ScaffoldMessenger.of(context);
    try {
      final message = await action();
      if (message != null) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(job.id));
      ref.invalidate(printQueueProvider);
    }
  }

  Future<void> _retry(PrintJob job) => _run(job, () async {
    final printed = await ref.read(printerRepositoryProvider).retryJob(job.id);
    return printed
        ? '${job.label} printed'
        : 'Still could not print. Check the printer is on and connected.';
  });

  /// Confirmed, because a cancelled kitchen ticket is one the kitchen never
  /// sees — that has to be a deliberate choice, not a mis-tap.
  Future<void> _cancel(PrintJob job) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cancel this ${job.label.toLowerCase()}?'),
        content: const Text(
          'It will not print, and it leaves the queue. If the kitchen still '
          'needs it, tell them by hand.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel it'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _run(job, () async {
      await ref.read(printerRepositoryProvider).cancelJob(job.id);
      return '${job.label} cancelled';
    });
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.busy,
    required this.onRetry,
    required this.onCancel,
  });

  final PrintJob job;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = job.hasFailed;

    return Container(
      decoration: BoxDecoration(
        color: failed ? AppColors.dangerTint : AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: failed ? AppColors.danger : AppColors.border,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.schedule,
                size: 18,
                color: failed ? AppColors.danger : AppColors.inkMuted,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(job.label, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(_detail(), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),

          if (failed && job.lastError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              job.lastError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.danger,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(right: AppSpacing.md),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              TextButton(
                onPressed: busy ? null : onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: AppSpacing.xs),
              // Offered on a pending job too. The sweep will get to it, but a
              // cook waiting at the pass should not have to wait for the next
              // tick, and the backend only sends a job that is still pending
              // so pressing this cannot produce a second ticket.
              ElevatedButton(
                onPressed: busy ? null : onRetry,
                child: Text(failed ? 'Retry' : 'Send now'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Where it was going, when it arrived, and how hard it has tried.
  String _detail() {
    final parts = <String>[
      job.printerName ?? 'Printer removed',
      if (job.createdAt != null) _clock(job.createdAt!),
      if (job.attempts > 0)
        job.attempts == 1 ? '1 try' : '${job.attempts} tries',
    ];
    return parts.join('  ·  ');
  }

  static String _clock(DateTime at) {
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    final minute = at.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${at.hour < 12 ? 'am' : 'pm'}';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.colour,
    required this.background,
  });

  final String label;
  final Color colour;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colour),
      ),
    );
  }
}

class _NothingQueued extends StatelessWidget {
  const _NothingQueued();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: AppSpacing.xl,
            color: AppColors.success,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text('Nothing waiting', style: theme.textTheme.bodyLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Everything sent has printed.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
