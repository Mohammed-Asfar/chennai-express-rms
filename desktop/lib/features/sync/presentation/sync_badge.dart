import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/sync_repository.dart';
import 'sync_screen.dart';

/// The cloud backup line in the sidebar, above the signed-in user.
///
/// It sits here rather than only on a settings page nobody opens: a backup
/// that stopped weeks ago is a disaster the day the PC dies, and by then the
/// warning has to have been somewhere it was seen every day.
///
/// Always present, and quiet when there is nothing wrong — a muted line
/// confirming the backup is current, with the space used beside it. It grows
/// loud only when it has something to say.
class SyncBadge extends ConsumerStatefulWidget {
  const SyncBadge({super.key});

  @override
  ConsumerState<SyncBadge> createState() => _SyncBadgeState();
}

class _SyncBadgeState extends ConsumerState<SyncBadge> {
  Timer? _timer;

  /// The status is pushed, so this only refreshes the size — which costs a
  /// cloud round trip and has nothing to push it — and rebuilds so the
  /// relative time on the line moves on.
  static const _interval = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted) return;
      ref.invalidate(cloudStorageProvider);
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(syncStreamProvider).valueOrNull;
    final storage = ref.watch(cloudStorageProvider).valueOrNull;

    // Nothing known yet. The backend being unreachable is already reported
    // elsewhere, and two alarms for one fault is noise.
    if (value == null) return const SizedBox.shrink();

    final healthy = value.healthy;

    // Quarantined rows are stuck until someone acts; everything else resolves
    // itself when the connection returns. Only the first is an alarm.
    final stuck =
        value.quarantined > 0 || (value.hasNeverSynced && value.pending > 0);

    // Green synced, red not. The light-ground versions of these are unreadable
    // on charcoal — see the note on the OnShell colours in app_colors.dart.
    //
    // Amber sits between the two for a backlog that is merely waiting: an
    // unreachable cloud fixes itself when the internet returns, and painting
    // that the same red as records the cloud has refused would cry wolf.
    final tone = healthy
        ? AppColors.successOnShell
        : stuck
        ? AppColors.dangerOnShell
        : AppColors.warningOnShell;

    return Semantics(
      button: true,
      label: '${_title(value, stuck)}. ${_detail(value, storage)}.',
      child: Material(
        color: healthy ? Colors.transparent : AppColors.shellHover,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SyncScreen()),
          ),
          child: Container(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.shellBorder)),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                Icon(
                  healthy ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                  size: 18,
                  color: tone,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title(value, stuck),
                        style: AppTextStyles.bodySmall.copyWith(
                          color: tone,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _detail(value, storage),
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.onShellMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: AppColors.onShellMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _title(SyncStatus status, bool stuck) {
    if (status.healthy) {
      return status.lastSuccessAt == null
          ? 'Backed up'
          : 'Backed up ${SyncScreen.relativeTime(status.lastSuccessAt!).toLowerCase()}';
    }
    return stuck ? 'Backup stopped' : 'Backup behind';
  }

  /// The second line: what is wrong, or how much room is left.
  ///
  /// A problem always outranks the space figure — nobody needs to know they
  /// have 500 MB free while their sales are not leaving the building.
  String _detail(SyncStatus status, CloudStorage? storage) {
    if (!status.enabled) return 'Not set up';
    if (status.quarantined > 0) return '${status.quarantined} records stuck';
    if (status.hasNeverSynced) return 'Nothing sent yet';
    if (!status.healthy) return '${status.pending} waiting';

    if (storage == null) return 'Cloud storage';
    return '${_size(storage.usedBytes)} of ${_size(storage.limitBytes)} used';
  }

  /// Sized for a person, not a sysadmin.
  static String _size(int bytes) {
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) {
      return '${(bytes / (1024 * mb)).toStringAsFixed(1)} GB';
    }
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).round()} KB';
  }
}
