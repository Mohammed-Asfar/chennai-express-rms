import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../data/floor_models.dart';

/// One table on the floor screen.
///
/// The status bar down the left edge is the signature of this screen: a cashier
/// scanning forty tables reads the colour band before anything else, and the
/// name and label confirm it. Status is never carried by colour alone — that
/// would fail anyone who cannot separate red from green, and a misread table is
/// a mis-seated customer.
class TableCard extends StatefulWidget {
  const TableCard({
    super.key,
    required this.table,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });

  final DiningTable table;
  final VoidCallback onTap;

  /// Layout changes. Shown on hover only: tapping the card seats a party, which
  /// is the action that matters during service, so editing must never be the
  /// thing a rushed hand hits first.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  State<TableCard> createState() => _TableCardState();
}

class _TableCardState extends State<TableCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final table = widget.table;
    final accent = _accentFor(table.status);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hovered ? AppColors.surfaceHover : AppColors.surface,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(
            color: _hovered ? accent : AppColors.border,
            width: AppSpacing.borderWidth,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The status band. Read first, from across the counter.
                Container(width: AppSpacing.statusBarWidth, color: accent),

                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      AppSpacing.sm + 2,
                      AppSpacing.md,
                      AppSpacing.sm + 2,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                table.name,
                                style: theme.textTheme.titleLarge,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            // The seat count gives way to the edit menu on
                            // hover — the card is too small for both.
                            if (_hovered && widget.onEdit != null)
                              SizedBox(
                                height: 18,
                                width: 22,
                                child: PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_horiz, size: 16),
                                  tooltip: 'Table setup',
                                  padding: EdgeInsets.zero,
                                  iconSize: 16,
                                  onSelected: (value) {
                                    if (value == 'edit') widget.onEdit?.call();
                                    if (value == 'delete') widget.onDelete?.call();
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'edit', child: Text('Edit table')),
                                    PopupMenuItem(value: 'delete', child: Text('Delete table')),
                                  ],
                                ),
                              )
                            else ...[
                              Text(
                                '${table.seats}',
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Icon(
                                Icons.person_outline,
                                size: 13,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ],
                          ],
                        ),

                        const Spacer(),

                        // A tinted pill rather than bare text: on a light ground
                        // the label needs a shape to sit in, or it disappears
                        // among the other small type.
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _tintFor(table.status),
                            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                          ),
                          child: Text(
                            _labelFor(table.status).toUpperCase(),
                            style: theme.textTheme.labelSmall?.copyWith(color: accent),
                          ),
                        ),

                        // Each party gets a chip so staff can pick the right one.
                        if (table.parties.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            children: [
                              for (final party in table.parties)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.surfaceSunken,
                                    borderRadius:
                                        BorderRadius.circular(AppSpacing.radiusSm),
                                    border: Border.all(color: AppColors.borderStrong),
                                  ),
                                  child: Text(
                                    party.label,
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: AppColors.ink),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _accentFor(TableStatus status) => switch (status) {
        TableStatus.free => AppColors.tableFree,
        TableStatus.occupied => AppColors.tableOccupied,
        TableStatus.reserved => AppColors.tableReserved,
      };

  static Color _tintFor(TableStatus status) => switch (status) {
        TableStatus.free => AppColors.tableFreeTint,
        TableStatus.occupied => AppColors.tableOccupiedTint,
        TableStatus.reserved => AppColors.tableReservedTint,
      };

  static String _labelFor(TableStatus status) => switch (status) {
        TableStatus.free => 'Free',
        TableStatus.occupied => 'Seated',
        TableStatus.reserved => 'Reserved',
      };
}
