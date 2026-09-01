import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/api/api_exception.dart';

/// Session restore must tell "the backend rejected this token" apart from
/// "the backend is not answering yet".
///
/// Treating both as a rejection would delete a valid token whenever the app
/// won the startup race against the Windows service, signing the user out
/// every morning.
void main() {
  group('ApiException classification', () {
    test('a backend that is not running is unreachable, not an auth failure', () {
      const error = ApiException(
        code: 'BACKEND_UNREACHABLE',
        message: 'Cannot reach the billing service.',
        statusCode: 0,
      );
      expect(error.isUnreachable, isTrue);
      expect(error.isAuthFailure, isFalse, reason: 'the token must be kept');
    });

    test('a 401 is an auth failure', () {
      const error = ApiException(
        code: 'INVALID_TOKEN',
        message: 'Invalid authentication token',
        statusCode: 401,
      );
      expect(error.isAuthFailure, isTrue);
      expect(error.isUnreachable, isFalse);
    });

    test('an expired token is an auth failure', () {
      const error = ApiException(
        code: 'TOKEN_EXPIRED',
        message: 'Session expired',
        statusCode: 401,
      );
      expect(error.isAuthFailure, isTrue);
    });

    test('a disabled account is not an auth failure that clears the token', () {
      // 403 means the account exists and the token is valid; the user is blocked.
      const error = ApiException(
        code: 'ACCOUNT_DISABLED',
        message: 'Account has been disabled',
        statusCode: 403,
      );
      expect(error.isAuthFailure, isFalse);
    });

    test('a server error is neither unreachable nor an auth failure', () {
      const error = ApiException(
        code: 'INTERNAL_ERROR',
        message: 'An unexpected error occurred',
        statusCode: 500,
      );
      expect(error.isAuthFailure, isFalse);
      expect(error.isUnreachable, isFalse);
    });
  });
}
