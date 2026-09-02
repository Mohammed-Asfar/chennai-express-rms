import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/api/providers.dart';
import 'user.dart';

/// Why a stored session could not be used.
enum RestoreOutcome {
  /// A valid session was restored.
  restored,

  /// No token, or the backend rejected it.
  noSession,

  /// A token exists but the backend is not answering yet. The token is kept.
  backendDown,
}

class RestoreResult {
  const RestoreResult._(this.outcome, this.user);

  const RestoreResult.noSession() : this._(RestoreOutcome.noSession, null);
  const RestoreResult.backendDown() : this._(RestoreOutcome.backendDown, null);
  const RestoreResult.restored(User user) : this._(RestoreOutcome.restored, user);

  final RestoreOutcome outcome;
  final User? user;
}

class AuthRepository {
  AuthRepository(this._api, this._storage);

  final ApiClient _api;
  final FlutterSecureStorage _storage;

  static const _tokenKey = 'auth_token';

  Future<({String token, User user})> login(String username, String password) async {
    final result = await _api.post('/auth/login', {
      'username': username,
      'password': password,
    });

    final token = result['token'] as String;
    final user = User.fromJson(result['user'] as Map<String, dynamic>);

    await _storage.write(key: _tokenKey, value: token);
    _api.setToken(token);

    return (token: token, user: user);
  }

  /// Restores a session from a stored token.
  ///
  /// Distinguishes a rejected token from an unreachable backend. Discarding a
  /// good token because the service had not finished starting would sign the
  /// user out every morning.
  Future<RestoreResult> restoreSession() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) return const RestoreResult.noSession();

    _api.setToken(token);
    try {
      final result = await _api.get('/auth/me');
      return RestoreResult.restored(User.fromJson(result['user'] as Map<String, dynamic>));
    } on ApiException catch (error) {
      if (error.isUnreachable) {
        // Keep the token — the backend is probably still starting.
        return const RestoreResult.backendDown();
      }
      // Expired, revoked, or the account is gone. Not an error worth showing.
      await logout();
      return const RestoreResult.noSession();
    }
  }

  /// Waits for the backend to answer, for use at startup.
  ///
  /// The Windows service and the app start together, and the service usually
  /// wins by a second or two — but not always.
  Future<bool> waitForBackend({
    Duration timeout = const Duration(seconds: 20),
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _api.isHealthy()) return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  Future<void> changePassword(String currentPassword, String newPassword) async {
    await _api.post('/auth/change-password', {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
    });
  }

  Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    _api.setToken(null);
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(apiClientProvider),
    const FlutterSecureStorage(
      wOptions: WindowsOptions(useBackwardCompatibility: false),
    ),
  );
});
