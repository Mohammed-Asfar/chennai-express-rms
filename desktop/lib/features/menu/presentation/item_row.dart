import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../data/menu_admin_models.dart';

/// One dish in the management list.
///
/// The row shows what an admin checks at a glance: the name, its portions and
/// prices, the GST rate, and whether the till is currently offering it. An
/// unavailable dish stays visible but reads as muted — hiding it would leave
/// staff wondering where it went.
class ItemRow extends StatefulWidget {
  const ItemRow({
    super.key,
    required this.item,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  final AdminMenuItem item;
  final VoidCallback onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  State<ItemRow> createState() => _ItemRowState();
}

class _ItemRowState extends State<ItemRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    final off = !item.isAvailable;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _hovered ? AppColors.surfaceHover : AppColors.surface,
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
            border: Border.all(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onEdit,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  item.name,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: off
                                        ? theme.colorScheme.onSurfaceVariant
                                        : null,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (off) ...[
                                const SizedBox(width: AppSpacing.sm),
                                _Pill(
                                  label: 'OFF',
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ],
                            ],
                          ),
                          if (item.description != null &&
                              item.description!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              item.description!,
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            children: [
                              for (final variant in item.variants)
                                _VariantChip(variant: variant),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(width: AppSpacing.md),

                    // The rate matters when checking a bill, so it is shown
                    // rather than buried in the edit dialog.
                    Text(
                      'GST ${Money.formatRate(item.taxRate)}%',
                      style: theme.textTheme.bodySmall,
                    ),

                    const SizedBox(width: AppSpacing.md),

                    Switch(
                      value: item.isAvailable,
                      onChanged: widget.onToggle,
                    ),

                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz, size: 18),
                      tooltip: 'Dish actions',
                      onSelected: (value) {
                        if (value == 'edit') widget.onEdit();
                        if (value == 'delete') widget.onDelete();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
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

/// A portion and its price.
class _VariantChip extends StatelessWidget {
  const _VariantChip({required this.variant});

  final AdminVariant variant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A sold-out portion is struck through here rather than hidden: the price
    // still matters, and someone scanning the menu needs to see at a glance
    // which sizes are off without opening every item.
    final off = !variant.isAvailable;
    final style = theme.textTheme.bodySmall?.copyWith(
      color: off ? AppColors.inkFaint : null,
      decoration: off ? TextDecoration.lineThrough : null,
    );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: off ? AppColors.surface : AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(variant.name, style: style),
          const SizedBox(width: AppSpacing.sm),
          Text(
            Money.formatWithSymbol(variant.price),
            style: style?.copyWith(color: off ? AppColors.inkFaint : AppColors.ink),
          ),
          if (off) ...[
            const SizedBox(width: AppSpacing.xs),
            Text('sold out', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
    );
  }
}
