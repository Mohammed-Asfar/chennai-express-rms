/// Models for managing the menu, as opposed to ordering from it.
///
/// The ordering models in `menu_models.dart` deliberately drop everything the
/// till does not need — tax rate, description, sort order, the inactive rows.
/// Management needs all of it, including items that are switched off, so these
/// are separate types rather than extra nullable fields on the order path.
library;

class AdminCategory {
  const AdminCategory({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isActive,
    required this.itemCount,
  });

  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;
  final int itemCount;

  factory AdminCategory.fromJson(Map<String, dynamic> json) => AdminCategory(
        id: json['id'] as String,
        name: json['name'] as String,
        sortOrder: json['sortOrder'] as int? ?? 0,
        isActive: json['isActive'] as bool? ?? true,
        itemCount: json['itemCount'] as int? ?? 0,
      );
}

/// A portion. Price lives here, never on the item.
class AdminVariant {
  const AdminVariant({
    required this.id,
    required this.name,
    required this.price,
    required this.sortOrder,
    required this.isAvailable,
  });

  final String id;
  final String name;

  /// Paise. Converted from rupees only at the input boundary.
  final int price;
  final int sortOrder;
  final bool isAvailable;

  factory AdminVariant.fromJson(Map<String, dynamic> json) => AdminVariant(
        id: json['id'] as String,
        name: json['name'] as String,
        price: json['price'] as int,
        sortOrder: json['sortOrder'] as int? ?? 0,
        isAvailable: json['isAvailable'] as bool? ?? true,
      );
}

class AdminMenuItem {
  const AdminMenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.description,
    required this.taxRate,
    required this.isAvailable,
    required this.sortOrder,
    required this.variants,
  });

  final String id;
  final String categoryId;
  final String name;
  final String? description;

  /// Basis points: 5% is 500. Never a float — see CLAUDE.md section 2.
  final int taxRate;
  final bool isAvailable;
  final int sortOrder;
  final List<AdminVariant> variants;

  /// The range shown in the list. An item with one portion shows one price.
  int get lowestPrice =>
      variants.isEmpty ? 0 : variants.map((v) => v.price).reduce((a, b) => a < b ? a : b);

  int get highestPrice =>
      variants.isEmpty ? 0 : variants.map((v) => v.price).reduce((a, b) => a > b ? a : b);

  bool get hasPriceRange => lowestPrice != highestPrice;

  factory AdminMenuItem.fromJson(Map<String, dynamic> json) => AdminMenuItem(
        id: json['id'] as String,
        categoryId: json['categoryId'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        taxRate: json['taxRate'] as int? ?? 0,
        isAvailable: json['isAvailable'] as bool? ?? true,
        sortOrder: json['sortOrder'] as int? ?? 0,
        variants: ((json['variants'] as List<dynamic>?) ?? const [])
            .map((v) => AdminVariant.fromJson(v as Map<String, dynamic>))
            .toList(),
      );
}

/// A portion being entered or edited, before it exists on the server.
///
/// Held separately from [AdminVariant] because a new one has no id, and the
/// price is mid-edit text rather than a settled integer.
class VariantDraft {
  VariantDraft({
    this.id,
    required this.name,
    required this.price,
    this.isAvailable = true,
  });

  /// Null for a portion that has not been saved yet.
  final String? id;
  String name;

  /// Paise.
  int price;

  /// Whether it can be ordered. A portion sold out for the evening keeps its
  /// price and comes back with one tap.
  bool isAvailable;

  bool get isNew => id == null;
}
