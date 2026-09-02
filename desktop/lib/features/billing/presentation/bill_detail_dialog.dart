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
import '../../auth/presentation/auth_controller.dart';
import 'bills_screen.dart';
import 'reason_dialog.dart';
import 'take_payment_dialog.dart';

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
                    // Nothing when no tax was charged. Keyed on the bill's own
                    // figures, not the current setting: this one recorded what
                    // the customer paid and must keep showing it.
                    if (bill.cgst + bill.sgst > 0) ...[
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
                    ],
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
                    for (final payment in bill.payments)
                      _PaymentRow(
                        payment: payment,
                        // Reversing is pointless once the bill is void — it
                        // cannot be voided while a payment stands, so by then
                        // they are already reversed.
                        onReverse: payment.isReversed
                            ? null
                            : () => _reverse(context, ref, payment),
                      ),
                    if (bill.payments.isEmpty)
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
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: AppSpacing.minTapTarget,
                  child: OutlinedButton.icon(
                    onPressed: () => _print(context, ref),
                    icon: const Icon(Icons.print_outlined, size: 18),
                    // A bill printed here has printed before, so the paper
                    // says duplicate. One never printed is still an original,
                    // which the backend decides from the print history.
                    label: const Text('Print'),
                  ),
                ),
              ),

              // Voiding is admin-only and refused while money stands against
              // the bill, so it is offered only when it can actually be done.
              // Showing it otherwise would be a button that only ever errors.
              if (ref.watch(authControllerProvider).user?.isAdmin == true &&
                  bill.livePayments.isEmpty) ...[
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  height: AppSpacing.minTapTarget,
                  child: TextButton(
                    onPressed: () => _void(context, ref),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: const Text('Void'),
                  ),
                ),
              ],

              // Settling later is the point of being able to print a bill
              // before it is paid: by then the billing dialog is long closed.
              if (bill.outstanding > 0) ...[
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: AppSpacing.minTapTarget,
                    child: ElevatedButton.icon(
                      onPressed: () => _takePayment(context, ref),
                      icon: const Icon(Icons.payments_outlined, size: 18),
                      label: Text(
                        'Take payment '
                        '${Money.formatWithSymbol(bill.outstanding)}',
                      ),
                    ),
                  ),
                ),
              ],
            ],
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

  /// Reverses a payment recorded in error.
  ///
  /// The row is kept and marked, never deleted — a cashier who recorded cash
  /// when it was card leaves both rows, and the bill's paid amount follows.
  Future<void> _reverse(
    BuildContext context,
    WidgetRef ref,
    BillPayment payment,
  ) async {
    final reason = await ReasonDialog.show(
      context,
      title: 'Reverse this payment?',
      message:
          '${payment.mode.label} ${Money.formatWithSymbol(payment.amount)} '
          'will stop counting towards this bill. The record of it stays.',
      confirmLabel: 'Reverse it',
      hint: 'Recorded as cash, was card',
    );
    if (reason == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(billRepositoryProvider)
          .reversePayment(bill.id, payment.id, reason);
      _refresh(ref);
      messenger.showSnackBar(const SnackBar(content: Text('Payment reversed')));
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Voids a bill raised in error, reopening its order to be corrected.
  Future<void> _void(BuildContext context, WidgetRef ref) async {
    final reason = await ReasonDialog.show(
      context,
      title: 'Void ${bill.billNumber}?',
      message:
          'It stops counting as a sale and its order reopens so it can be '
          'corrected and billed again. The bill number stays used.',
      confirmLabel: 'Void it',
      hint: 'Billed to the wrong table',
    );
    if (reason == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref.read(billRepositoryProvider).voidBill(bill.id, reason);
      // The bill is gone from the list, so there is nothing left to show.
      ref.invalidate(billListProvider);
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('${bill.billNumber} voided')),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Both the detail and the list behind it go stale together.
  void _refresh(WidgetRef ref) {
    ref.invalidate(_billDetailProvider(bill.id));
    ref.invalidate(billListProvider);
  }

  /// Takes a payment, then reloads so the status and balance follow.
  Future<void> _takePayment(BuildContext context, WidgetRef ref) async {
    final paid = await TakePaymentDialog.show(context, bill);
    if (paid != true) return;

    _refresh(ref);
  }

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
                ? 'Bill printed'
                : result.error ?? 'The printer did not respond',
          ),
        ),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

/// One payment on the bill, with a way to undo it.
///
/// Reversed payments stay listed but struck through: they are the audit trail,
/// and hiding them makes a corrected bill look like it was always right.
class _PaymentRow extends StatelessWidget {
  const _PaymentRow({required this.payment, required this.onReverse});

  final BillPayment payment;

  /// Null once it has been reversed — there is nothing left to undo.
  final VoidCallback? onReverse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final off = payment.isReversed;

    final style = theme.textTheme.bodyMedium?.copyWith(
      color: off ? theme.colorScheme.onSurfaceVariant : null,
      decoration: off ? TextDecoration.lineThrough : null,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              off ? '${payment.mode.label} (reversed)' : payment.mode.label,
              style: style,
            ),
          ),
          Text(Money.formatWithSymbol(payment.amount), style: style),
          SizedBox(
            width: 40,
            child: onReverse == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.undo, size: 16),
                    tooltip: 'Reverse this payment',
                    visualDensity: VisualDensity.compact,
                    onPressed: onReverse,
                  ),
          ),
        ],
      ),
    );
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
                // "GST 0%" says nothing. With tax off the line is either the
                // unit price or, at a quantity of one, nothing at all.
                if (item.qty > 1)
                  Text(
                    '${Money.formatWithSymbol(item.unitPrice)} each'
                    '${item.taxRate > 0 ? '  ·  GST ${Money.formatRate(item.taxRate)}%' : ''}',
                    style: theme.textTheme.bodySmall,
                  )
                else if (item.taxRate > 0)
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
