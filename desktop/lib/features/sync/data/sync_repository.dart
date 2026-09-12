import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';

/// How the cloud backup is doing.
///
/// The cloud is the only copy of the day's trading that is not on this one PC.
/// If it silently stops, nobody finds out until the PC dies and the answer to
/// "restore from the backup" is that there isn't one.
class SyncStatus {
  const SyncStatus({
    required this.enabled,
    required this.running,
    required this.healthy,
    required this.pending,
    required this.quarantined,
    this.problem,
    this.lastSuccessAt,
    this.lastAttemptAt,
    this.lastError,
  });

  /// Whether a cloud is configured at all on this machine.
  final bool enabled;

  /// A cycle is in flight right now.
  final bool running;

  /// Whether the cloud copy can be trusted to be current. Decided by the
  /// backend so the rule lives in one place.
  final bool healthy;

  /// Rows waiting to go up. A few is normal between cycles.
  final int pending;

  /// Rows the cloud kept refusing, now given up on. These never leave without
  /// someone pressing retry, so they are the number that matters.
  final int quarantined;

  /// What is wrong, in words worth showing to whoever runs the restaurant.
  final String? problem;

  /// When a cycle last actually put rows in the cloud. Null means never.
  final DateTime? lastSuccessAt;

  /// When it last looked, whether or not anything needed sending.
  ///
  /// Different from [lastSuccessAt], and the difference is the reassuring
  /// part: on a quiet afternoon nothing changes, so the last successful push
  /// can be hours old while the system is checking every few minutes and
  /// working perfectly.
  final DateTime? lastAttemptAt;

  /// The raw database error, for when the plain-language problem is not enough
  /// to fix it.
  final String? lastError;

  bool get hasNeverSynced => lastSuccessAt == null;

  factory SyncStatus.fromJson(Map<String, dynamic> json) => SyncStatus(
    enabled: json['enabled'] as bool? ?? false,
    running: json['running'] as bool? ?? false,
    healthy: json['healthy'] as bool? ?? false,
    pending: json['pending'] as int? ?? 0,
    quarantined: json['quarantined'] as int? ?? 0,
    problem: json['problem'] as String?,
    lastSuccessAt: DateTime.tryParse(
      json['lastSuccessAt'] as String? ?? '',
    )?.toLocal(),
    lastAttemptAt: DateTime.tryParse(
      json['lastAttemptAt'] as String? ?? '',
    )?.toLocal(),
    lastError: json['lastError'] as String?,
  );
}

/// Why rows are not reaching the cloud, as the cloud itself put it.
///
/// The status says how many are stuck; this says what was actually objected to.
/// Without it the only way to find out was the server log on the till, which is
/// not something a restaurant can read.
class SyncFailure {
  const SyncFailure({
    required this.table,
    required this.error,
    required this.count,
    required this.attempts,
  });

  /// The table whose rows were refused — "orders", "bills".
  final String table;

  /// The database's own message, unedited. Support needs the real text.
  final String error;

  final int count;
  final int attempts;

  /// The message with the parts a person can act on, and none of the rest.
  ///
  /// A foreign key failure reads as
  /// `insert or update on table "orders" violates foreign key constraint
  /// "orders_branch_id_fkey"`, which says the same thing three times and buries
  /// the one useful word. What it means is that something this row points at is
  /// not in the cloud yet.
  String get plain {
    // Matched against the known foreign-key columns rather than by splitting
    // the constraint name: a table whose own name contains an underscore
    // ("order_items_menu_item_variant_id_fkey") cannot be split reliably, and
    // the column is the only part that says what is missing.
    final fk = RegExp(r'violates foreign key constraint "(\w+)_fkey"')
        .firstMatch(error);
    if (fk != null) {
      final constraint = fk.group(1)!;
      final column = _foreignKeyColumns.firstWhere(
        (c) => constraint.endsWith('_$c'),
        orElse: () => '',
      );
      if (column.isNotEmpty) {
        return 'Waiting for the ${_parentName(column)} record to reach the '
            'cloud first.';
      }
      return 'Something this record points at has not reached the cloud yet.';
    }

    if (error.contains('does not exist')) {
      return 'The cloud is missing a column this version sends. It needs updating.';
    }
    if (error.contains('connection') || error.contains('timeout')) {
      return 'The connection dropped part way through.';
    }
    return error;
  }

