class MenuCategory {
  const MenuCategory({
    required this.id,
    required this.name,
    required this.itemCount,
  });

  final String id;
  final String name;
  final int itemCount;

  factory MenuCategory.fromJson(Map<String, dynamic> json) => MenuCategory(
        id: json['id'] as String,
        name: json['name'] as String,
        itemCount: json['itemCount'] as int? ?? 0,
      );
}

/// A portion. Price lives here, never on the item.
class MenuVariant {
  const MenuVariant({
    required this.id,
    required this.name,
    required this.price,
    required this.isAvailable,
  });

  final String id;
  final String name;

  /// Paise. The backend owns all arithmetic; this is only displayed.
  final int price;
  final bool isAvailable;

  factory MenuVariant.fromJson(Map<String, dynamic> json) => MenuVariant(
        id: json['id'] as String,
        name: json['name'] as String,
        price: json['price'] as int,
        isAvailable: json['isAvailable'] as bool? ?? true,
      );
}

class MenuItem {
  const MenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.isAvailable,
    required this.variants,
  });

  final String id;
  final String categoryId;
  final String name;
  final bool isAvailable;
  final List<MenuVariant> variants;

  /// Items with one portion add straight to the order; several prompt first.
  bool get hasChoice => variants.length > 1;

  /// The price shown on the tile when there is nothing to choose.
  int? get singlePrice => hasChoice ? null : variants.firstOrNull?.price;

  bool get canOrder =>
      isAvailable && variants.any((v) => v.isAvailable);

  factory MenuItem.fromJson(Map<String, dynamic> json) => MenuItem(
        id: json['id'] as String,
        categoryId: json['categoryId'] as String,
        name: json['name'] as String,
        isAvailable: json['isAvailable'] as bool? ?? true,
        variants: ((json['variants'] as List<dynamic>?) ?? const [])
            .map((v) => MenuVariant.fromJson(v as Map<String, dynamic>))
            .toList(),
      );
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
