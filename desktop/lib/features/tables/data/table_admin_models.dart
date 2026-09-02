/// Models for managing sections and tables.
///
/// The floor screen has its own models in `floor/data/floor_models.dart` shaped
/// around service — who is seated, what is free. These are shaped around setup:
/// they include inactive rows and the counts an admin needs before deleting
/// something.
library;

class AdminSection {
  const AdminSection({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.isActive,
    required this.tableCount,
  });

  final String id;
  final String name;
  final int sortOrder;
  final bool isActive;
  final int tableCount;

  factory AdminSection.fromJson(Map<String, dynamic> json) => AdminSection(
        id: json['id'] as String,
        name: json['name'] as String,
        sortOrder: json['sortOrder'] as int? ?? 0,
        isActive: json['isActive'] as bool? ?? true,
        tableCount: json['tableCount'] as int? ?? 0,
      );
}

class AdminTable {
  const AdminTable({
    required this.id,
    required this.sectionId,
    required this.name,
    required this.seats,
    required this.status,
    required this.sortOrder,
    required this.isActive,
    required this.partyCount,
  });

  final String id;
  final String sectionId;
  final String name;
  final int seats;

  /// free, occupied or reserved. Setup does not change it, but a table in use
  /// cannot be deleted, and the UI should say so before the request fails.
  final String status;
  final int sortOrder;
  final bool isActive;
  final int partyCount;

  bool get isInUse => partyCount > 0 || status == 'occupied';

  factory AdminTable.fromJson(Map<String, dynamic> json) => AdminTable(
        id: json['id'] as String,
        sectionId: json['sectionId'] as String,
        name: json['name'] as String,
        seats: json['seats'] as int? ?? 2,
        status: json['status'] as String? ?? 'free',
        sortOrder: json['sortOrder'] as int? ?? 0,
        isActive: json['isActive'] as bool? ?? true,
        partyCount: json['partyCount'] as int? ?? 0,
      );
}