  /// Longest first, so `menu_item_variant_id` wins over `variant_id`.
  static const _foreignKeyColumns = [
    'menu_item_variant_id',
    'reservation_id',
    'category_id',
    'section_id',
    'created_by',
    'voided_by',
    'branch_id',
    'variant_id',
    'order_id',
    'table_id',
    'user_id',
    'bill_id',
    'item_id',
  ];

  static String _parentName(String column) {
    switch (column) {
      case 'branch_id':
        return 'restaurant';
      case 'created_by':
      case 'voided_by':
      case 'user_id':
        return 'staff';
      case 'table_id':
        return 'table';
      case 'section_id':
        return 'section';
      case 'category_id':
        return 'category';
      case 'order_id':
        return 'order';
      case 'bill_id':
        return 'bill';
      default:
        return column.replaceAll('_id', '').replaceAll('_', ' ');
    }
  }

  factory SyncFailure.fromJson(Map<String, dynamic> json) => SyncFailure(
    table: json['table'] as String? ?? '',
    error: json['error'] as String? ?? '',
    count: json['count'] as int? ?? 0,
    attempts: json['attempts'] as int? ?? 0,
  );
}

/// How much cloud room the backup is using.
///
/// The question behind it is commercial: a restaurant on a free plan wants to
/// know whether they are about to be asked for money. A byte count alone does
/// not answer that, so the projection is the point.
class CloudStorage {
  const CloudStorage({
    required this.usedBytes,
    required this.limitBytes,
    required this.bytesPerBill,
    required this.billsPerDay,
    required this.daysMeasured,
    required this.largest,
    this.yearsRemaining,
  });

  final int usedBytes;
  final int limitBytes;

  /// Measured from this branch's own bills, not assumed.
  final int bytesPerBill;
  final double billsPerDay;

  /// Trading days behind the average. Too few and no projection is offered.
  final int daysMeasured;

  /// Years of room left at the current rate. Null when there is not enough
  /// trading history to say honestly.
  final double? yearsRemaining;

  final List<({String table, int bytes})> largest;

  double get fraction => limitBytes == 0 ? 0 : usedBytes / limitBytes;
  int get percent => (fraction * 100).round();

  /// Worth telling someone about. Below this the number is trivia.
  bool get isRunningOut => fraction >= 0.75;

  factory CloudStorage.fromJson(Map<String, dynamic> json) => CloudStorage(
    usedBytes: json['usedBytes'] as int? ?? 0,
    limitBytes: json['limitBytes'] as int? ?? 0,
    bytesPerBill: json['bytesPerBill'] as int? ?? 0,
    billsPerDay: (json['billsPerDay'] as num?)?.toDouble() ?? 0,
    daysMeasured: json['daysMeasured'] as int? ?? 0,
    yearsRemaining: (json['yearsRemaining'] as num?)?.toDouble(),
    largest:
        ((json['largest'] as List<dynamic>?) ?? const []).map((e) {
          final row = e as Map<String, dynamic>;
          return (
            table: row['table'] as String? ?? '',
            bytes: row['bytes'] as int? ?? 0,
          );
        }).toList(),
  );
}

class SyncRepository {
  SyncRepository(this._api);

  final ApiClient _api;

  Future<SyncStatus> status() async {
    return SyncStatus.fromJson(await _api.get('/sync/status'));
  }

