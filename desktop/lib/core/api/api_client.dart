import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_exception.dart';

/// Talks to the local Node backend.
///
/// The backend holds all data and business logic; this client only moves JSON.
/// It never computes a total or decides what a user may do.
class ApiClient {
  ApiClient({
    this.baseUrl = 'http://127.0.0.1:4000',
    http.Client? httpClient,
    Duration? timeout,
  })  : _http = httpClient ?? http.Client(),
        _timeout = timeout ?? const Duration(seconds: 10);

  final String baseUrl;
  final http.Client _http;
  final Duration _timeout;

  String? _token;

  void setToken(String? token) => _token = token;

  /// The current token, for the one caller that cannot use a header.
  ///
  /// A websocket handshake carries no Authorization header, so the printer
  /// discovery stream passes it as a query parameter instead. Nothing else
  /// should read this — use the client's own methods.
  String? get token => _token;

  /// Headers for a request.
  ///
  /// The JSON content-type is only sent when there is a body. Declaring a JSON
  /// body and then sending none makes Fastify reject the request outright,
  /// which is what a DELETE with no payload would do.
  Map<String, String> _headersFor({required bool hasBody}) => {
        if (hasBody) 'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Future<Map<String, dynamic>> get(String path) => _send('GET', path, null);

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) =>
      _send('POST', path, body);

  Future<Map<String, dynamic>> patch(String path, [Map<String, dynamic>? body]) =>
      _send('PATCH', path, body);

  Future<Map<String, dynamic>> delete(String path) => _send('DELETE', path, null);

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    final request = http.Request(method, uri)
      ..headers.addAll(_headersFor(hasBody: body != null));
    if (body != null) request.body = jsonEncode(body);

    try {
      final streamed = await _http.send(request).timeout(_timeout);
      final response = await http.Response.fromStream(streamed);
      return _decode(response);
    } on SocketException {
      // The Flutter client holds no data, so a backend that is not running means
      // a dead UI. Say so plainly instead of showing a blank screen.
      throw const ApiException(
        code: 'BACKEND_UNREACHABLE',
        message: 'Cannot reach the billing service. Make sure it is running.',
        statusCode: 0,
      );
    } on HttpException {
      throw const ApiException(
        code: 'BACKEND_UNREACHABLE',
        message: 'Cannot reach the billing service.',
        statusCode: 0,
      );
    } catch (error) {
      if (error is ApiException) rethrow;
      throw ApiException(
        code: 'NETWORK_ERROR',
        message: 'Network error: $error',
        statusCode: 0,
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> json;
    try {
      json = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw ApiException(
        code: 'BAD_RESPONSE',
        message: 'The billing service returned an unreadable response.',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) return json;

    final error = json['error'] as Map<String, dynamic>?;
    throw ApiException(
      code: error?['code'] as String? ?? 'UNKNOWN',
      message: error?['message'] as String? ?? 'Something went wrong.',
      statusCode: response.statusCode,
      details: error?['details'],
    );
  }

  Future<bool> isHealthy() async {
    try {
      final result = await get('/health');
      return result['status'] == 'ok';
    } on ApiException {
      return false;
    }
  }

  /// Polls `/health` until the backend answers, or the timeout passes.
  ///
  /// A packaged build spawns its own backend, which needs several seconds to
  /// apply migrations and start listening. Anything that runs before the user
  /// can act — the activation check, restoring a session — has to wait for it
  /// rather than report a failure the user cannot do anything about.
  ///
  /// Returns false on timeout rather than throwing. The caller decides whether
  /// that is an error worth showing.
  Future<bool> waitUntilHealthy({
    Duration timeout = const Duration(seconds: 30),
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isHealthy()) return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  void dispose() => _http.close();
}
