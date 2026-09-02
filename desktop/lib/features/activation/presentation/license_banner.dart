import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_spacing.dart';
import 'activation_controller.dart';

/// Warns that the licence is running out of grace, above the work area.
///
/// Only appears in the last few days of the grace period. Earlier than that a
/// brief internet outage is normal and a banner would be noise staff learn to
/// ignore — which is exactly what must not happen on the day it matters.
///
/// It never blocks anything. Billing continues underneath it.
class LicenseBanner extends ConsumerWidget {
  const LicenseBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(activationControllerProvider).status;
    if (status == null || !status.showBanner) return const SizedBox.shrink();

    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      color: theme.colorScheme.error.withValues(alpha: 0.10),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              status.message!,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () => ref.read(activationControllerProvider.notifier).check(),
            child: const Text('Retry now'),
          ),
        ],
      ),
    );
  }
}
