import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    lastError: json['lastError'] as String?,
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

/// Cloud usage. Its own provider because it costs a round trip to the cloud —
/// the status is polled every couple of minutes, this is not.
final cloudStorageProvider = FutureProvider<CloudStorage?>((ref) {
  return ref.watch(syncRepositoryProvider).storage();
});
