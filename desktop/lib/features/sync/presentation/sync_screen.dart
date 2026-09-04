import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/sync_repository.dart';
import 'purge_dialog.dart';

/// Cloud backup: what state it is in, and the two things that can be done
/// about it.
///
/// Written for whoever runs the restaurant, not for whoever wrote the sync
/// worker. The question being answered is "is my trading data safe anywhere
/// other than this PC", and the answer has to be readable without knowing what
/// a foreign key is.
class SyncScreen extends ConsumerStatefulWidget {
  const SyncScreen({super.key});

  /// Relative, because "3 hours ago" answers the question and a timestamp
  /// makes the reader do the subtraction.
  ///
  /// Public because the sidebar badge shows the same phrase, and because the
  /// wording is the whole point of the line — "1 minutes ago" is the kind of
  /// thing nobody notices until a client does.
  static String relativeTime(DateTime at, {DateTime? now}) {
    final gap = (now ?? DateTime.now()).difference(at);

    // A clock that has drifted, or a backup stamped a moment in the future by
    // a server slightly ahead. "-1 minutes ago" would look broken.
    if (gap.isNegative || gap.inMinutes < 1) return 'Just now';

    if (gap.inMinutes < 60) {
      return '${gap.inMinutes} minute${gap.inMinutes == 1 ? '' : 's'} ago';
    }
    if (gap.inHours < 24) {
      return '${gap.inHours} hour${gap.inHours == 1 ? '' : 's'} ago';
    }
    return '${gap.inDays} day${gap.inDays == 1 ? '' : 's'} ago';
  }

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  bool _busy = false;
  String? _error;
  Timer? _tick;

  /// The status arrives pushed, but the relative times on screen are computed
  /// from the clock — "1 minute ago" has to become "2 minutes ago" with no new
  /// data at all. This tick only rebuilds; it fetches nothing.
  static const _interval = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(_interval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStreamProvider);

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

            const SizedBox(height: AppSpacing.lg),
            const _StorageCard(),

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

            // Set apart from the backup actions above, and below them.
            // Everything else on this screen protects data; this is the one
            // control that destroys it, and it should not sit in the same row
            // as the button someone presses when they are worried.
            const SizedBox(height: AppSpacing.xxl),
            const Divider(),
            const SizedBox(height: AppSpacing.lg),

            Text('Storage', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Old bills can be cleared from this PC and the cloud once you have '
              'exported them. Your menu, tables, staff and settings are never '
              'touched.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _clearOldData(context),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Clear old data'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearOldData(BuildContext context) async {
    final cleared = await showDialog<bool>(
      context: context,
      builder: (_) => const PurgeDialog(),
    );
    // The counts on this screen are now wrong, and a stale "waiting to send"
    // after a purge reads as data that failed to back up. This screen reads the
    // stream, so that is what has to be rebuilt.
    if (cleared == true && mounted) {
      ref.invalidate(syncStreamProvider);
      ref.invalidate(syncStatusProvider);
    }
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
      // The status arrives on its own — the cycle this triggered broadcasts
      // when it finishes. Only the size needs asking for, because a push that
      // landed changed it and nothing pushes that.
      ref.invalidate(cloudStorageProvider);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Cloud room used, and how long it will last.
///
/// Present even when everything is fine, because the question it answers is
/// "am I about to be asked to pay for this" — and that gets asked when nothing
/// is wrong. Silent while it cannot be measured: a missing size is not a fault.
class _StorageCard extends ConsumerWidget {
  const _StorageCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(cloudStorageProvider).valueOrNull;
    if (storage == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final tight = storage.isRunningOut;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Cloud space used', style: theme.textTheme.titleSmall),
              Text(
                '${_size(storage.usedBytes)} of ${_size(storage.limitBytes)}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: tight ? AppColors.danger : AppColors.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),

          ClipRRect(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: LinearProgressIndicator(
              // A hair of fill at 1%, so the bar reads as a measurement rather
              // than as an empty control someone has to interpret.
              value: storage.fraction.clamp(0.01, 1.0),
              minHeight: 8,
              backgroundColor: AppColors.chartTrack,
              valueColor: AlwaysStoppedAnimation(
                tight ? AppColors.danger : AppColors.success,
              ),
            ),
          ),

          const SizedBox(height: AppSpacing.sm),
          Text(_summary(storage), style: theme.textTheme.bodySmall),

          // Only when it starts to matter. Naming the biggest table while 2%
          // is used would invite someone to optimise nothing.
          if (tight && storage.largest.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Largest: ${storage.largest.take(3).map((l) => '${l.table} ${_size(l.bytes)}').join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  /// The projection in words, and honest about not having one.
  static String _summary(CloudStorage s) {
    final used = '${s.percent}% used';

    if (s.yearsRemaining == null) {
      return s.daysMeasured == 0
          ? '$used. Nothing billed yet, so there is nothing to project from.'
          : '$used. Too few trading days so far to estimate how long it lasts.';
    }

    final years = s.yearsRemaining!;
    final rate = '${s.billsPerDay.round()} bills a day';

    if (years >= 50) {
      return '$used. At $rate this will not run out.';
    }
    if (years >= 2) {
      return '$used. At $rate there is room for about ${years.round()} more years.';
    }
    if (years >= 1) {
      return '$used. At $rate there is about a year left.';
    }

    final months = (years * 12).round();
    return '$used. At $rate there is about '
        '$months month${months == 1 ? '' : 's'} left.';
  }

  /// Sized for a person, not a sysadmin: MB and GB, one decimal.
  static String _size(int bytes) {
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) return '${(bytes / (1024 * mb)).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).round()} KB';
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
              : SyncScreen.relativeTime(status.lastSuccessAt!),
        ),
        // Separate from the line above, and the difference is the point: on a
        // quiet afternoon nothing changes, so the last push can be hours old
        // while the system is checking every few minutes and is perfectly fine.
        // Without this line that gap looks like neglect.
        if (status.lastAttemptAt != null)
          _Fact(
            label: 'Last checked',
            value: SyncScreen.relativeTime(status.lastAttemptAt!),
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
