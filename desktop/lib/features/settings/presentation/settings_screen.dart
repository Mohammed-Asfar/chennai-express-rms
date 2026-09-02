import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../printers/presentation/printer_settings_screen.dart';
import '../../sync/presentation/sync_screen.dart';
import 'branch_screen.dart';
import 'tax_billing_screen.dart';

/// The settings index.
///
/// A list of areas rather than one long page: printer setup, tax rules and bill
/// numbering have nothing to do with each other, and stacking them makes each
/// one harder to find.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: [
        Text('Settings', style: theme.textTheme.titleLarge),
        const SizedBox(height: AppSpacing.lg),

        _SettingsRow(
          icon: Icons.print_outlined,
          title: 'Printers',
          subtitle: 'Thermal printers for bills and kitchen tickets',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const PrinterSettingsScreen(),
            ),
          ),
        ),

        _SettingsRow(
          icon: Icons.percent,
          title: 'Tax and billing',
          subtitle: 'GST mode, default rate, bill numbering',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const TaxBillingScreen()),
          ),
        ),

        _SettingsRow(
          icon: Icons.storefront_outlined,
          title: 'Branch',
          subtitle: 'Name, address and GSTIN, as printed on the bill',
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const BranchScreen())),
        ),

        // Reachable even when healthy: "is my data backed up" is a question
        // people ask when nothing is wrong, and the sidebar badge only appears
        // when something is.
        _SettingsRow(
          icon: Icons.cloud_outlined,
          title: 'Cloud backup',
          subtitle: 'Whether your sales are copied off this PC',
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const SyncScreen())),
        ),

        // Shown but not built, so it is clear what the system will do rather
        // than leaving someone hunting for a screen that does not exist.
        const _SettingsRow(
          icon: Icons.people_outline,
          title: 'Users',
          subtitle: 'Cashier accounts and roles',
        ),
      ],
    );
  }
}

class _SettingsRow extends StatefulWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// Null for a section that is not built yet.
  final VoidCallback? onTap;

  @override
  State<_SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<_SettingsRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.onTap != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _hovered && enabled
                ? AppColors.surfaceHover
                : AppColors.surface,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    Icon(
                      widget.icon,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: enabled
                                  ? null
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (enabled)
                      const Icon(Icons.chevron_right, size: 18)
                    else
                      Text('Soon', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
