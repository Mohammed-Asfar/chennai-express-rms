import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/bill_models.dart';
import '../data/bill_repository.dart';

/// Changes a bill that has already been issued.
///
/// The bill keeps its number and is overwritten: the customer is not handed a
/// second slip with a different number for the same meal. What that costs is
/// the original figures, so the backend records every change — and this screen
/// says plainly when the bill being changed is one somebody has already seen.
///
/// Items are not edited here. They live on the order, which is where the totals
/// are computed from, so "Edit items" reopens the order and hands the operator
/// back to the screen they already use for it.
class EditBillDialog extends ConsumerStatefulWidget {
  const EditBillDialog({super.key, required this.bill});

  final Bill bill;

  /// Returns true when something was saved, so the caller can refresh.
  static Future<bool?> show(BuildContext context, Bill bill) {
    return showDialog<bool>(
      context: context,
      builder: (_) => EditBillDialog(bill: bill),
    );
  }

  @override
  ConsumerState<EditBillDialog> createState() => _EditBillDialogState();
}

class _EditBillDialogState extends ConsumerState<EditBillDialog> {
  late final TextEditingController _discount;
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _reason;

  DiscountType _discountType = DiscountType.none;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final bill = widget.bill;

    // Seeded with what the bill already says, so an operator changing the phone
    // number does not have to retype a discount that is staying put.
    _discountType = bill.discountAmount > 0 ? DiscountType.fixed : DiscountType.none;
    _discount = TextEditingController(
      text: bill.discountAmount > 0 ? Money.format(bill.discountAmount) : '',
    );
    _name = TextEditingController(text: bill.customerName ?? '');
    _phone = TextEditingController(text: bill.customerPhone ?? '');
    _reason = TextEditingController();
  }

  @override
  void dispose() {
    _discount.dispose();
    _name.dispose();
    _phone.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bill = widget.bill;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Text('Edit ${bill.billNumber}', style: theme.textTheme.titleLarge),
            ),

            // The warning that makes this defensible. Not a block — the bill is
            // editable either way — but the moment someone can still decide to
            // hand over a corrected copy rather than leave the paper wrong.
            if (bill.isPaid || bill.amountPaid > 0)
              _Notice(
                icon: Icons.payments_outlined,
                message: bill.isPaid
                    ? 'This bill is settled. Changing the total will leave the '
                          'payment over or under what is owed.'
                    : 'Part of this bill is already paid. Changing the total '
                          'changes what is still owed.',
              ),

            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: AppSpacing.sm),

                    // Items first: it is the change most likely to be wanted,
                    // and it leaves this dialog rather than happening in it.
                    _Section(
                      label: 'Items',
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${bill.items.length} '
                              '${bill.items.length == 1 ? 'line' : 'lines'} '
                              '· ${Money.formatWithSymbol(bill.subtotal)}',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          OutlinedButton(
                            onPressed: _saving ? null : _editItems,
                            child: const Text('Edit items'),
                          ),
                        ],
                      ),
                    ),

                    _Section(
                      label: 'Discount',
                      child: Row(
                        children: [
                          SegmentedButton<DiscountType>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(value: DiscountType.none, label: Text('None')),
                              ButtonSegment(value: DiscountType.fixed, label: Text('₹')),
                              ButtonSegment(value: DiscountType.percent, label: Text('%')),
                            ],
                            selected: {_discountType},
                            onSelectionChanged: _saving
                                ? null
                                : (s) => setState(() => _discountType = s.first),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: AppTextField(
                              controller: _discount,
                              label: _discountType == DiscountType.percent
                                  ? 'Percent off'
                                  : 'Amount off',
                              enabled: !_saving && _discountType != DiscountType.none,
                              hintText: _discountType == DiscountType.percent ? '10' : '0.00',
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    _Section(
                      label: 'Customer',
                      child: Column(
                        children: [
                          AppTextField(
                            controller: _name,
                            label: 'Name',
                            enabled: !_saving,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          AppTextField(
                            controller: _phone,
                            label: 'Phone',
                            enabled: !_saving,
                          ),
                        ],
                      ),
                    ),

                    _Section(
                      label: 'Reason',
                      child: AppTextField(
                        controller: _reason,
                        label: 'Why is this being changed?',
                        enabled: !_saving,
                      ),
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      ErrorBanner(message: _error!),
                    ],

                    const SizedBox(height: AppSpacing.md),
                  ],
                ),
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
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  SizedBox(
                    height: AppSpacing.minTapTarget,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'Saving…' : 'Save changes'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Hands the operator back to the order screen, where lines are edited.
  ///
  /// Reopening is a real change to the order, so it is done before leaving —
  /// arriving at a closed order with nothing editable would be worse than the
  /// extra call.
  Future<void> _editItems() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(billRepositoryProvider).reopenOrder(widget.bill.id);
      if (!mounted) return;
      // True: the bill has changed state even though no total moved yet, and
      // the caller has to redraw to show that its figures are now stale.
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }

  Future<void> _save() async {
    final bill = widget.bill;

    // Paise at the boundary, exactly once. Everything below is integer.
    final entered = _discountType == DiscountType.none
        ? 0
        : _discountType == DiscountType.percent
            // Basis points: 10% is 1000, so the same field reads as a
            // percentage and stores as an integer rate.
            ? (double.tryParse(_discount.text.trim()) ?? 0) * 100
            : (Money.parse(_discount.text.trim()) ?? 0).toDouble();

    final name = _name.text.trim();
    final phone = _phone.text.trim();

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(billRepositoryProvider).amend(
            bill.id,
            discountType: _discountType,
            discountValue: entered.round(),
            customerName: name,
            customerPhone: phone,
            reason: _reason.text.trim(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }
}

/// A labelled block, so the three kinds of edit read as three decisions.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AppColors.inkMuted,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          child,
        ],
      ),
    );
  }
}

/// Says what changing this bill will mean, without preventing it.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warningTint,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}
