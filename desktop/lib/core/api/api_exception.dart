/// An error returned by the backend, or a failure reaching it.
///
/// [code] is the stable identifier the UI branches on; [message] is what the
/// user reads.
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    required this.statusCode,
    this.details,
  });

  final String code;
  final String message;
  final int statusCode;
  final Object? details;

  /// The session is gone and the user must log in again.
  bool get isAuthFailure =>
      statusCode == 401 || code == 'TOKEN_EXPIRED' || code == 'INVALID_TOKEN';

  /// The backend is not running or not reachable.
  bool get isUnreachable => code == 'BACKEND_UNREACHABLE' || statusCode == 0;

  @override
  String toString() => 'ApiException($code): $message';
}
