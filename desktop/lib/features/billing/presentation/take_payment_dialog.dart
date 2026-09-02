import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/bill_models.dart';
import '../data/bill_repository.dart';

/// Takes a payment against a bill that was left unpaid.
///
/// A bill printed before the table paid has to be settleable afterwards, and by
/// then the billing dialog is long closed. Part payments are allowed: the
/// amount is prefilled with what is due but can be reduced, and the bill stays
/// open until it is covered.
class TakePaymentDialog extends ConsumerStatefulWidget {
  const TakePaymentDialog({super.key, required this.bill});

  final Bill bill;

  /// Resolves true when a payment was recorded, so the caller can refresh.
  static Future<bool?> show(BuildContext context, Bill bill) {
    return showDialog<bool>(
      context: context,
      builder: (_) => TakePaymentDialog(bill: bill),
    );
  }

  @override
  ConsumerState<TakePaymentDialog> createState() => _TakePaymentDialogState();
}

class _TakePaymentDialogState extends ConsumerState<TakePaymentDialog> {
  late final TextEditingController _amount = TextEditingController(
    // Settling in full is the common case, so it is one tap away.
    text: (widget.bill.outstanding / 100).toStringAsFixed(2),
  );
  final _reference = TextEditingController();

  PaymentMode _mode = PaymentMode.cash;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bill = widget.bill;

    return AlertDialog(
      title: const Text('Take payment'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(bill.billNumber, style: theme.textTheme.bodyMedium),
                Text(
                  'Due ${Money.formatWithSymbol(bill.outstanding)}',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),

            // What has already been taken, so a part payment is not repeated.
            if (bill.livePayments.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              for (final payment in bill.livePayments)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(payment.mode.label, style: theme.textTheme.bodySmall),
                    Text(
                      Money.formatWithSymbol(payment.amount),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
            ],

            const SizedBox(height: AppSpacing.md),
            SegmentedButton<PaymentMode>(
              segments: const [
                ButtonSegment(value: PaymentMode.cash, label: Text('Cash')),
                ButtonSegment(value: PaymentMode.card, label: Text('Card')),
                ButtonSegment(value: PaymentMode.upi, label: Text('UPI')),
              ],
              selected: {_mode},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => setState(() => _mode = selection.first),
            ),

            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _amount,
              enabled: !_busy,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount (₹)',
                isDense: true,
              ),
            ),

            // A card or UPI reference is worth keeping for reconciliation.
            if (_mode != PaymentMode.cash) ...[
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _reference,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Reference (optional)',
                  hintText: 'Auth code, txn id',
                  isDense: true,
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              ErrorBanner(message: _error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          child: Text('Take ${_mode.label.toLowerCase()}'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final amount = Money.parse(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount to take.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // Overpayment is refused by the backend, which owns that rule — the
      // amount is not clamped here, so the reason reaches the cashier.
      await ref
          .read(billRepositoryProvider)
          .pay(
            widget.bill.id,
            mode: _mode,
            amount: amount,
            reference: _reference.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }
}
