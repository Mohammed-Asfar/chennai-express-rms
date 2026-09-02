import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/widgets/app_sidebar.dart';
import '../../auth/data/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../sync/presentation/sync_badge.dart';
import '../../auth/presentation/change_password_screen.dart';
import '../../floor/data/floor_repository.dart';
import '../../floor/presentation/floor_screen.dart';
import '../../billing/presentation/bills_screen.dart';
import '../../bookings/data/booking_repository.dart';
import '../../bookings/presentation/bookings_screen.dart';
import '../../menu/presentation/menu_admin_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../order/data/order_repository.dart';
import '../../order/presentation/order_screen.dart';
import '../../reports/presentation/reports_screen.dart';
import '../../updates/presentation/update_controller.dart';
import '../../updates/presentation/update_dialog.dart';

/// The shell staff work in all day.
///
/// Charcoal sidebar on the left, work area on the right — the 30/60 split. The
/// accent appears only on the active nav item and the primary action.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _selected = 0;

  /// Sections not built yet are shown but disabled, so staff can see what the
  /// system will do rather than wondering whether it is missing.
  static const _items = [
    SidebarItem(icon: Icons.grid_view_rounded, label: 'Floor'),
    SidebarItem(icon: Icons.receipt_long_outlined, label: 'Bills'),
    SidebarItem(icon: Icons.restaurant_menu, label: 'Menu'),
    SidebarItem(icon: Icons.event_seat_outlined, label: 'Bookings'),
    SidebarItem(icon: Icons.insights_outlined, label: 'Reports'),
    SidebarItem(icon: Icons.tune, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          AppSidebar(
            items: _items,
            selectedIndex: _selected,
            onSelect: (index) => setState(() => _selected = index),
            footer: const _SidebarFooter(),
          ),
          Expanded(
            child: Column(
              children: [
                _WorkHeader(
                  title: _items[_selected].label,
                  // Takeaway belongs to the floor. Showing it while editing the
                  // menu would offer an action that has nothing to do with the
                  // screen in front of you.
                  onTakeaway: _selected == 0 ? () => _startTakeaway(context) : null,
                  onRefresh: switch (_selected) {
                    0 => () => ref.invalidate(floorProvider),
                    1 => () => ref.invalidate(billListProvider),
                    3 => () => ref.invalidate(bookingsProvider),
                    4 => () => refreshReports(ref),
                    _ => null,
                  },
                ),
                Expanded(
                  child: switch (_selected) {
                    0 => const FloorScreen(),
                    1 => const BillsScreen(),
                    2 => const MenuAdminScreen(),
                    3 => const BookingsScreen(),
                    4 => const ReportsScreen(),
                    5 => const SettingsScreen(),
                    _ => const _ComingSoon(),
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startTakeaway(BuildContext context) async {
    try {
      final order = await ref.read(orderRepositoryProvider).startTakeaway();
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => OrderScreen(orderId: order.id)),
      );
      ref.invalidate(floorProvider);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

/// The bar above the work area: what you are looking at, and what you can do.
class _WorkHeader extends StatelessWidget {
  const _WorkHeader({
    required this.title,
    required this.onTakeaway,
    required this.onRefresh,
  });

  final String title;

  /// Null on screens the action does not belong to.
  final VoidCallback? onTakeaway;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 68,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Text(title, style: theme.textTheme.headlineMedium),
          const Spacer(),

          if (onRefresh != null) ...[
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: 'Refresh',
              onPressed: onRefresh,
            ),
            const SizedBox(width: AppSpacing.sm),
          ],

          // Takeaway is a first-class action, not a menu item: it is the second
          // most common way an order starts.
          if (onTakeaway != null)
            ElevatedButton.icon(
              onPressed: onTakeaway,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Takeaway'),
            ),
        ],
      ),
    );
  }
}

/// Who is signed in, and the account menu. Lives at the foot of the sidebar so
/// it is always reachable but never in the way.
class _SidebarFooter extends ConsumerWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).user;
    if (user == null) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Above the user, where the eye already goes. Renders nothing at all
        // while the backup is healthy.
        const SyncBadge(),
        _UserRow(user: user),
      ],
    );
  }
}

class _UserRow extends ConsumerWidget {
  const _UserRow({required this.user});

  final User user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Container(
            height: 32,
            width: 32,
            decoration: BoxDecoration(
              color: AppColors.shellHover,
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            ),
            alignment: Alignment.center,
            child: Text(
              user.fullName.characters.first.toUpperCase(),
              style: AppTextStyles.titleMedium.copyWith(color: AppColors.onShell),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.fullName,
                  style: AppTextStyles.bodyMedium.copyWith(color: AppColors.onShell),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  user.isAdmin ? 'Admin' : 'Cashier',
                  style: AppTextStyles.bodySmall.copyWith(color: AppColors.onShellMuted),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18, color: AppColors.onShellMuted),
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
              PopupMenuDivider(),
              PopupMenuItem(value: 'logout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
    );
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
}

class _ComingSoon extends StatelessWidget {
  const _ComingSoon();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.construction_outlined,
            size: AppSpacing.xxl,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Not built yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text('This section is on the way.', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
