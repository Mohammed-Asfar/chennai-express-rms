import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'api_client.dart';

/// One client for the whole app, so the auth token set after login is visible
/// to every later request.
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient();
  ref.onDispose(client.dispose);
  return client;
});
