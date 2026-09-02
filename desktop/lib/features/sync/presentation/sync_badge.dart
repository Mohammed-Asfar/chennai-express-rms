import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/sync_repository.dart';
import 'sync_screen.dart';

/// The cloud backup indicator, in the sidebar above the signed-in user.
///
/// It sits here rather than on a settings page nobody opens. A backup that
/// stopped weeks ago is only a disaster when the PC dies, and by then the
/// warning has to have been somewhere it was seen every day.
///
/// Silent when healthy: a green tick every day trains people to ignore the
/// spot, and then the red one is ignored too.
class SyncBadge extends ConsumerStatefulWidget {
  const SyncBadge({super.key});

  @override
  ConsumerState<SyncBadge> createState() => _SyncBadgeState();
}

class _SyncBadgeState extends ConsumerState<SyncBadge> {
  Timer? _timer;

  /// Slow on purpose. This is a background health check, not a live readout,
  /// and the till has better things to do during service.
  static const _interval = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) {
      if (mounted) ref.invalidate(syncStatusProvider);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(syncStatusProvider);

    // A status that cannot be fetched says nothing: the backend being
    // unreachable is already reported elsewhere, and two alarms for one fault
    // is noise.
    final value = status.valueOrNull;
    if (value == null || value.healthy) return const SizedBox.shrink();

    // Quarantined rows are stuck until someone acts; everything else resolves
    // itself when the connection returns. Only the first is an alarm.
    final stuck = value.quarantined > 0 || (value.hasNeverSynced && value.pending > 0);
    final tone = stuck ? AppColors.danger : AppColors.warning;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Material(
        color: AppColors.shellHover,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SyncScreen()),
          ),
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off_outlined, size: 16, color: tone),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stuck ? 'Backup stopped' : 'Backup behind',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: tone,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _detail(value),
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.onShellMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _detail(SyncStatus status) {
    if (!status.enabled) return 'Not set up';
    if (status.quarantined > 0) return '${status.quarantined} records stuck';
    if (status.hasNeverSynced) return 'Nothing sent yet';
    return '${status.pending} waiting';
  }
}
