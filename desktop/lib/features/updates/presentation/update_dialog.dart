import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/error_banner.dart';
import 'update_controller.dart';

/// Shown when a newer release is available.
///
/// A forced update has no dismiss path — after a billing-math fix, an old build
/// must not keep running because staff kept postponing.
class UpdateDialog extends ConsumerWidget {
  const UpdateDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const UpdateDialog(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final release = state.release;
    final theme = Theme.of(context);

    if (release == null) return const SizedBox.shrink();

    final isBusy = state.phase == UpdatePhase.downloading ||
        state.phase == UpdatePhase.verifying ||
        state.phase == UpdatePhase.ready;

    return PopScope(
      // Escape and the back gesture must not bypass a forced update.
      canPop: !state.isForced && !isBusy,
      child: AlertDialog(
        icon: Icon(
          state.isForced ? Icons.warning_amber_rounded : Icons.system_update_alt,
          color: state.isForced ? theme.colorScheme.error : theme.colorScheme.primary,
          size: AppSpacing.xl,
        ),
        title: Text(state.isForced ? 'Update required' : 'Update available'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Version ${release.version}  ·  ${release.readableSize}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'You are on version ${state.result?.currentVersion ?? '-'}.',
                style: theme.textTheme.bodySmall,
              ),

              if (state.isForced) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Text(
                    'This update is required before you can continue billing.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              ],

              if (release.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text("What's new", style: theme.textTheme.titleMedium),
                const SizedBox(height: AppSpacing.xs),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Text(release.releaseNotes, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ],

              if (state.phase == UpdatePhase.failed && state.errorMessage != null) ...[
                const SizedBox(height: AppSpacing.md),
                ErrorBanner(message: state.errorMessage!),
              ],

              if (state.phase == UpdatePhase.downloading) ...[
                const SizedBox(height: AppSpacing.md),
                LinearProgressIndicator(value: state.total == 0 ? null : state.progress),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${(state.progress * 100).toStringAsFixed(0)}% downloaded',
                  style: theme.textTheme.bodySmall,
                ),
              ],

              if (state.phase == UpdatePhase.ready) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Starting the installer. The application will close.',
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (state.phase == UpdatePhase.downloading)
            TextButton(
              onPressed: controller.cancelDownload,
              child: const Text('Cancel'),
            )
          else ...[
            if (!state.isForced)
              TextButton(
                onPressed: () async {
                  await controller.dismiss();
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: const Text('Later'),
              ),
            ElevatedButton(
              onPressed: isBusy ? null : controller.downloadAndInstall,
              child: Text(
                state.phase == UpdatePhase.failed ? 'Try again' : 'Update now',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
