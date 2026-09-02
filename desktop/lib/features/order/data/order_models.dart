enum OrderType { dineIn, takeaway }

enum OrderStatus { open, billed, cancelled }

class OrderLine {
  const OrderLine({
    required this.id,
    required this.variantId,
    required this.itemName,
    required this.variantName,
    required this.unitPrice,
    required this.qty,
    required this.lineTotal,
    required this.kotPrinted,
    this.notes,
  });

  final String id;
  final String variantId;

  /// Snapshots taken when the line was added. The menu may have changed since.
  final String itemName;
  final String variantName;
  final int unitPrice;

  final int qty;
  final int lineTotal;
  final bool kotPrinted;
  final String? notes;

  /// "Chicken Biryani" or "Chicken Biryani (Full)" — the portion is only worth
  /// showing when the item has more than the default one.
  String get displayName =>
      variantName == 'Standard' ? itemName : '$itemName ($variantName)';

  factory OrderLine.fromJson(Map<String, dynamic> json) => OrderLine(
        id: json['id'] as String,
        variantId: json['variantId'] as String,
        itemName: json['itemName'] as String,
        variantName: json['variantName'] as String,
        unitPrice: json['unitPrice'] as int,
        qty: json['qty'] as int,
        lineTotal: json['lineTotal'] as int,
        kotPrinted: json['kotPrinted'] as bool? ?? false,
        notes: json['notes'] as String?,
      );
}

class Order {
  const Order({
    required this.id,
    required this.orderNo,
    required this.type,
    required this.status,
    required this.version,
    required this.lines,
    required this.subtotal,
    required this.tax,
    required this.total,
    required this.itemCount,
    this.tableId,
    this.seatLabel,
    this.customerName,
  });

  final String id;
  final int orderNo;
  final OrderType type;
  final OrderStatus status;

  /// Optimistic concurrency token; sent back on edits.
  final int version;

  final List<OrderLine> lines;
  final int subtotal;
  final int tax;
  final int total;
  final int itemCount;
  final String? tableId;
  final String? seatLabel;
  final String? customerName;

  bool get isOpen => status == OrderStatus.open;
  bool get isEmpty => lines.isEmpty;

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        id: json['id'] as String,
        orderNo: json['orderNo'] as int,
        type: json['type'] == 'dine_in' ? OrderType.dineIn : OrderType.takeaway,
        status: switch (json['status']) {
          'billed' => OrderStatus.billed,
          'cancelled' => OrderStatus.cancelled,
          _ => OrderStatus.open,
        },
        version: json['version'] as int? ?? 1,
        lines: ((json['items'] as List<dynamic>?) ?? const [])
            .map((l) => OrderLine.fromJson(l as Map<String, dynamic>))
            .toList(),
        subtotal: json['subtotal'] as int? ?? 0,
        tax: json['tax'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        itemCount: json['itemCount'] as int? ?? 0,
        tableId: json['tableId'] as String?,
        seatLabel: json['seatLabel'] as String?,
        customerName: json['customerName'] as String?,
      );
}
