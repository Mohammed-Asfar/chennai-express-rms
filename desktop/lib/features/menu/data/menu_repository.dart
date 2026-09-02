import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'menu_models.dart';

class MenuRepository {
  MenuRepository(this._api);

  final ApiClient _api;

  Future<List<MenuCategory>> categories() async {
    final json = await _api.get('/categories');
    return ((json['categories'] as List<dynamic>?) ?? const [])
        .map((c) => MenuCategory.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Only orderable items — the backend refuses an unavailable dish anyway, so
  /// showing it only invites a failed tap during service.
  Future<List<MenuItem>> items() async {
    final json = await _api.get('/menu-items?availableOnly=true');
    return ((json['items'] as List<dynamic>?) ?? const [])
        .map((i) => MenuItem.fromJson(i as Map<String, dynamic>))
        .toList();
  }
}

final menuRepositoryProvider = Provider<MenuRepository>((ref) {
  return MenuRepository(ref.watch(apiClientProvider));
});

final categoriesProvider = FutureProvider<List<MenuCategory>>((ref) {
  return ref.watch(menuRepositoryProvider).categories();
});

final menuItemsProvider = FutureProvider<List<MenuItem>>((ref) {
  return ref.watch(menuRepositoryProvider).items();
});
