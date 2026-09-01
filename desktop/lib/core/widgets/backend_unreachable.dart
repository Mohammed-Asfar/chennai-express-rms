import 'package:flutter/material.dart';
import '../theme/app_spacing.dart';

/// Shown when the local backend is not answering.
///
/// The client holds no data, so this is the difference between an actionable
/// message and a blank screen the user cannot interpret.
class BackendUnreachable extends StatelessWidget {
  const BackendUnreachable({super.key, required this.onRetry, this.isRetrying = false});

  final VoidCallback onRetry;
  final bool isRetrying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off, size: AppSpacing.xxl, color: theme.colorScheme.error),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Billing service not running',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'The application cannot reach the local billing service. '
                  'It may still be starting up.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpacing.lg),
                ElevatedButton.icon(
                  onPressed: isRetrying ? null : onRetry,
                  icon: isRetrying
                      ? const SizedBox(
                          height: AppSpacing.md,
                          width: AppSpacing.md,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(isRetrying ? 'Checking...' : 'Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
