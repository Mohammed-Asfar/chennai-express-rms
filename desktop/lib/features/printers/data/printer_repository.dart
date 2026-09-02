import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/api/providers.dart';

/// One message from the discovery stream.
sealed class DiscoveryEvent {
  const DiscoveryEvent();

  const factory DiscoveryEvent.found(DiscoveredPrinter printer) =
      DiscoveryFound;
  const factory DiscoveryEvent.progress({
    required int scanned,
    required int total,
  }) = DiscoveryProgress;
  const factory DiscoveryEvent.done() = DiscoveryDone;
  const factory DiscoveryEvent.failed(String message) = DiscoveryFailed;
}

class DiscoveryFound extends DiscoveryEvent {
  const DiscoveryFound(this.printer);
  final DiscoveredPrinter printer;
}

class DiscoveryProgress extends DiscoveryEvent {
  const DiscoveryProgress({required this.scanned, required this.total});
  final int scanned;
  final int total;

  double get fraction => total == 0 ? 0 : scanned / total;
}

class DiscoveryDone extends DiscoveryEvent {
  const DiscoveryDone();
}

class DiscoveryFailed extends DiscoveryEvent {
  const DiscoveryFailed(this.message);
  final String message;
}

/// Whether a printer is configured for each role.
///
/// The order screen hides the KOT button when no kitchen printer exists, rather
/// than offering a button that can only fail.
class PrinterStatus {
  const PrinterStatus({required this.hasBill, required this.hasKot});

  final bool hasBill;
  final bool hasKot;

  factory PrinterStatus.fromJson(Map<String, dynamic> json) => PrinterStatus(
    hasBill: json['bill'] as bool? ?? false,
    hasKot: json['kot'] as bool? ?? false,
  );

  static const none = PrinterStatus(hasBill: false, hasKot: false);
}

class Printer {
  const Printer({
    required this.id,
    required this.name,
    required this.connection,
    required this.address,
    required this.role,
    required this.paperWidth,
    required this.isActive,
  });

  final String id;
  final String name;

  /// usb or network.
  final String connection;

  /// A device path, or `192.168.1.50:9100`.
  final String address;

  /// bill, kot, or both.
  final String role;

  /// 58mm or 80mm.
  final String paperWidth;
  final bool isActive;

  factory Printer.fromJson(Map<String, dynamic> json) => Printer(
    id: json['id'] as String,
    name: json['name'] as String,
    connection: json['connection'] as String,
    address: json['address'] as String,
    role: json['role'] as String,
    paperWidth: json['paperWidth'] as String,
    isActive: json['isActive'] as bool? ?? true,
  );
}

/// The outcome of asking for a print.
///
/// Carries whether paper actually came out, separately from whether the request
/// succeeded — a queued job that has not printed yet is not a failure, but the
/// user still needs telling.
class PrintOutcome {
  const PrintOutcome({
    required this.printed,
    this.error,
    this.isReprint = false,
  });

  final bool printed;
  final String? error;
  final bool isReprint;
}

/// A printer found by scanning, not yet configured.
class DiscoveredPrinter {
  const DiscoveredPrinter({
    required this.name,
    required this.connection,
    required this.address,
    required this.likelyThermal,
    required this.alreadyAdded,
    this.detail,
  });

  final String name;
  final String connection;
  final String address;

  /// Whether the name looks like a receipt printer rather than an office one.
  /// Only affects ordering — nothing is hidden.
  final bool likelyThermal;
  final bool alreadyAdded;
  final String? detail;

  factory DiscoveredPrinter.fromJson(Map<String, dynamic> json) =>
      DiscoveredPrinter(
        name: json['name'] as String,
        connection: json['connection'] as String,
        address: json['address'] as String,
        likelyThermal: json['likelyThermal'] as bool? ?? false,
        alreadyAdded: json['alreadyAdded'] as bool? ?? false,
        detail: json['detail'] as String?,
      );
}

/// A queued ticket, waiting or stuck.
///
/// Only pending and failed jobs are listed. A printed one is settled and a
/// cancelled one has been dealt with — showing either means the panel is never
/// empty, and a real failure gets lost among things already handled.
class PrintJob {
  const PrintJob({
    required this.id,
    required this.type,
    required this.status,
    required this.attempts,
    required this.createdAt,
    this.lastError,
    this.printerName,
  });

  final String id;

  /// bill, kot, kot_additional, kot_cancel or test.
  final String type;

  /// pending or failed.
  final String status;

  /// How many sends have been tried. Five is the limit before it gives up.
  final int attempts;
  final DateTime? createdAt;
  final String? lastError;

  /// Null if the printer has since been removed.
  final String? printerName;

  bool get hasFailed => status == 'failed';

