import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/api/providers.dart';
import 'release_info.dart';

class UpdateRepository {
  UpdateRepository(this._api);

  final ApiClient _api;
  static const _dismissedKey = 'update_dismissed_build';
  static const _dismissedDateKey = 'update_dismissed_date';

  /// Asks the backend whether a newer release exists.
  ///
  /// Returns null on any failure. An update check must never surface an error the
  /// user cannot act on, and must never stand between staff and a bill.
  Future<UpdateCheckResult?> check() async {
    try {
      final json = await _api.get('/updates/check');
      return UpdateCheckResult.fromJson(json);
    } on ApiException {
      return null;
    }
  }

  /// True when the user dismissed this build earlier today.
  Future<bool> wasDismissedToday(int buildNumber) async {
    final prefs = await SharedPreferences.getInstance();
    final build = prefs.getInt(_dismissedKey);
    final date = prefs.getString(_dismissedDateKey);
    return build == buildNumber && date == _today();
  }

  Future<void> dismissForToday(int buildNumber) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_dismissedKey, buildNumber);
    await prefs.setString(_dismissedDateKey, _today());
  }

  static String _today() => DateTime.now().toIso8601String().split('T').first;

  /// Downloads the installer and verifies its checksum.
  ///
  /// Throws if the SHA-256 does not match. The app is about to execute this file
  /// on the billing PC — running an unverified binary is the worst outcome in the
  /// system, so a mismatch aborts and the downloaded file is deleted.
  Future<File> download(
    ReleaseInfo release, {
    required void Function(int received, int total) onProgress,
    required Future<bool> Function() isCancelled,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/chennai-express-${release.version}.exe');
    if (await file.exists()) await file.delete();

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(release.downloadUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw UpdateException('Download failed (HTTP ${response.statusCode})');
      }

      final total = response.contentLength ?? release.fileSize;
      final sink = file.openWrite();
      var received = 0;

      try {
        await for (final chunk in response.stream) {
          if (await isCancelled()) {
            await sink.close();
            if (await file.exists()) await file.delete();
            throw const UpdateException('Download cancelled');
          }
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
      } finally {
        await sink.close();
      }

      final digest = sha256.convert(await file.readAsBytes()).toString();
      if (digest.toLowerCase() != release.sha256.toLowerCase()) {
        await file.delete();
        throw const UpdateException(
          'The downloaded file failed its security check and was discarded.',
        );
      }

      return file;
    } on SocketException {
      if (await file.exists()) await file.delete();
      throw const UpdateException('Could not reach the download server.');
    } finally {
      client.close();
    }
  }

  /// Launches the installer and leaves it to take over.
  ///
  /// The caller closes the app afterwards; the installer cannot replace files
  /// that are still in use.
  Future<void> launchInstaller(File installer) async {
    final result = await Process.start(
      installer.path,
      const [],
      mode: ProcessStartMode.detached,
      runInShell: true,
    );
    if (result.pid == 0) {
      throw const UpdateException('The installer could not be started.');
    }
  }
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

final updateRepositoryProvider = Provider<UpdateRepository>((ref) {
  return UpdateRepository(ref.watch(apiClientProvider));
});
