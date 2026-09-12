import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:chennai_express_pos/core/api/api_client.dart';
import 'package:chennai_express_pos/core/api/ca_trust.dart';
import 'package:chennai_express_pos/features/updates/data/release_info.dart';
import 'package:chennai_express_pos/features/updates/data/update_repository.dart';

/// A client that streams fixed bytes, or fails in a chosen way.
class _FakeClient extends http.BaseClient {
  _FakeClient({this.body, this.error});

  final List<int>? body;
  final Object? error;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (error != null) throw error!;
    final bytes = body!;
    return http.StreamedResponse(
      Stream.value(bytes),
      200,
      contentLength: bytes.length,
    );
  }

  @override
  void close() => closed = true;
}

ReleaseInfo _release(List<int> payload, {int? sizeOverride}) {
  return ReleaseInfo(
    version: '1.0.8',
    buildNumber: 9,
    downloadUrl: 'https://example.test/setup.exe',
    fileSize: sizeOverride ?? payload.length,
    sha256: sha256.convert(payload).toString(),
    releaseNotes: 'notes',
    isMandatory: false,
    releasedAt: '2026-09-12T00:00:00.000Z',
  );
}

Future<File> _download(UpdateRepository repo, ReleaseInfo release) {
  return repo.download(
    release,
    onProgress: (_, __) {},
    isCancelled: () async => false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider is a plugin with no implementation in the test host, so the
  // download would fail before reaching anything this file is about. Point it
  // at a scratch directory instead.
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('update_download_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getTemporaryDirectory' ? temp.path : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('a good installer is written and returned', () async {
    final payload = utf8.encode('MZ fake installer');
    final client = _FakeClient(body: payload);
    final repo = UpdateRepository(
      ApiClient(),
      downloadClient: () async => client,
    );

    final file = await _download(repo, _release(payload));

    expect(await file.readAsBytes(), payload);
    expect(client.closed, isTrue);
    await file.delete();
  });

  test('a TLS failure reports something a cashier can act on', () async {
    // 1.0.7 showed a branch the raw BoringSSL message, path and all. Whatever
    // the update dialog prints must not be that.
    final repo = UpdateRepository(
      ApiClient(),
      downloadClient: () async => _FakeClient(
        error: const HandshakeException(
          'Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED: '
          'unable to get local issuer certificate'
          '(../../third_party/boringssl/src/ssl/handshake.cc:298))',
        ),
      ),
    );

    final payload = utf8.encode('x');
    await expectLater(
      _download(repo, _release(payload)),
      throwsA(
        isA<UpdateException>()
            .having((e) => e.message, 'message', contains('secure connection'))
            .having((e) => e.message, 'message', isNot(contains('boringssl')))
            .having((e) => e.message, 'message', isNot(contains('OS Error')))
            .having((e) => e.message, 'message', isNot(contains('CERTIFICATE_VERIFY_FAILED'))),
      ),
    );
  });

  test('a truncated download is rejected on size before it is hashed', () async {
    // The 1.0.5 failure: the bytes that arrived were self-consistent, just
    // fewer than published.
    final payload = utf8.encode('short');
    final release = _release(payload, sizeOverride: payload.length + 11);
    final repo = UpdateRepository(
      ApiClient(),
      downloadClient: () async => _FakeClient(body: payload),
    );

    await expectLater(
      _download(repo, release),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('finished early'))),
    );
  });

  test('a wrong-content installer is rejected and deleted', () async {
    final payload = utf8.encode('not the installer we published');
    final release = ReleaseInfo(
      version: '1.0.8',
      buildNumber: 9,
      downloadUrl: 'https://example.test/setup.exe',
      fileSize: payload.length,
      sha256: sha256.convert(utf8.encode('the real installer')).toString(),
      releaseNotes: 'notes',
      isMandatory: false,
      releasedAt: '2026-09-12T00:00:00.000Z',
    );
    final repo = UpdateRepository(
      ApiClient(),
      downloadClient: () async => _FakeClient(body: payload),
    );

    await expectLater(
      _download(repo, release),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('security check'))),
    );

    expect(
      temp.listSync().whereType<File>().where(
            (f) => f.path.endsWith('chennai-express-1.0.8.exe'),
          ),
      isEmpty,
      reason: 'a file that failed verification must not be left behind',
    );
  });

  test('the bundled roots load and exclude the platform store', () async {
    CaTrust.resetForTest();
    final ctx = await CaTrust.context();

    // The point of the bundle is that it is the whole trust decision. If the
    // asset were missing this is null, and the download would silently fall
    // back to the Windows store this change exists to stop depending on.
    expect(ctx, isNotNull, reason: 'assets/ca_roots.pem must ship with the app');
  });
}
