import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/widgets/error_banner.dart';
import '../../billing/data/bill_repository.dart';
import '../../billing/presentation/bill_detail_dialog.dart';
import '../../billing/presentation/billing_dialog.dart';
import '../../printers/data/printer_repository.dart';
import '../data/order_models.dart';
import '../data/order_repository.dart';
import 'menu_panel.dart';
import 'order_controller.dart';

/// Menu on the left, the running order on the right.
class OrderScreen extends ConsumerWidget {
  const OrderScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(orderControllerProvider(orderId));
    final controller = ref.read(orderControllerProvider(orderId).notifier);
    final order = state.order;

    // Surface a kitchen warning once, then clear it.
    ref.listen(orderControllerProvider(orderId), (previous, next) {
      final notice = next.notice;
      if (notice != null && notice != previous?.notice) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(notice), duration: const Duration(seconds: 5)),
        );
        controller.clearNotice();
      }
    });

    // Leaving an empty order behind is what strands a table: it stays open,
    // the floor keeps showing SEATED, and nothing in the app explains why.
    // Going back discards it, since an order with nothing on it is a mis-tap
    // rather than work worth keeping.
    return PopScope(
      canPop: order == null || !order.isOpen || !order.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || order == null || !order.isOpen || !order.isEmpty) return;
        _discardAndLeave(context, controller);
      },
      child: Scaffold(
        appBar: AppBar(
          title: order == null
              ? const Text('Order')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_title(order)),
                    // Read back to the customer while the order is taken, and
                    // read off by whoever hands it to the rider. Recording an
                    // address nobody can see afterwards would be pointless.
                    if (_contact(order) != null)
                      Text(
                        _contact(order)!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
          actions: [
            if (order != null && order.isOpen)
              TextButton.icon(
                onPressed: () => _cancelOrder(
                  context,
                  ref,
                  controller,
                  isEmpty: order.isEmpty,
                ),
                icon: const Icon(Icons.close),
                // "Discard" for an order that never had anything on it: nothing is
                // being cancelled, and the softer word matches the lighter action.
                label: Text(order.isEmpty ? 'Discard' : 'Cancel order'),
              ),
            const SizedBox(width: AppSpacing.sm),
          ],
        ),
        body: state.isLoading
            ? const AppLoading()
            : order == null
            ? Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: ErrorBanner(
                  message: state.errorMessage ?? 'Order not found',
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  // The order panel needs enough room for a name, quantity
                  // stepper and amount without wrapping, but must not squeeze
                  // the menu on a small counter screen.
                  final panelWidth = constraints.maxWidth < 1100
                      ? constraints.maxWidth * 0.36
                      : 380.0;

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: MenuPanel(
                          enabled: order.isOpen && !state.isBusy,
                          onPick: (variant) => controller.addItem(variant.id),
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: panelWidth,
                        child: _OrderPanel(
                          state: state,
                          controller: controller,
                          onBill: () => _openBilling(context, ref, order),
                          onPrintKot: () => _printKot(context, ref, order),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  /// Discards an empty order on the way out, so the table frees itself.
  ///
  /// No confirmation: there is nothing to lose, and asking is what leaves a
  /// table seated because someone dismissed the dialog and walked away.
  Future<void> _discardAndLeave(
    BuildContext context,
    OrderController controller,
  ) async {
    final navigator = Navigator.of(context);
    try {
      await controller.cancel('Discarded before anything was ordered');
    } on ApiException {
      // Leaving is what was asked for. A discard that failed leaves the order
      // open, which the floor will show — better than trapping the cashier on
      // a screen they are trying to leave.
    }
    if (navigator.mounted) navigator.pop();
  }

  /// The customer line under the title, or null when there is nothing to show.
  ///
  /// Phone first: it is what someone reaches for when a rider cannot find the
  /// address, and it is the shorter of the two.
  static String? _contact(Order order) {
    final parts = [
      if (order.customerPhone != null && order.customerPhone!.isNotEmpty)
        order.customerPhone!,
      if (order.customerName != null && order.customerName!.isNotEmpty)
        order.customerName!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _title(Order order) {
    final seat = order.seatLabel == null ? '' : ' · ${order.seatLabel}';
    return '${order.type.label} #${order.orderNo}$seat';
  }

  /// Sends the kitchen ticket.
  ///
  /// Only lines not yet sent go on it, so pressing this twice does not make the
  /// kitchen cook everything again — the backend decides what is new.
  Future<void> _printKot(
    BuildContext context,
    WidgetRef ref,
    Order order,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref.read(orderRepositoryProvider).printKot(order.id);

      // Distinguishes "the paper came out" from "it is queued": a cook waiting
      // at a printer that never fired needs to know.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.printed
                ? 'Sent ${result.itemsSent} item${result.itemsSent == 1 ? '' : 's'} to the kitchen'
                : 'Queued for the kitchen — the printer did not respond',
          ),
        ),
      );
      // The lines are now marked as sent, which changes what a second press
      // would do.
      await ref.read(orderControllerProvider(order.id).notifier).refresh();
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _openBilling(
    BuildContext context,
    WidgetRef ref,
    Order order,
  ) async {
    // An order reopened to correct an existing bill must not be billed again.
    // Going through the billing dialog asks the backend to create a second bill
    // for the same order, which it refuses — and the refusal landed in front of
    // the cashier as ApiException(ALREADY_BILLED) over a "Take cash" button.
    if (order.isBeingCorrected) {
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      try {
        await ref
            .read(billRepositoryProvider)
            .amend(order.billId!, recalculate: true);
        // The bill's cached copy is now the one from before this edit. Left
        // alone, opening it again shows the old total beside a list row
        // carrying the new one.
        invalidateBill(ref, order.billId!);
        if (!context.mounted) return;
        navigator.pop();
        messenger.showSnackBar(const SnackBar(content: Text('Bill updated')));
      } on ApiException catch (error) {
        messenger.showSnackBar(SnackBar(content: Text(error.message)));
      }
      return;
    }

    final billed = await showDialog<bool>(
      context: context,
      // Billing cannot be dismissed by clicking away: a half-taken payment
      // closed by accident is a bill the cashier thinks is settled.
      barrierDismissible: false,
      builder: (_) => BillingDialog(order: order),
    );
    if (billed == true && context.mounted) Navigator.of(context).pop();
  }

  Future<void> _cancelOrder(
    BuildContext context,
    WidgetRef ref,
    OrderController controller, {
    required bool isEmpty,
  }) async {
    // An order with nothing on it has nothing to explain. Demanding a written
    // reason to discard a mis-tap is friction with no audit value — and it is
    // what leaves a table showing as seated because nobody wanted to fill in a
    // form to undo a mistake.
    final String? reason;
    if (isEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Discard this order?'),
          content: const Text(
            'Nothing was added, so the table will be free again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep it'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      reason = 'Discarded before anything was ordered';
    } else {
      // Two results, not one: null means the dialog was dismissed, an empty
      // string means cancel with no note. Reading an empty reason as "changed
      // my mind" would leave the order open with nothing on screen to say why.
      final result = await showDialog<String>(
        context: context,
        builder: (_) => const _CancelDialog(),
      );
      if (result == null) return;
      reason = result;
    }

    if (!context.mounted) return;

    final kitchenNeedsTelling = await controller.cancel(reason);
    if (!context.mounted) return;

    if (kitchenNeedsTelling) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.soup_kitchen_outlined),
          title: const Text('Tell the kitchen'),
          // Otherwise they keep cooking food nobody will pay for.
          content: const Text(
            'This order was already sent to the kitchen. Let them know it is cancelled.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
    if (context.mounted) Navigator.of(context).pop();
  }
}

class _OrderPanel extends ConsumerWidget {
  const _OrderPanel({
    required this.state,
    required this.controller,
    required this.onBill,
    required this.onPrintKot,
  });

  final OrderState state;
  final OrderController controller;
  final VoidCallback onBill;
  final VoidCallback onPrintKot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final order = state.order!;

    // No kitchen printer means no button, rather than one that can only fail.
    final hasKotPrinter = ref
        .watch(printerStatusProvider)
        .maybeWhen(data: (status) => status.hasKot, orElse: () => false);

    return Container(
      color: AppColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Text('THIS ORDER', style: theme.textTheme.labelSmall),
                const Spacer(),
                if (order.itemCount > 0)
                  Text(
                    '${order.itemCount} ${order.itemCount == 1 ? 'item' : 'items'}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),

          if (state.errorMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: ErrorBanner(
                message: state.errorMessage!,
                onDismiss: controller.clearError,
              ),
            ),

          Expanded(
            child: order.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.add_shopping_cart_outlined,
                            size: AppSpacing.xl,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            'Pick items from the menu',
                            style: theme.textTheme.bodyMedium,
                            textAlign: TextAlign.center,
                          ),
                          // Leaving the screen keeps the table held, which is
                          // not obvious from a back arrow.
                          if (order.type == OrderType.dineIn) ...[
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              'The table stays seated until you add something '
                              'or discard the order.',
                              style: theme.textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    itemCount: order.lines.length,
                    itemBuilder: (context, index) => _LineRow(
                      line: order.lines[index],
                      enabled: order.isOpen && !state.isBusy,
                      onIncrement: () => controller.setQty(
                        order.lines[index].id,
                        order.lines[index].qty + 1,
                      ),
                      onDecrement: () => controller.setQty(
                        order.lines[index].id,
                        order.lines[index].qty - 1,
                      ),
                    ),
                  ),
          ),

          Container(
            decoration: const BoxDecoration(
              color: AppColors.surfaceSunken,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                _Totals(order: order),
                const SizedBox(height: AppSpacing.lg),

                // The kitchen ticket goes first in the flow and second in
                // weight: it is pressed early and often, but the till's job is
                // still to take money, so payment keeps the primary style.
                if (hasKotPrinter) ...[
                  SizedBox(
                    width: double.infinity,
                    height: AppSpacing.minTapTarget,
                    child: OutlinedButton.icon(
                      onPressed: order.isEmpty || !order.isOpen || state.isBusy
                          ? null
                          : onPrintKot,
                      icon: const Icon(Icons.receipt_outlined, size: 18),
                      label: const Text('Print KOT'),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],

                SizedBox(
                  width: double.infinity,
                  height: AppSpacing.primaryActionHeight,
                  child: ElevatedButton(
                    onPressed: order.isEmpty || !order.isOpen || state.isBusy
                        ? null
                        : onBill,
                    child: state.isBusy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        // The order already has a bill; this brings it in step
                        // rather than raising a second one.
                        : Text(
                            order.isBeingCorrected
                                ? 'Update bill'
                                : 'Take payment',
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    required this.line,
    required this.enabled,
    required this.onIncrement,
    required this.onDecrement,
  });

  final OrderLine line;
  final bool enabled;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(line.displayName, style: theme.textTheme.bodyLarge),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                Money.formatWithSymbol(line.lineTotal),
                style: AppTextStyles.money,
              ),
            ],
          ),

          if (line.notes != null) ...[
            const SizedBox(height: 2),
            Text(line.notes!, style: theme.textTheme.bodySmall),
          ],

          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              _StepButton(
                icon: line.qty == 1 ? Icons.delete_outline : Icons.remove,
                tooltip: line.qty == 1 ? 'Remove' : 'One less',
                onPressed: enabled ? onDecrement : null,
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${line.qty}',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.quantity,
                ),
              ),
              _StepButton(
                icon: Icons.add,
                tooltip: 'One more',
                onPressed: enabled ? onIncrement : null,
              ),
              const Spacer(),
              Text(
                '${Money.formatWithSymbol(line.unitPrice)} each',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        _row(theme, 'Subtotal', order.subtotal),
        _row(theme, 'Tax', order.tax),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Total', style: theme.textTheme.titleMedium),
            Text(
              Money.formatWithSymbol(order.total),
              style: AppTextStyles.displayLarge,
            ),
          ],
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, String label, int paise) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(Money.formatWithSymbol(paise), style: AppTextStyles.money),
      ],
    ),
  );
}

/// A compact square stepper, sized for a quick tap without the padding a stock
/// IconButton carries.
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          child: SizedBox(
            height: 34,
            width: 34,
            child: Icon(
              icon,
              size: 16,
              color: onPressed == null ? AppColors.inkFaint : AppColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _CancelDialog extends StatefulWidget {
  const _CancelDialog();

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cancel this order?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'The order is cancelled and the table freed.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            // Not autofocused, and optional. Requiring a reason taught staff
            // to type anything at all to get past it, which filled the record
            // with noise that reads like data. Somewhere to put a real note
            // is still worth having for the times there is one.
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              hintText: 'Customer left, wrong table…',
            ),
            // Enter cancels, so the common case is one keypress.
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep order'),
        ),
        ElevatedButton(
          // Always enabled: an empty note is a valid cancellation, and the
          // string is what distinguishes it from dismissing the dialog.
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Cancel order'),
        ),
      ],
    );
  }
}
