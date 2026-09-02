import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../data/booking_models.dart';

/// One booking on the day's list.
///
/// The time is the first thing read and set largest — staff scan this column
/// for what is due next. Everything else supports it.
class BookingRow extends StatelessWidget {
  const BookingRow({
    super.key,
    required this.booking,
    required this.onSeat,
    required this.onEdit,
    required this.onNoShow,
    required this.onCancel,
  });

  final Booking booking;
  final VoidCallback onSeat;
  final VoidCallback onEdit;
  final VoidCallback onNoShow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final closed = !booking.isOpen;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: booking.isOverdue ? AppColors.warning : AppColors.border,
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              _time(context, booking.reservedAt),
              style: theme.textTheme.titleMedium?.copyWith(
                // A closed booking is history: it stays legible but stops
                // competing with the ones still to arrive.
                color: closed ? AppColors.inkMuted : AppColors.ink,
              ),
            ),
          ),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        booking.customerName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: closed ? AppColors.inkMuted : AppColors.ink,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (booking.customerPhone != null &&
                        booking.customerPhone!.isNotEmpty) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        booking.customerPhone!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${booking.partySize} guests · ${booking.tableLabel}',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (booking.notes != null && booking.notes!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    booking.notes!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),

          // Tables that do not seat the party, flagged while there is still
          // time to add another rather than when they are at the door.
          if (booking.isOpen && booking.isUndersized) ...[
            const _Pill(
              label: 'Tight fit',
              tone: AppColors.warning,
              tint: AppColors.warningTint,
            ),
            const SizedBox(width: AppSpacing.sm),
          ],

          if (booking.isOverdue) ...[
            const _Pill(
              label: 'Late',
              tone: AppColors.warning,
              tint: AppColors.warningTint,
            ),
            const SizedBox(width: AppSpacing.sm),
          ],

          if (closed) ...[
            _Pill(
              label: booking.status.label,
              tone: booking.status == BookingStatus.seated
                  ? AppColors.success
                  : AppColors.inkMuted,
              tint: booking.status == BookingStatus.seated
                  ? AppColors.successTint
                  : AppColors.surfaceSunken,
            ),
            const SizedBox(width: AppSpacing.sm),
          ],

          if (booking.isOpen) ...[
            FilledButton(onPressed: onSeat, child: const Text('Seat')),
            const SizedBox(width: AppSpacing.xs),
            MenuAnchor(
              menuChildren: [
                MenuItemButton(onPressed: onEdit, child: const Text('Edit')),
                MenuItemButton(
                  onPressed: onNoShow,
                  child: const Text('Mark no-show'),
                ),
                MenuItemButton(
                  onPressed: onCancel,
                  child: const Text('Cancel booking'),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.more_vert),
                tooltip: 'More',
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _time(BuildContext context, DateTime at) {
    return TimeOfDay.fromDateTime(at).format(context);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone, required this.tint});

  final String label;
  final Color tone;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      // Colour is never the only carrier: every pill states its meaning in
      // words, because a status read wrong on a busy floor costs a table.
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: tone,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
