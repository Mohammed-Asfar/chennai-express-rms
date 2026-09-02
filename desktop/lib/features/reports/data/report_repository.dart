import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'report_models.dart';

/// Reads the reporting endpoints.
///
/// All three are admin-only; a cashier's token gets a 403 the UI turns into a
/// plain message rather than an error the user cannot act on.
class ReportRepository {
  ReportRepository(this._api);

  final ApiClient _api;

  /// Dates are `yyyy-MM-dd` business dates, inclusive at both ends.
  Future<ReportSummary> summary({required String from, required String to}) async {
    final json = await _api.get('/reports/summary?from=$from&to=$to');
    return ReportSummary.fromJson(json);
  }

  Future<ItemSalesReport> items({required String from, required String to}) async {
    final json = await _api.get('/reports/items?from=$from&to=$to');
    return ItemSalesReport.fromJson(json);
  }

  /// The per-day series behind the trend chart. Closed days arrive as zeros.
  Future<DailySalesReport> daily({required String from, required String to}) async {
    final json = await _api.get('/reports/daily?from=$from&to=$to');
    return DailySalesReport.fromJson(json);
  }

  /// Not range-filtered — everything still owed, whenever it was billed.
  Future<OutstandingReport> outstanding() async {
    final json = await _api.get('/reports/outstanding');
    return OutstandingReport.fromJson(json);
  }
}

final reportRepositoryProvider = Provider<ReportRepository>((ref) {
  return ReportRepository(ref.watch(apiClientProvider));
});
