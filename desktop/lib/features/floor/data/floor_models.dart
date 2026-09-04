enum TableStatus { free, occupied, reserved }

TableStatus _statusFrom(String value) => switch (value) {
      'occupied' => TableStatus.occupied,
      'reserved' => TableStatus.reserved,
      _ => TableStatus.free,
    };

/// An open order sitting on a table. A table may hold several — two parties
/// sharing it, each with its own bill.
class SeatedParty {
  const SeatedParty({
    required this.orderId,
    required this.orderNo,
    this.seatLabel,
    this.itemCount = 0,
  });

  final String orderId;
  final int orderNo;
  final String? seatLabel;

  /// Lines on the order. Zero means nobody has ordered anything yet — a
  /// mis-tap, or a screen left by a crash, holding the table for nothing.
  final int itemCount;

  bool get isEmpty => itemCount == 0;

  /// What the floor screen shows on the chip.
  String get label => seatLabel ?? '#$orderNo';

  factory SeatedParty.fromJson(Map<String, dynamic> json) => SeatedParty(
        orderId: json['orderId'] as String,
        orderNo: json['orderNo'] as int,
        seatLabel: json['seatLabel'] as String?,
        itemCount: json['itemCount'] as int? ?? 0,
      );
}

class DiningTable {
  const DiningTable({
    required this.id,
    required this.sectionId,
    required this.name,
    required this.seats,
    required this.status,
    required this.parties,
  });

  final String id;
  final String sectionId;
  final String name;
  final int seats;
  final TableStatus status;
  final List<SeatedParty> parties;

  bool get isFree => status == TableStatus.free;
  bool get hasMultipleParties => parties.length > 1;

  /// Whether tapping this table has to ask who is meant.
  ///
  /// True for one party as well as several. The picker is the only place that
  /// offers "seat another party", so a table holding exactly one person must
  /// still show it — opening that person's order directly, as a shortcut, left
  /// no way to seat a second party at all.
  bool get needsPartyChoice => parties.isNotEmpty;

  factory DiningTable.fromJson(Map<String, dynamic> json) => DiningTable(
        id: json['id'] as String,
        sectionId: json['sectionId'] as String,
        name: json['name'] as String,
        seats: json['seats'] as int,
        status: _statusFrom(json['status'] as String),
        parties: ((json['parties'] as List<dynamic>?) ?? const [])
            .map((p) => SeatedParty.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
}

class FloorSection {
  const FloorSection({
    required this.id,
    required this.name,
    required this.tables,
  });

  final String id;
  final String name;
  final List<DiningTable> tables;

  factory FloorSection.fromJson(Map<String, dynamic> json) => FloorSection(
        id: json['id'] as String,
        name: json['name'] as String,
        tables: ((json['tables'] as List<dynamic>?) ?? const [])
            .map((t) => DiningTable.fromJson(t as Map<String, dynamic>))
            .toList(),
      );
}
