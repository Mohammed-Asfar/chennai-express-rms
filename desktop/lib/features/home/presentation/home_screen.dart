import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_spacing.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/change_password_screen.dart';
import '../../updates/presentation/update_controller.dart';
import '../../updates/presentation/update_dialog.dart';

/// Placeholder shell. The POS, menu, tables and billing screens land here as
/// they are built.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chennai Express'),
        actions: [
          if (user != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Center(
                child: Text(
                  '${user.fullName}  ·  ${user.isAdmin ? 'Admin' : 'Cashier'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          const SizedBox(width: AppSpacing.sm),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Account',
            onSelected: (value) {
              switch (value) {
                case 'password':
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ChangePasswordScreen(forced: false),
                    ),
                  );
                case 'updates':
                  _checkForUpdates(context, ref);
                case 'logout':
                  ref.read(authControllerProvider.notifier).logout();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'password', child: Text('Change password')),
              PopupMenuItem(value: 'updates', child: Text('Check for updates')),
              PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.point_of_sale_outlined,
              size: AppSpacing.xxl * 2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Signed in', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'The POS screens are next.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            const _VersionRow(),
          ],
        ),
      ),
    );
  }
}

Future<void> _checkForUpdates(BuildContext context, WidgetRef ref) async {
  final controller = ref.read(updateControllerProvider.notifier);
  // A manual check ignores an earlier dismissal - the user asked for it.
  await controller.check(respectDismissal: false);
  if (!context.mounted) return;

  if (ref.read(updateControllerProvider).hasUpdate) {
    await UpdateDialog.show(context);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('You are on the latest version.')),
    );
  }
}

class _VersionRow extends ConsumerWidget {
  const _VersionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final version = state.result?.currentVersion;
    return Text(
      version == null ? '' : 'Version $version',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
