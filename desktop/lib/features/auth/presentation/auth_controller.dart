import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../data/auth_repository.dart';
import '../data/user.dart';

enum AuthStatus {
  /// Checking for a stored session on startup.
  checking,

  /// The local billing service is not answering. Not a login failure.
  backendDown,
  unauthenticated,

  /// Logged in, but the password must be changed before anything else.
  mustChangePassword,
  authenticated,
}

class AuthState {
  const AuthState({
    required this.status,
    this.user,
    this.errorMessage,
    this.isSubmitting = false,
  });

  final AuthStatus status;
  final User? user;
  final String? errorMessage;
  final bool isSubmitting;

  const AuthState.checking() : this(status: AuthStatus.checking);

  AuthState copyWith({
    AuthStatus? status,
    User? user,
    String? errorMessage,
    bool? isSubmitting,
    bool clearError = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isSubmitting: isSubmitting ?? this.isSubmitting,
    );
  }
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repository) : super(const AuthState.checking()) {
    _restore();
  }

  final AuthRepository _repository;

  Future<void> _restore() async {
    // The Windows service and the app start together and the service usually
    // wins, but not always. Waiting beats signing the user out on a race.
    await _repository.waitForBackend();

    final result = await _repository.restoreSession();
    if (!mounted) return;

    state = switch (result.outcome) {
      RestoreOutcome.restored => AuthState(
          status: _statusFor(result.user!),
          user: result.user,
        ),
      RestoreOutcome.backendDown => const AuthState(status: AuthStatus.backendDown),
      RestoreOutcome.noSession => const AuthState(status: AuthStatus.unauthenticated),
    };
  }

  /// Retries after the backend was unreachable.
  Future<void> retryConnection() async {
    state = const AuthState.checking();
    await _restore();
  }

  static AuthStatus _statusFor(User user) =>
      user.mustChangePassword ? AuthStatus.mustChangePassword : AuthStatus.authenticated;

  Future<void> login(String username, String password) async {
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      final result = await _repository.login(username, password);
      if (!mounted) return;
      state = AuthState(status: _statusFor(result.user), user: result.user);
    } on ApiException catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        isSubmitting: false,
        errorMessage: error.message,
      );
    }
  }

  Future<void> changePassword(String currentPassword, String newPassword) async {
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await _repository.changePassword(currentPassword, newPassword);
      if (!mounted) return;
      // Re-read the user so mustChangePassword reflects the backend, not a guess.
      final result = await _repository.restoreSession();
      if (!mounted) return;
      final user = result.user;
      state = user == null
          ? const AuthState(status: AuthStatus.unauthenticated)
          : AuthState(status: _statusFor(user), user: user);
    } on ApiException catch (error) {
      if (!mounted) return;
      state = state.copyWith(isSubmitting: false, errorMessage: error.message);
    }
  }

  Future<void> logout() async {
    await _repository.logout();
    if (!mounted) return;
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(ref.watch(authRepositoryProvider));
});
