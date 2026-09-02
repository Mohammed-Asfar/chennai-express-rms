import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/api/api_exception.dart';
import '../../order/data/order_models.dart';
import '../../printers/data/printer_repository.dart';
import '../data/bill_models.dart';
import '../data/bill_repository.dart';

/// Review the total, apply a discount, generate the bill, take payment.
///
/// Every figure here comes from the backend. Nothing on this screen computes a
/// total — that would risk showing the customer one number and recording another.
class BillingDialog extends ConsumerStatefulWidget {
  const BillingDialog({super.key, required this.order});

  final Order order;

  @override
  ConsumerState<BillingDialog> createState() => _BillingDialogState();
}

class _BillingDialogState extends ConsumerState<BillingDialog> {
  final _discountController = TextEditingController();

  DiscountType _discountType = DiscountType.none;

  /// How the customer is paying. Cash is the default because it is what most
  /// bills are settled with at a counter like this.
  PaymentMode _mode = PaymentMode.cash;

  /// Set when the customer is paying with more than one method — ₹100 cash and
  /// the rest by UPI. Generates the bill but takes no payment, dropping into
  /// the step where amounts are entered one at a time.
  bool _split = false;

  BillPreview? _preview;
  Bill? _bill;
  bool _isBusy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refreshPreview();
  }

  @override
  void dispose() {
    _discountController.dispose();
    super.dispose();
  }

  Future<void> _refreshPreview() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      final preview = await ref
          .read(billRepositoryProvider)
          .preview(
            widget.order.id,
            discountType: _discountType,
            discountValue: _discountValue(),
          );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _isBusy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _error = '$error';
      });
    }
  }

  /// Paise for a fixed discount, basis points for a percentage.
  int _discountValue() {
    final text = _discountController.text.trim();
    if (text.isEmpty) return 0;
    final value = double.tryParse(text);
    if (value == null) return 0;
    return (value * 100).round();
  }

  /// Generates the bill, then settles it with the chosen method.
  ///
  /// Two calls, because a payment has to reference a bill that exists. If the
  /// payment leg fails the bill still stands and the dialog moves on to the
  /// payment step — a generated bill is never silently discarded, since its
  /// number has already been allocated.
  Future<void> _settle() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });

    final repo = ref.read(billRepositoryProvider);

    try {
      final bill = await repo.create(
        widget.order.id,
        discountType: _discountType,
        discountValue: _discountValue(),
      );
      if (!mounted) return;
      setState(() => _bill = bill);

      // A split bill stops here: the amounts are not known yet, so the payment
      // step takes them one at a time. Printing waits until it is settled.
      if (_split) {
        setState(() => _isBusy = false);
        return;
      }

      final paid = await repo.pay(
        bill.id,
        mode: _mode,
        amount: bill.total,
        reference: null,
      );
      if (!mounted) return;
      setState(() {
        _bill = paid;
        _isBusy = false;
      });

      // Printed once the bill is settled, so the receipt carries the payment
      // that was actually taken. Deliberately not awaited into the busy state:
      // a print failure must never make a settled bill look unfinished.
      _printBill(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _error = '$error';
      });
    }
  }

  /// Generates the bill and prints it without taking payment.
  ///
  /// What a table is handed before they pay. The printout says UNPAID and
  /// carries the balance due, so it doubles as the record of what is owed.
  ///
  /// The bill is real once this runs — its number is allocated and it appears
  /// in the bills list as unpaid. The dialog moves on to the payment step
  /// rather than closing, because the table is still sitting there.
  Future<void> _printUnpaid() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });

    try {
      final bill = await ref
          .read(billRepositoryProvider)
          .create(
            widget.order.id,
            discountType: _discountType,
            discountValue: _discountValue(),
          );
      if (!mounted) return;
      setState(() {
        _bill = bill;
        _isBusy = false;
      });

      // Not silent: this print is the whole point of the button, so a failure
      // and a success are both worth confirming.
      await _printBill();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _error = '$error';
      });
    }
  }

  /// Sends the bill to the billing printer.
  ///
  /// Never throws into the billing path: a bill that is paid and recorded is
  /// finished whether or not paper came out, and the job stays queued for retry.
  ///
  /// [silent] suppresses the success message for the automatic print after
  /// settling — the cashier did not ask for it, so only a failure is worth
  /// interrupting them for.
  Future<void> _printBill({bool silent = false}) async {
    final bill = _bill;
    if (bill == null) return;

    final messenger = ScaffoldMessenger.of(context);

    try {
      final result = await ref.read(printerRepositoryProvider).printBill(bill.id);
      if (!mounted) return;

      if (!result.printed) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(result.error ?? 'The bill did not print. It is queued.'),
            duration: const Duration(seconds: 6),
          ),
        );
      } else if (!silent) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Bill printed')),
        );
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      // NO_BILL_PRINTER is the common one: nothing is set up yet. Worth saying
      // plainly rather than silently doing nothing.
      messenger.showSnackBar(
        SnackBar(content: Text(error.message), duration: const Duration(seconds: 6)),
      );
    }
  }

  Future<void> _takePayment(
    PaymentMode mode,
    int amount,
    String? reference,
  ) async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      final bill = await ref
          .read(billRepositoryProvider)
          .pay(_bill!.id, mode: mode, amount: amount, reference: reference);
      if (!mounted) return;
      setState(() {
        _bill = bill;
        _isBusy = false;
      });

      // The last instalment of a split settles the bill, and that is the point
      // it should print — with every payment line on it, not just the first.
      if (bill.isPaid) _printBill(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bill = _bill;

    // Sized against the window rather than a fixed number: a dialog as tall as
    // the screen has no visible margin and reads as a page, which is exactly
    // what it is not.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;

    return Dialog(
      // Billing is a step in the order, not a place you navigate to. A dialog
      // keeps the order visible behind it and makes cancelling obvious.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _DialogHeader(
              title: bill == null
                  ? 'Bill order #${widget.order.orderNo}'
                  : bill.billNumber,
              // Once a bill exists it cannot be un-generated, so closing has to
              // report back that the order was billed.
              onClose: () => Navigator.of(context).pop(bill != null),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  if (_error != null) ...[
                    ErrorBanner(
                      message: _error!,
                      onDismiss: () => setState(() => _error = null),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Items', style: theme.textTheme.titleMedium),
                          const SizedBox(height: AppSpacing.sm),
                          for (final line in widget.order.lines)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 32,
                                    child: Text(
                                      '${line.qty}x',
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      line.displayName,
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ),
                                  Text(
                                    Money.formatWithSymbol(line.lineTotal),
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: AppSpacing.md),

                  if (bill == null) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Discount',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            SegmentedButton<DiscountType>(
                              segments: const [
                                ButtonSegment(
                                  value: DiscountType.none,
                                  label: Text('None'),
                                ),
                                ButtonSegment(
                                  value: DiscountType.fixed,
                                  label: Text('Amount'),
                                ),
                                ButtonSegment(
                                  value: DiscountType.percent,
                                  label: Text('Percent'),
                                ),
                              ],
                              selected: {_discountType},
                              onSelectionChanged: (selection) {
                                setState(() => _discountType = selection.first);
                                _refreshPreview();
                              },
                            ),
                            if (_discountType != DiscountType.none) ...[
                              const SizedBox(height: AppSpacing.md),
                              TextField(
                                controller: _discountController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText: _discountType == DiscountType.fixed
                                      ? 'Amount off (₹)'
                                      : 'Percent off',
                                  isDense: true,
                                ),
                                onChanged: (_) => _refreshPreview(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],

                  // Above the totals, so the amount stays the last thing read
                  // before the button that charges it.
                  if (bill == null) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Paying by',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            // Split sits alongside the modes rather than behind
                            // them: "₹100 cash and the rest on UPI" is a normal
                            // request, and it should not need the bill to be
                            // wrongly settled first to get at it.
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(value: 'cash', label: Text('Cash')),
                                ButtonSegment(value: 'card', label: Text('Card')),
                                ButtonSegment(value: 'upi', label: Text('UPI')),
                                ButtonSegment(
                                  value: 'split',
                                  label: Text('Split'),
                                  icon: Icon(Icons.call_split, size: 14),
                                ),
                              ],
                              selected: {_split ? 'split' : _mode.name},
                              onSelectionChanged: (selection) {
                                final choice = selection.first;
                                setState(() {
                                  _split = choice == 'split';
                                  if (!_split) {
                                    _mode = PaymentMode.values.byName(choice);
                                  }
                                });
                              },
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              _split
                                  ? 'Enter each amount on the next step, until '
                                        'nothing is left due.'
                                  : 'Settles the full amount in one payment.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],

                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: _isBusy && _preview == null && bill == null
                          ? const AppLoading()
                          : _Totals(preview: _preview, bill: bill),
                    ),
                  ),
                ],
              ),
            ),

            // The action stays put while the items above scroll. On a short
            // window a scrolling primary button ends up below the fold, and a
            // cashier should never have to hunt for "take payment".
            Container(
              decoration: const BoxDecoration(
                color: AppColors.surfaceSunken,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: bill == null
                  ? Row(
                      children: [
                        // The table wants to see what they owe before they pay.
                        // Generates the bill and prints it unpaid, leaving it
                        // open for payment when they are ready.
                        SizedBox(
                          height: AppSpacing.primaryActionHeight,
                          child: OutlinedButton.icon(
                            onPressed: _isBusy ? null : _printUnpaid,
                            icon: const Icon(Icons.print_outlined, size: 18),
                            label: const Text('Print unpaid'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: SizedBox(
                            height: AppSpacing.primaryActionHeight,
                            child: ElevatedButton.icon(
                              onPressed: _isBusy ? null : _settle,
                              icon: const Icon(Icons.receipt_long, size: 18),
                              label: Text(
                                _preview == null
                                    ? 'Generate bill'
                                    : _split
                                    ? 'Generate bill ${Money.formatWithSymbol(_preview!.total)}'
                                    : 'Take ${_mode.label.toLowerCase()} '
                                          '${Money.formatWithSymbol(_preview!.total)}',
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : _PaymentSection(
                      bill: bill,
                      isBusy: _isBusy,
                      onPay: _takePayment,
                      onDone: () => Navigator.of(context).pop(true),
                      onPrint: _printBill,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The dialog's own title bar, since a Dialog has no AppBar.
class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
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
          Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.preview, required this.bill});

  final BillPreview? preview;
  final Bill? bill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final subtotal = bill?.subtotal ?? preview?.subtotal ?? 0;
    final discount = bill?.discountAmount ?? preview?.discountAmount ?? 0;
    final cgst = bill?.cgst ?? preview?.cgst ?? 0;
    final sgst = bill?.sgst ?? preview?.sgst ?? 0;
    final roundOff = bill?.roundOff ?? preview?.roundOff ?? 0;
    final total = bill?.total ?? preview?.total ?? 0;
    final groups =
        bill?.taxBreakdown ?? preview?.taxBreakdown ?? const <TaxGroup>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(theme, 'Subtotal', subtotal),
        if (discount > 0) _row(theme, 'Discount', -discount),

        // GST requires the rate-wise split to be visible when a bill carries
        // more than one rate.
        if (groups.length > 1)
          for (final group in groups) ...[
            _row(
              theme,
              'CGST ${Money.formatRate(group.rate ~/ 2)}%',
              group.cgst,
            ),
            _row(
              theme,
              'SGST ${Money.formatRate(group.rate ~/ 2)}%',
              group.sgst,
            ),
          ]
        else ...[_row(theme, 'CGST', cgst), _row(theme, 'SGST', sgst)],

        if (roundOff != 0) _row(theme, 'Round off', roundOff),

        const Divider(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Total', style: theme.textTheme.titleLarge),
            Text(
              Money.formatWithSymbol(total),
              style: theme.textTheme.displayLarge,
            ),
          ],
        ),
      ],
    );
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
}

class _PaymentSection extends StatefulWidget {
  const _PaymentSection({
    required this.bill,
    required this.isBusy,
    required this.onPay,
    required this.onDone,
    required this.onPrint,
  });

  final Bill bill;
  final bool isBusy;
  final void Function(PaymentMode mode, int amount, String? reference) onPay;
  final VoidCallback onDone;
  final VoidCallback onPrint;

  @override
  State<_PaymentSection> createState() => _PaymentSectionState();
}

class _PaymentSectionState extends State<_PaymentSection> {
  final _amountController = TextEditingController();
  final _referenceController = TextEditingController();
  PaymentMode _mode = PaymentMode.cash;

  @override
  void initState() {
    super.initState();
    _fillOutstanding();
  }

  @override
  void didUpdateWidget(_PaymentSection old) {
    super.didUpdateWidget(old);
    if (old.bill.outstanding != widget.bill.outstanding) _fillOutstanding();
  }

  /// Prefilled with what is still due — the common case is paying it all at once.
  void _fillOutstanding() {
    _amountController.text = widget.bill.outstanding == 0
        ? ''
        : (widget.bill.outstanding / 100).toStringAsFixed(2);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bill = widget.bill;

    // No Card or padding of its own: this sits in the dialog's footer, which
    // already provides both. Nesting them doubles the inset and wastes the
    // little vertical room a short window has.
    if (bill.isPaid) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('Paid in full', style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final payment in bill.livePayments)
            Text(
              '${payment.mode.label}  ${Money.formatWithSymbol(payment.amount)}',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              // The bill printed automatically on settling. This is for the
              // times it did not, or the customer wants another copy.
              Expanded(
                child: SizedBox(
                  height: AppSpacing.primaryActionHeight,
                  child: OutlinedButton.icon(
                    onPressed: widget.onPrint,
                    icon: const Icon(Icons.print_outlined, size: 18),
                    label: const Text('Print'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: AppSpacing.primaryActionHeight,
                  child: ElevatedButton(
                    onPressed: widget.onDone,
                    child: const Text('Done'),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Payment', style: theme.textTheme.titleMedium),
            Text(
              'Due ${Money.formatWithSymbol(bill.outstanding)}',
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),

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
          onSelectionChanged: (selection) =>
              setState(() => _mode = selection.first),
        ),

        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _amountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Amount (₹)',
            isDense: true,
          ),
        ),

        // A card or UPI reference is worth keeping for reconciliation.
        if (_mode != PaymentMode.cash) ...[
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _referenceController,
            decoration: const InputDecoration(
              labelText: 'Reference (optional)',
              hintText: 'Auth code, txn id',
              isDense: true,
            ),
          ),
        ],

        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: AppSpacing.primaryActionHeight,
          child: ElevatedButton.icon(
            onPressed: widget.isBusy ? null : _submit,
            icon: const Icon(Icons.payments_outlined, size: 18),
            label: Text('Take ${_mode.label.toLowerCase()} payment'),
          ),
        ),
      ],
    );
  }

  void _submit() {
    final amount = Money.parse(_amountController.text);
    if (amount == null || amount <= 0) return;
    widget.onPay(_mode, amount, _referenceController.text.trim());
  }
}
