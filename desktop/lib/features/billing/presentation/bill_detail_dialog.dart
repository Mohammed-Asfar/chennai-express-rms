import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../printers/data/printer_repository.dart';
import '../data/bill_models.dart';
import '../data/bill_repository.dart';

final _billDetailProvider = FutureProvider.family<Bill, String>((ref, billId) {
  return ref.watch(billRepositoryProvider).fetch(billId);
});

/// Everything on one issued bill: what was sold, the tax, and how it was paid.
///
/// The figures are the ones recorded at the time, not recomputed — this is a
/// record of what the customer was charged, and it must not drift.
class BillDetailDialog extends ConsumerWidget {
  const BillDetailDialog({super.key, required this.billId});

  final String billId;

  static Future<void> show(BuildContext context, String billId) {
    return showDialog<void>(
      context: context,
      builder: (_) => BillDetailDialog(billId: billId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(_billDetailProvider(billId));
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: maxHeight),
        child: detail.when(
          loading: () => const SizedBox(
            height: 220,
            child: AppLoading(message: 'Loading bill'),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ErrorBanner(message: '$error'),
          ),
          data: (bill) => _Content(bill: bill),
        ),
      ),
    );
  }
}

class _Content extends ConsumerWidget {
  const _Content({required this.bill});

  final Bill bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bill.billNumber, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(_subtitle(), style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              _StatusPill(status: bill.paymentStatus),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),

        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _Section(
                title: 'Items',
                child: Column(
                  children: [
                    for (final item in bill.items) _ItemRow(item: item),
                    if (bill.items.isEmpty)
                      Text(
                        'No items recorded.',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),

              const SizedBox(height: AppSpacing.md),

              _Section(
                title: 'Total',
                child: Column(
                  children: [
                    _row(theme, 'Subtotal', bill.subtotal),
                    if (bill.discountAmount > 0)
                      _row(theme, 'Discount', -bill.discountAmount),
                    // A bill mixing 5% and 18% items shows each rate on its own
                    // line, so the GST can be checked group by group. With a
                    // single rate that would just repeat the totals below, so
                    // only the summed split is shown.
                    if (bill.taxBreakdown.length > 1)
                      for (final group in bill.taxBreakdown)
                        _row(
                          theme,
                          'GST ${Money.formatRate(group.rate)}% on '
                          '${Money.formatWithSymbol(group.base)}',
                          group.cgst + group.sgst,
                        ),
                    _row(theme, 'CGST', bill.cgst),
                    _row(theme, 'SGST', bill.sgst),
                    if (bill.roundOff != 0)
                      _row(theme, 'Round off', bill.roundOff),
                    const Divider(height: AppSpacing.lg),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Total', style: theme.textTheme.titleLarge),
                        Text(
                          Money.formatWithSymbol(bill.total),
                          style: theme.textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: AppSpacing.md),

              _Section(
                title: 'Payment',
                child: Column(
                  children: [
                    for (final payment in bill.livePayments)
                      _row(theme, payment.mode.label, payment.amount),
                    if (bill.livePayments.isEmpty)
                      Text(
                        'Nothing has been paid on this bill.',
                        style: theme.textTheme.bodySmall,
                      ),
                    if (bill.outstanding > 0) ...[
                      const Divider(height: AppSpacing.lg),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Still due',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                          Text(
                            Money.formatWithSymbol(bill.outstanding),
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceSunken,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: SizedBox(
            height: AppSpacing.minTapTarget,
            child: OutlinedButton.icon(
              onPressed: () => _print(context, ref),
              icon: const Icon(Icons.print_outlined, size: 18),
              // Any print from here is a second copy, and the paper says so.
              label: const Text('Print a duplicate'),
            ),
          ),
        ),
      ],
    );
  }

  String _subtitle() {
    final at = bill.createdAt;
    final time = at == null
        ? ''
        : '${at.hour > 12 ? at.hour - 12 : (at.hour == 0 ? 12 : at.hour)}'
              ':${at.minute.toString().padLeft(2, '0')} '
              '${at.hour >= 12 ? 'pm' : 'am'}';
    final order = bill.orderNo == null ? '' : 'Order #${bill.orderNo}';
    return [
      bill.businessDate,
      time,
      bill.placeLabel,
      order,
    ].where((s) => s.isNotEmpty).join('  ·  ');
  }

  Widget _row(ThemeData theme, String label, int paise) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodyMedium),
        Text(Money.formatWithSymbol(paise), style: theme.textTheme.bodyMedium),
      ],
    ),
  );

  Future<void> _print(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(printerRepositoryProvider)
          .printBill(bill.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.printed
                ? 'Duplicate printed'
                : result.error ?? 'The printer did not respond',
          ),
        ),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final BillItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text('${item.qty}x', style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.displayName, style: theme.textTheme.bodyMedium),
                // The unit price only earns its place when it is not obvious
                // from the line total.
                if (item.qty > 1)
                  Text(
                    '${Money.formatWithSymbol(item.unitPrice)} each'
                    '  ·  GST ${Money.formatRate(item.taxRate)}%',
                    style: theme.textTheme.bodySmall,
                  )
                else
                  Text(
                    'GST ${Money.formatRate(item.taxRate)}%',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          Text(
            Money.formatWithSymbol(item.lineTotal),
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final PaymentStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (label, colour, tint) = switch (status) {
      PaymentStatus.paid => ('PAID', AppColors.success, AppColors.successTint),
      PaymentStatus.partial => (
        'PART PAID',
        AppColors.warning,
        AppColors.warningTint,
      ),
      PaymentStatus.unpaid => (
        'UNPAID',
        AppColors.danger,
        AppColors.dangerTint,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: colour),
      ),
    );
  }
}
