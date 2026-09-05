import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'menu_admin_models.dart';

/// A field being set, where null is one of the values it can be set to.
///
/// `null` as an argument means "leave this alone"; `Patch(null)` means "store
/// null". Needed wherever clearing a value and not touching it are different
/// outcomes — an item's AC surcharge being the case in point, since null there
/// puts it back on its section's amount.
class Patch<T> {
  const Patch(this.value);

  final T? value;
}

/// Menu management calls.
///
/// Separate from [MenuRepository], which serves the till: this one asks for
/// everything including unavailable items, because an admin needs to see the
/// dish that is switched off in order to switch it back on.
class MenuAdminRepository {
  MenuAdminRepository(this._api);

  final ApiClient _api;

  // --- categories ---

  Future<List<AdminCategory>> categories() async {
    final json = await _api.get('/categories');
    return ((json['categories'] as List<dynamic>?) ?? const [])
        .map((c) => AdminCategory.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<void> createCategory(String name) async {
    await _api.post('/categories', {'name': name});
  }

  Future<void> renameCategory(String id, String name) async {
    await _api.patch('/categories/$id', {'name': name});
  }

  Future<void> setCategoryActive(String id, bool isActive) async {
    await _api.patch('/categories/$id', {'isActive': isActive});
  }

  /// Fails with CATEGORY_NOT_EMPTY when it still holds items — the backend
  /// refuses to cascade, so the message is shown to the user as-is.
  Future<void> deleteCategory(String id) async {
    await _api.delete('/categories/$id');
  }

  Future<void> reorderCategories(List<String> ids) async {
    await _api.post('/categories/reorder', {'ids': ids});
  }

  // --- items ---

  /// Every item, including unavailable ones.
  Future<List<AdminMenuItem>> items() async {
    final json = await _api.get('/menu-items');
    return ((json['items'] as List<dynamic>?) ?? const [])
        .map((i) => AdminMenuItem.fromJson(i as Map<String, dynamic>))
        .toList();
  }

  Future<void> createItem({
    required String categoryId,
    required String name,
    String? description,
    int? taxRate,
    int? acSurcharge,
    required List<VariantDraft> variants,
  }) async {
    await _api.post('/menu-items', {
      'categoryId': categoryId,
      'name': name,
      if (description != null && description.isNotEmpty) 'description': description,
      if (taxRate != null) 'taxRate': taxRate,
      if (acSurcharge != null) 'acSurcharge': acSurcharge,
      'variants': [
        for (final v in variants)
          {
            'name': v.name,
            'price': v.price,
            if (!v.isAvailable) 'isAvailable': false,
          },
      ],
    });
  }

  /// [acSurcharge] is wrapped because null is a value here, not an absence:
  /// `Clear()` puts the item back on its section's amount, `Set(0)` exempts it,
  /// and omitting it leaves whatever is stored alone. A bare `int?` could only
  /// express two of those three.
  Future<void> updateItem(
    String id, {
    String? categoryId,
    String? name,
    String? description,
    int? taxRate,
    bool? isAvailable,
    Patch<int>? acSurcharge,
  }) async {
    await _api.patch('/menu-items/$id', {
      if (categoryId != null) 'categoryId': categoryId,
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (taxRate != null) 'taxRate': taxRate,
      if (isAvailable != null) 'isAvailable': isAvailable,
      if (acSurcharge != null) 'acSurcharge': acSurcharge.value,
    });
  }

  Future<void> deleteItem(String id) async {
    await _api.delete('/menu-items/$id');
  }

  // --- portions ---

  Future<void> addVariant(String itemId, String name, int price) async {
    await _api.post('/menu-items/$itemId/variants', {'name': name, 'price': price});
  }

  Future<void> updateVariant(
    String itemId,
    String variantId, {
    String? name,
    int? price,
    bool? isAvailable,
  }) async {
    await _api.patch('/menu-items/$itemId/variants/$variantId', {
      if (name != null) 'name': name,
      if (price != null) 'price': price,
      if (isAvailable != null) 'isAvailable': isAvailable,
    });
  }

  /// Fails with LAST_VARIANT when it is the only portion left.
  Future<void> deleteVariant(String itemId, String variantId) async {
    await _api.delete('/menu-items/$itemId/variants/$variantId');
  }
}

final menuAdminRepositoryProvider = Provider<MenuAdminRepository>((ref) {
  return MenuAdminRepository(ref.watch(apiClientProvider));
});

final adminCategoriesProvider = FutureProvider<List<AdminCategory>>((ref) {
  return ref.watch(menuAdminRepositoryProvider).categories();
});

final adminItemsProvider = FutureProvider<List<AdminMenuItem>>((ref) {
  return ref.watch(menuAdminRepositoryProvider).items();
});
