import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'table_admin_models.dart';

class TableAdminRepository {
  TableAdminRepository(this._api);

  final ApiClient _api;

  // --- sections ---

  Future<List<AdminSection>> sections() async {
    final json = await _api.get('/sections');
    return ((json['sections'] as List<dynamic>?) ?? const [])
        .map((s) => AdminSection.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  /// [surcharge] is paise added to every item ordered here — the AC charge.
  Future<void> createSection(String name, {int surcharge = 0}) async {
    await _api.post('/sections', {'name': name, 'surcharge': surcharge});
  }

  /// Changing [surcharge] affects items added from now on. Food already
  /// ordered keeps the price it was snapshotted at.
  Future<void> renameSection(String id, String name, {int? surcharge}) async {
    await _api.patch('/sections/$id', {
      'name': name,
      if (surcharge != null) 'surcharge': surcharge,
    });
  }

  /// Fails with SECTION_NOT_EMPTY, or LAST_SECTION when it is the only one.
  /// Saves the running order of the sections.
  ///
  /// The full list rather than a moved index: the backend numbers them from
  /// the order it is given, so a dropped request cannot leave two sections
  /// claiming the same position.
  Future<void> reorderSections(List<String> ids) async {
    await _api.post('/sections/reorder', {'ids': ids});
  }

  Future<void> deleteSection(String id) async {
    await _api.delete('/sections/$id');
  }

  // --- tables ---

  Future<List<AdminTable>> tables() async {
    final json = await _api.get('/tables');
    return ((json['tables'] as List<dynamic>?) ?? const [])
        .map((t) => AdminTable.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  Future<void> createTable({
    required String sectionId,
    required String name,
    required int seats,
  }) async {
    await _api.post('/tables', {
      'sectionId': sectionId,
      'name': name,
      'seats': seats,
    });
  }

  Future<void> updateTable(
    String id, {
    String? sectionId,
    String? name,
    int? seats,
    bool? isActive,
  }) async {
    await _api.patch('/tables/$id', {
      if (sectionId != null) 'sectionId': sectionId,
      if (name != null) 'name': name,
      if (seats != null) 'seats': seats,
      if (isActive != null) 'isActive': isActive,
    });
  }

  /// Fails with TABLE_IN_USE when an order is still open on it.
  Future<void> deleteTable(String id) async {
    await _api.delete('/tables/$id');
  }
}

final tableAdminRepositoryProvider = Provider<TableAdminRepository>((ref) {
  return TableAdminRepository(ref.watch(apiClientProvider));
});

final adminSectionsProvider = FutureProvider<List<AdminSection>>((ref) {
  return ref.watch(tableAdminRepositoryProvider).sections();
});

final adminTablesProvider = FutureProvider<List<AdminTable>>((ref) {
  return ref.watch(tableAdminRepositoryProvider).tables();
});
