import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';

/// What a purge would remove, and whether it has been exported.
class PurgePreview {
  const PurgePreview({
    required this.bills,
    required this.orders,
    required this.payments,
    required this.orderItems,
    required this.exported,
    required this.missingExports,
  });

  final int bills;
  final int orders;
  final int payments;
  final int orderItems;

  /// True when every export covering the whole range has been taken.
  final bool exported;

  /// Which are missing, so the warning can name them.
  final List<String> missingExports;

  bool get isEmpty => bills == 0 && orders == 0 && payments == 0;

  factory PurgePreview.fromJson(Map<String, dynamic> json) => PurgePreview(
        bills: json['bills'] as int? ?? 0,
        orders: json['orders'] as int? ?? 0,
        payments: json['payments'] as int? ?? 0,
        orderItems: json['orderItems'] as int? ?? 0,
        exported: json['exported'] as bool? ?? false,
        missingExports:
            ((json['missingExports'] as List<dynamic>?) ?? const []).cast<String>(),
      );
}

/// What a purge actually did.
class PurgeResult {
  const PurgeResult({
    required this.bills,
    required this.orders,
    required this.payments,
    this.cloudRemoved,
    this.cloudError,
  });

  final int bills;
  final int orders;
  final int payments;

  /// Null when no cloud is configured, or when the cloud could not be reached.
  final int? cloudRemoved;

  /// Set when the till was cleared but the cloud was not. Not a failure of the
  /// purge — the local rows are gone — but the operator has to be told.
  final String? cloudError;

  factory PurgeResult.fromJson(Map<String, dynamic> json) => PurgeResult(
        bills: json['bills'] as int? ?? 0,
        orders: json['orders'] as int? ?? 0,
        payments: json['payments'] as int? ?? 0,
        cloudRemoved: json['cloudRemoved'] as int?,
        cloudError: json['cloudError'] as String?,
      );
}

class PurgeRepository {
  PurgeRepository(this._api);

  final ApiClient _api;

  /// Asks what would go. Changes nothing.
  Future<PurgePreview> preview({required String from, required String to}) async {
    final json = await _api.post('/purge/preview', {'from': from, 'to': to});
    return PurgePreview.fromJson(json['preview'] as Map<String, dynamic>);
  }

  /// Does it. There is no undo.
  Future<PurgeResult> purge({required String from, required String to}) async {
    final json = await _api.post('/purge', {'from': from, 'to': to});
    return PurgeResult.fromJson(json);
  }
}

final purgeRepositoryProvider = Provider<PurgeRepository>((ref) {
  return PurgeRepository(ref.watch(apiClientProvider));
});
