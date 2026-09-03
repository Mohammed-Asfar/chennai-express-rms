import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/api/providers.dart';
import 'activation_status.dart';

class ActivationRepository {
  ActivationRepository(this._api);

  final ApiClient _api;

  /// Asks the backend whether this installation may run.
  ///
  /// Waits for the service first. On a packaged build the app spawns the
  /// backend itself, and it needs several seconds to apply migrations and
  /// listen — asking immediately produced "Cannot reach the billing service"
  /// on a till whose backend was seconds away from being ready, with no retry
  /// and nothing to do but restart the app.
  ///
  /// Rethrows only when the backend is still unreachable after that. It is a
  /// different problem with its own screen, and treating it as "not activated"
  /// would send an activated till to the key entry screen.
  Future<ActivationStatus> status() async {
    await _api.waitUntilHealthy();
    final json = await _api.get('/activation/status');
    return ActivationStatus.fromJson(json);
  }

  /// Claims a key for this PC.
  ///
  /// Throws [ActivationException] with a message written for staff. The backend
  /// deliberately returns the same message for a wrong key, one already bound to
  /// another PC, and a revoked one, so nothing here can distinguish them either.
  Future<ActivationStatus> claim(String key) async {
    try {
      final json = await _api.post('/activation/claim', {'key': key});
      return ActivationStatus.fromJson(json);
    } on ApiException catch (error) {
      throw ActivationException(
        error.isUnreachable
            ? 'Cannot reach the billing service on this PC.'
            : error.message,
      );
    }
  }
}

class ActivationException implements Exception {
  const ActivationException(this.message);
  final String message;

  @override
  String toString() => message;
}

final activationRepositoryProvider = Provider<ActivationRepository>((ref) {
  return ActivationRepository(ref.watch(apiClientProvider));
});