  /// The status, pushed as it changes.
  ///
  /// The backend sends the current state on connect and again whenever a cycle
  /// starts, succeeds or fails, so an outage reaches the screen in the time it
  /// takes the worker to notice rather than on top of a polling interval.
  ///
  /// Errors are not surfaced: a socket that drops is a transport problem, and
  /// the caller falls back to asking over HTTP rather than showing the user a
  /// message about websockets.
  Stream<SyncStatus> watch() {
    final token = _api.token ?? '';
    final wsUrl = _api.baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final channel = WebSocketChannel.connect(
      Uri.parse('$wsUrl/sync/stream?token=$token'),
    );

    return channel.stream
        .map((raw) => jsonDecode(raw as String) as Map<String, dynamic>)
        .where((message) => message['type'] == 'status')
        .map(
          (message) =>
              SyncStatus.fromJson(message['status'] as Map<String, dynamic>),
        );
  }

  /// Cloud usage, or null when it could not be measured. Not knowing the size
  /// is not a fault worth an error in front of someone.
  Future<CloudStorage?> storage() async {
    final json = await _api.get('/sync/storage');
    final storage = json['storage'] as Map<String, dynamic>?;
    return storage == null ? null : CloudStorage.fromJson(storage);
  }

  /// Runs a cycle now rather than waiting for the heartbeat.
  Future<SyncStatus> syncNow() async {
    final json = await _api.post('/sync/now');
    return SyncStatus.fromJson(json['status'] as Map<String, dynamic>);
  }

  /// What the cloud objected to, grouped by message.
  ///
  /// Empty is the normal answer and not an error — nothing is wrong.
  Future<List<SyncFailure>> failures() async {
    final json = await _api.get('/sync/errors');
    final list = json['failures'] as List<dynamic>? ?? const [];
    return list
        .map((e) => SyncFailure.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Clears quarantine and pushes again.
  ///
  /// Needed after the cause is fixed — a cloud migration, usually. Without it
  /// those rows stay given up on however healthy the connection becomes.
  Future<SyncStatus> retryFailed() async {
    final json = await _api.post('/sync/retry');
    return SyncStatus.fromJson(json['status'] as Map<String, dynamic>);
  }
}

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  return SyncRepository(ref.watch(apiClientProvider));
});

final syncStatusProvider = FutureProvider<SyncStatus>((ref) {
  return ref.watch(syncRepositoryProvider).status();
});

/// Why rows are stuck. Empty when nothing is.
final syncFailuresProvider = FutureProvider<List<SyncFailure>>((ref) {
  return ref.watch(syncRepositoryProvider).failures();
});

/// The live status, pushed over a websocket.
///
/// Seeded from the REST endpoint so there is something to draw before the
/// socket opens, and so a screen still works when the socket cannot be
/// established at all.
///
/// Reconnects on a drop. A socket that dies silently would leave the screen
/// showing a stale reading while looking live, which is worse than polling —
/// so the failure is treated as expected rather than exceptional.
final syncStreamProvider = StreamProvider<SyncStatus>((ref) async* {
  final repository = ref.watch(syncRepositoryProvider);

  try {
    yield await repository.status();
  } catch (_) {
    // The backend may not be up yet. The socket attempt below will report the
    // real state once it is, and the screen shows its loading state until then.
  }

  var attempt = 0;
  while (true) {
    try {
      await for (final status in repository.watch()) {
        attempt = 0;
        yield status;
      }
    } catch (_) {
      // Dropped or refused. Fall through to the backoff below.
    }

    // Backs off to four seconds. The backend is on this same machine, so a
    // failure here is usually a restart mid-development rather than a network
    // problem, and coming back quickly is what makes it invisible.
    attempt += 1;
    final delay = Duration(seconds: (1 << (attempt - 1)).clamp(1, 4));
    await Future<void>.delayed(delay);

    // One REST read on the way round, so a long outage still refreshes the
    // screen even while the socket refuses to open.
    try {
      yield await repository.status();
    } catch (_) {
      // Still down. The loop will try the socket again.
    }
  }
});

/// Cloud usage. Its own provider because it costs a round trip to the cloud —
/// the status is polled every couple of minutes, this is not.
final cloudStorageProvider = FutureProvider<CloudStorage?>((ref) {
  return ref.watch(syncRepositoryProvider).storage();
});
