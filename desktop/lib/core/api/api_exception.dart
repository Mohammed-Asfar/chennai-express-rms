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

/// What to put in front of a person when something failed.
///
/// `'$error'` reads an exception's `toString()`, and for an ApiException that
/// is `ApiException(ALREADY_BILLED): This order has already been billed` — a
/// class name and a wire constant, shown to a cashier mid-service. The message
/// alone is the half that was written for them.
///
/// Anything that is not an ApiException has no user-facing text at all, so it
/// gets a sentence that says what to do rather than a fragment of a stack trace.
String userMessage(Object error) {
  if (error is ApiException) return error.message;
  return 'Something went wrong. Try again, and tell support if it keeps happening.';
}
