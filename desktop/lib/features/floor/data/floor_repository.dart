import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';
import 'floor_models.dart';

class FloorRepository {
  FloorRepository(this._api);

  final ApiClient _api;

  /// Sections with their tables and who is seated, in one call.
  Future<List<FloorSection>> load() async {
    final json = await _api.get('/floor');
    return ((json['sections'] as List<dynamic>?) ?? const [])
        .map((s) => FloorSection.fromJson(s as Map<String, dynamic>))
        .toList();
  }
}

final floorRepositoryProvider = Provider<FloorRepository>((ref) {
  return FloorRepository(ref.watch(apiClientProvider));
});

/// The floor, refetched whenever it is invalidated after an order changes.
final floorProvider = FutureProvider<List<FloorSection>>((ref) {
  return ref.watch(floorRepositoryProvider).load();
});
