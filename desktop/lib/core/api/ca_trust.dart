import 'dart:io';
import 'package:flutter/services.dart';

/// The certificate roots used for outbound HTTPS, bundled with the app.
///
/// Dart on Windows validates TLS against the Windows certificate store, and a
/// till is exactly the machine where that store is wrong: Windows fetches most
/// roots on demand from Windows Update, so a PC kept off updates — or behind a
/// firewall that blocks the root-update endpoint — has never downloaded the
/// issuer for the download host and cannot build a chain to it. 1.0.7 failed to
/// install on a branch for that reason, with
/// `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`.
///
/// The update *check* kept working throughout, which is what made this
/// confusing: the check is plain HTTP to the local backend, and the Node
/// process behind it does its own TLS against a CA list compiled into Node.
/// Only the installer download is Flutter talking TLS itself, so only the
/// download saw the broken store.
///
/// Carrying our own roots makes the download depend on the shipped app rather
/// than on the state of the machine it landed on.
class CaTrust {
  CaTrust._();

  static const _assetPath = 'assets/ca_roots.pem';

  static SecurityContext? _context;
  static bool _loadFailed = false;

  /// A context trusting the bundled roots, or null if they could not be read.
  ///
  /// Deliberately built with `withTrustedRoots: false`. Including the system
  /// roots as well would mean an intercepting proxy's certificate keeps being
  /// accepted on machines that have one installed, and the bundle is only
  /// worth carrying if it is the whole answer.
  ///
  /// Null is a real outcome, not an error to throw: a caller that cannot get a
  /// context falls back to the platform's own validation, which is no worse
  /// than the behaviour before this file existed.
  static Future<SecurityContext?> context() async {
    if (_context != null || _loadFailed) return _context;

    try {
      final pem = await rootBundle.load(_assetPath);
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(pem.buffer.asUint8List());
      _context = context;
      return context;
    } catch (_) {
      // A missing or unparseable bundle must not stop an update from being
      // attempted — the platform store may well be fine on this machine.
      _loadFailed = true;
      return null;
    }
  }

  /// An HttpClient validating against the bundled roots where possible.
  static Future<HttpClient> httpClient() async {
    final ctx = await context();
    return ctx == null ? HttpClient() : HttpClient(context: ctx);
  }

  /// Resets the cache. Tests only.
  static void resetForTest() {
    _context = null;
    _loadFailed = false;
  }
}
