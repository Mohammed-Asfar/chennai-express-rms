import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/sync_repository.dart';

/// Cloud backup: what state it is in, and the two things that can be done
/// about it.
///
/// Written for whoever runs the restaurant, not for whoever wrote the sync
/// worker. The question being answered is "is my trading data safe anywhere
/// other than this PC", and the answer has to be readable without knowing what
/// a foreign key is.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Cloud backup')),
      body: status.when(
        loading: () => const AppLoading(message: 'Checking the backup'),
        error: (error, _) => Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: ErrorBanner(message: '$error'),
        ),
        data: (value) => ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            _Verdict(status: value),
            const SizedBox(height: AppSpacing.lg),

            _Facts(status: value),

            if (value.lastError != null) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Reported problem', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              // The raw database message. Meaningless to most people, and the
              // only thing that identifies the fault to whoever can fix it.
              SelectableText(
                value.lastError!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: AppSpacing.lg),
              ErrorBanner(message: _error!),
            ],

            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _busy || !value.enabled ? null : _syncNow,
                  icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: const Text('Back up now'),
                ),
                const SizedBox(width: AppSpacing.sm),
                // Offered whenever anything is wrong, not only once rows have
                // been given up on. The commonest fault is a branch or user
                // the cloud is missing, which rejects every bill while nothing
                // is quarantined yet — and this is the button that repairs it.
                if (!value.healthy && value.enabled)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _retry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(
                      value.quarantined > 0
                          ? 'Retry ${value.quarantined} stuck'
                          : 'Repair and retry',
                    ),
                  ),
              ],
            ),

            if (!value.healthy && value.enabled) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Retry sends the branch and staff details again first, then '
                'everything waiting. If the cause is still there it will fail '
                'again — the records stay safe on this PC either way.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _syncNow() => _run((r) => r.syncNow());

  Future<void> _retry() => _run((r) => r.retryFailed());

  Future<void> _run(Future<SyncStatus> Function(SyncRepository) action) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await action(ref.read(syncRepositoryProvider));
      ref.invalidate(syncStatusProvider);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The headline: safe, or not.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final healthy = status.healthy;

    final tone = healthy ? AppColors.success : AppColors.danger;
    final tint = healthy ? AppColors.successTint : AppColors.dangerTint;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            healthy ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: tone,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  healthy
                      ? 'Your sales are backed up to the cloud'
                      : 'Your sales are only on this PC',
                  style: theme.textTheme.titleMedium?.copyWith(color: tone),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  status.problem ??
                      'Everything recorded here has been copied off this machine.',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts({required this.status});

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Fact(
          label: 'Last backed up',
          value: status.lastSuccessAt == null
              ? 'Never'
              : _when(status.lastSuccessAt!),
        ),
        _Fact(label: 'Waiting to send', value: '${status.pending}'),
        _Fact(
          label: 'Stuck',
          value: '${status.quarantined}',
          tone: status.quarantined > 0 ? AppColors.danger : null,
        ),
      ],
    );
  }

  /// Relative, because "3 hours ago" answers the question and a timestamp
  /// makes the reader do the subtraction.
  static String _when(DateTime at) {
    final gap = DateTime.now().difference(at);
    if (gap.inMinutes < 1) return 'Just now';
    if (gap.inMinutes < 60) return '${gap.inMinutes} minutes ago';
    if (gap.inHours < 24) {
      return '${gap.inHours} hour${gap.inHours == 1 ? '' : 's'} ago';
    }
    return '${gap.inDays} day${gap.inDays == 1 ? '' : 's'} ago';
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.tone});

  final String label;
  final String value;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(color: tone),
          ),
        ],
      ),
    );
  }
}
