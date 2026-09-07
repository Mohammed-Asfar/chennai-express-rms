import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_spacing.dart';
import 'activation_controller.dart';

/// Warns that a licence has been withdrawn, above the work area.
///
/// Shown only while a revocation is counting down. **Being offline does not
/// raise it** — a branch with no internet bills indefinitely, so a banner there
/// would announce a deadline that does not exist.
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
