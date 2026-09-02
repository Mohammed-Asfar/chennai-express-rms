import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../data/activation_repository.dart';
import '../data/activation_status.dart';

enum ActivationPhase {
  /// Asking the backend on startup.
  checking,

  /// The local billing service is not answering. Not an activation failure.
  backendDown,

  /// No key has been entered on this PC, or the licence has run out.
  blocked,

  /// Licensed. The app may continue to login.
  allowed,
}

class ActivationState {
  const ActivationState({
    required this.phase,
    this.status,
    this.errorMessage,
    this.isSubmitting = false,
  });

  final ActivationPhase phase;
  final ActivationStatus? status;
  final String? errorMessage;
  final bool isSubmitting;

  const ActivationState.checking() : this(phase: ActivationPhase.checking);

  ActivationState copyWith({
    ActivationPhase? phase,
    ActivationStatus? status,
    String? errorMessage,
    bool? isSubmitting,
    bool clearError = false,
  }) {
    return ActivationState(
      phase: phase ?? this.phase,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isSubmitting: isSubmitting ?? this.isSubmitting,
    );
  }
}

class ActivationController extends StateNotifier<ActivationState> {
  ActivationController(this._repository) : super(const ActivationState.checking()) {
    check();
  }

  final ActivationRepository _repository;

  Future<void> check() async {
    try {
      final status = await _repository.status();
      state = state.copyWith(
        phase: status.allowed ? ActivationPhase.allowed : ActivationPhase.blocked,
        status: status,
        clearError: true,
      );
    } on ApiException catch (error) {
      // A backend that is not answering is its own problem with its own screen.
      // Showing the key entry screen here would ask an activated restaurant to
      // re-enter its key every time the service is slow to start.
      state = state.copyWith(
        phase: error.isUnreachable ? ActivationPhase.backendDown : ActivationPhase.blocked,
        errorMessage: error.isUnreachable ? null : error.message,
      );
    }
  }

  Future<void> activate(String key) async {
    if (key.trim().isEmpty) {
      state = state.copyWith(errorMessage: 'Enter your activation key.');
      return;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      final status = await _repository.claim(key);
      state = ActivationState(
        phase: status.allowed ? ActivationPhase.allowed : ActivationPhase.blocked,
        status: status,
      );
    } on ActivationException catch (error) {
      state = state.copyWith(isSubmitting: false, errorMessage: error.message);
    }
  }
}

final activationControllerProvider =
    StateNotifierProvider<ActivationController, ActivationState>((ref) {
  return ActivationController(ref.watch(activationRepositoryProvider));
});