  /// What this ticket is, in the words used elsewhere in the app.
  String get label => switch (type) {
    'bill' => 'Bill',
    'kot' => 'Kitchen ticket',
    'kot_additional' => 'Kitchen ticket (added items)',
    'kot_cancel' => 'Kitchen ticket (cancellation)',
    'test' => 'Test page',
    _ => type,
  };

  factory PrintJob.fromJson(Map<String, dynamic> json) => PrintJob(
    id: json['id'] as String,
    type: json['type'] as String? ?? '',
    status: json['status'] as String? ?? 'pending',
    attempts: json['attempts'] as int? ?? 0,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal(),
    lastError: json['lastError'] as String?,
    printerName: json['printerName'] as String?,
  );
}

class PrinterRepository {
  PrinterRepository(this._api);

  final ApiClient _api;

  /// Scans for printers, over a websocket.
  ///
  /// A subnet sweep is several hundred probes and takes seconds. Streaming lets
  /// USB printers appear almost immediately while the network sweep continues,
  /// so the dialog shows progress instead of looking hung.
  ///
  /// Closing the returned stream cancels the sweep server-side.
  Stream<DiscoveryEvent> discoverStream() {
    final token = _api.token ?? '';
    final wsUrl = _api.baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final channel = WebSocketChannel.connect(
      Uri.parse('$wsUrl/printers/discover/stream?token=$token'),
    );

    return channel.stream
        .map((raw) {
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          return switch (message['type']) {
            'found' => DiscoveryEvent.found(
              DiscoveredPrinter.fromJson(
                message['printer'] as Map<String, dynamic>,
              ),
            ),
            'progress' => DiscoveryEvent.progress(
              scanned: message['scanned'] as int? ?? 0,
              total: message['total'] as int? ?? 0,
            ),
            'error' => DiscoveryEvent.failed(
              message['message'] as String? ?? 'The scan could not finish',
            ),
            _ => const DiscoveryEvent.done(),
          };
        })
        .handleError((Object error) {
          throw ApiException(
            code: 'SCAN_FAILED',
            message: 'Could not scan for printers: $error',
            statusCode: 0,
          );
        });
  }

  Future<PrinterStatus> status() async {
    final json = await _api.get('/printers/status');
    return PrinterStatus.fromJson(json);
  }

  Future<List<Printer>> printers() async {
    final json = await _api.get('/printers');
    return ((json['printers'] as List<dynamic>?) ?? const [])
        .map((p) => Printer.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<void> create({
    required String name,
    required String connection,
    required String address,
    required String role,
    required String paperWidth,
  }) async {
    await _api.post('/printers', {
      'name': name,
      'connection': connection,
      'address': address,
      'role': role,
      'paperWidth': paperWidth,
    });
  }

  Future<void> update(
    String id, {
    String? name,
    String? connection,
    String? address,
    String? role,
    String? paperWidth,
    bool? isActive,
  }) async {
    await _api.patch('/printers/$id', {
      if (name != null) 'name': name,
      if (connection != null) 'connection': connection,
      if (address != null) 'address': address,
      if (role != null) 'role': role,
      if (paperWidth != null) 'paperWidth': paperWidth,
      if (isActive != null) 'isActive': isActive,
    });
  }

  Future<void> delete(String id) async {
    await _api.delete('/printers/$id');
  }

  /// Waits for the result — the point of a test page is finding out.
  Future<PrintOutcome> test(String id) async {
    final json = await _api.post('/printers/$id/test');
    return PrintOutcome(
      printed: json['ok'] as bool? ?? false,
      error: json['error'] as String?,
    );
  }

  Future<PrintOutcome> printBill(String billId) async {
    final json = await _api.post('/bills/$billId/print');
    return PrintOutcome(
      printed: json['ok'] as bool? ?? false,
      error: json['error'] as String?,
      isReprint: json['isReprint'] as bool? ?? false,
    );
  }

  /// Everything still waiting or stuck. Settled jobs are left out.
  Future<List<PrintJob>> queue() async {
    final json = await _api.get('/print-jobs?active=true');
    return ((json['jobs'] as List<dynamic>?) ?? const [])
        .map((j) => PrintJob.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Sends a stuck job again, and waits to say whether it worked.
  Future<bool> retryJob(String id) async {
    final json = await _api.post('/print-jobs/$id/retry');
    return json['ok'] as bool? ?? false;
  }

  Future<void> cancelJob(String id) async {
    await _api.post('/print-jobs/$id/cancel');
  }
}

final printerRepositoryProvider = Provider<PrinterRepository>((ref) {
  return PrinterRepository(ref.watch(apiClientProvider));
});

/// Cached for the session: printers change rarely, and the order screen asks
/// for this on every build.
final printerStatusProvider = FutureProvider<PrinterStatus>((ref) async {
  try {
    return await ref.watch(printerRepositoryProvider).status();
  } catch (_) {
    // A status check must never break the order screen.
    return PrinterStatus.none;
  }
});
