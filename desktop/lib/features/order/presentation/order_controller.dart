import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../data/order_models.dart';
import '../data/order_repository.dart';

class OrderState {
  const OrderState({
    this.order,
    this.isLoading = true,
    this.isBusy = false,
    this.errorMessage,
    this.notice,
  });

  final Order? order;
  final bool isLoading;

  /// A write is in flight. Buttons disable so a double tap cannot double-add.
  final bool isBusy;

  final String? errorMessage;

  /// A transient message the screen shows once, e.g. the kitchen needs telling.
  final String? notice;

  OrderState copyWith({
    Order? order,
    bool? isLoading,
    bool? isBusy,
    String? errorMessage,
    String? notice,
    bool clearError = false,
    bool clearNotice = false,
  }) {
    return OrderState(
      order: order ?? this.order,
      isLoading: isLoading ?? this.isLoading,
      isBusy: isBusy ?? this.isBusy,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

class OrderController extends StateNotifier<OrderState> {
  OrderController(this._repository, this._orderId) : super(const OrderState()) {
    _load();
  }

  final OrderRepository _repository;
  final String _orderId;

  Future<void> _load() async {
    try {
      final order = await _repository.fetch(_orderId);
      if (!mounted) return;
      state = OrderState(order: order, isLoading: false);
    } on ApiException catch (error) {
      if (!mounted) return;
      state = OrderState(isLoading: false, errorMessage: error.message);
    }
  }

  Future<void> addItem(String variantId, {int qty = 1, String? notes}) async {
    await _run(() => _repository.addItem(_orderId, variantId: variantId, qty: qty, notes: notes));
  }

  Future<void> setQty(String lineId, int qty) async {
    // Reaching zero removes the line rather than rejecting the tap.
    if (qty <= 0) {
      await removeLine(lineId);
      return;
    }
    await _run(() => _repository.setQty(_orderId, lineId, qty));
  }

  Future<void> removeLine(String lineId) async {
    if (state.isBusy) return;
    state = state.copyWith(isBusy: true, clearError: true, clearNotice: true);
    try {
      final result = await _repository.removeLine(_orderId, lineId);
      if (!mounted) return;
      state = state.copyWith(
        order: result.order,
        isBusy: false,
        // The kitchen is already cooking this; someone has to tell them.
        notice: result.kotAlreadyPrinted
            ? 'That item was already sent to the kitchen — tell them it is cancelled.'
            : null,
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      state = state.copyWith(isBusy: false, errorMessage: error.message);
    }
  }

  /// Returns true when the kitchen needs a cancellation slip.
  Future<bool> cancel(String reason) async {
    try {
      return await _repository.cancel(_orderId, reason);
    } on ApiException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(errorMessage: error.message);
      return false;
    }
  }

  Future<void> refresh() => _load();

  void clearNotice() => state = state.copyWith(clearNotice: true);
  void clearError() => state = state.copyWith(clearError: true);

  Future<void> _run(Future<Order> Function() action) async {
    if (state.isBusy) return;
    state = state.copyWith(isBusy: true, clearError: true, clearNotice: true);
    try {
      final order = await action();
      if (!mounted) return;
      state = state.copyWith(order: order, isBusy: false);
    } on ApiException catch (error) {
      if (!mounted) return;
      state = state.copyWith(isBusy: false, errorMessage: error.message);
    }
  }
}

final orderControllerProvider =
    StateNotifierProvider.family<OrderController, OrderState, String>((ref, orderId) {
  return OrderController(ref.watch(orderRepositoryProvider), orderId);
});
