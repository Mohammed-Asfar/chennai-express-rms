import '../../billing/data/bill_models.dart' show PaymentMode, PaymentStatus;

/// The trading days a report covers.
///
/// These are business dates, not calendar dates: a restaurant serving past
/// midnight books a 1 AM sale on the previous trading day. Every report echoes
/// the range back so the figures can never be read against the wrong days.
class ReportRange {
  const ReportRange({required this.from, required this.to});

  final String from;
  final String to;

  bool get isSingleDay => from == to;

  factory ReportRange.fromJson(Map<String, dynamic> json) => ReportRange(
    from: json['from'] as String? ?? '',
    to: json['to'] as String? ?? '',
  );
}

/// Sales for bills *dated* in the range. Every money field is paise.
class SalesTotals {
  const SalesTotals({
    required this.billCount,
    required this.totalSales,
    required this.averageBillValue,
    required this.subtotal,
    required this.discountTotal,
    required this.cgst,
    required this.sgst,
    required this.roundOff,
    required this.collected,
    required this.outstanding,
  });

  final int billCount;
  final int totalSales;
  final int averageBillValue;
  final int subtotal;
  final int discountTotal;
  final int cgst;
  final int sgst;
  final int roundOff;

  /// Paid against bills dated in this range — deliberately not the same figure
  /// as [Collections.total], which counts money taken in the range instead.
  final int collected;

  final int outstanding;

  factory SalesTotals.fromJson(Map<String, dynamic> json) => SalesTotals(
    billCount: json['billCount'] as int? ?? 0,
    totalSales: json['totalSales'] as int? ?? 0,
    averageBillValue: json['averageBillValue'] as int? ?? 0,
    subtotal: json['subtotal'] as int? ?? 0,
    discountTotal: json['discountTotal'] as int? ?? 0,
    cgst: json['cgst'] as int? ?? 0,
    sgst: json['sgst'] as int? ?? 0,
    roundOff: json['roundOff'] as int? ?? 0,
    collected: json['collected'] as int? ?? 0,
    outstanding: json['outstanding'] as int? ?? 0,
  );
}

class CollectionByMode {
  const CollectionByMode({
    required this.mode,
    required this.count,
    required this.amount,
  });

  final PaymentMode mode;
  final int count;
  final int amount;

  factory CollectionByMode.fromJson(Map<String, dynamic> json) =>
      CollectionByMode(
        mode: switch (json['mode']) {
          'card' => PaymentMode.card,
          'upi' => PaymentMode.upi,
          _ => PaymentMode.cash,
        },
        count: json['count'] as int? ?? 0,
        amount: json['amount'] as int? ?? 0,
      );
}

/// Money actually taken in the range, whatever day the bill was dated.
class Collections {
  const Collections({required this.total, required this.byMode});

  final int total;
  final List<CollectionByMode> byMode;

  factory Collections.fromJson(Map<String, dynamic> json) => Collections(
    total: json['total'] as int? ?? 0,
    byMode: ((json['byMode'] as List<dynamic>?) ?? const [])
        .map((m) => CollectionByMode.fromJson(m as Map<String, dynamic>))
        .toList(),
  );
}

/// Where an order went.
///
/// Delivery behaves exactly like takeaway — no table, nothing extra required —
/// and exists so the two can be told apart on a bill and in the sales report.
enum OrderType { dineIn, takeaway, delivery }

extension OrderTypeLabel on OrderType {
  String get label => switch (this) {
    OrderType.dineIn => 'Dine-in',
    OrderType.takeaway => 'Takeaway',
    OrderType.delivery => 'Delivery',
  };

  /// The value the backend stores.
  String get wire => switch (this) {
    OrderType.dineIn => 'dine_in',
    OrderType.takeaway => 'takeaway',
    OrderType.delivery => 'delivery',
  };
}

OrderType _orderTypeFrom(Object? wire) => switch (wire) {
  'takeaway' => OrderType.takeaway,
  'delivery' => OrderType.delivery,
  _ => OrderType.dineIn,
};

class OrderTypeSales {
  const OrderTypeSales({
    required this.type,
    required this.billCount,
    required this.totalSales,
  });

  final OrderType type;
  final int billCount;
  final int totalSales;

  factory OrderTypeSales.fromJson(Map<String, dynamic> json) => OrderTypeSales(
    type: _orderTypeFrom(json['type']),
    billCount: json['billCount'] as int? ?? 0,
    totalSales: json['totalSales'] as int? ?? 0,
  );
}

class SectionSales {
  const SectionSales({
    required this.sectionId,
    required this.sectionName,
    required this.billCount,
    required this.totalSales,
  });

  /// Null for takeaway, which is served from no section.
  final String? sectionId;
  final String? sectionName;

  final int billCount;
  final int totalSales;

  /// What to show when there is no section behind the row.
  String get displayName => sectionName ?? 'Takeaway';

  factory SectionSales.fromJson(Map<String, dynamic> json) => SectionSales(
    sectionId: json['sectionId'] as String?,
    sectionName: json['sectionName'] as String?,
    billCount: json['billCount'] as int? ?? 0,
    totalSales: json['totalSales'] as int? ?? 0,
  );
}

class DiscountByUser {
  const DiscountByUser({
    required this.userId,
    required this.username,
    required this.fullName,
    required this.billCount,
    required this.discountTotal,
  });

  final String userId;
  final String username;
  final String fullName;
  final int billCount;
  final int discountTotal;

  factory DiscountByUser.fromJson(Map<String, dynamic> json) => DiscountByUser(
    userId: json['userId'] as String? ?? '',
    username: json['username'] as String? ?? '',
    fullName: json['fullName'] as String? ?? '',
    billCount: json['billCount'] as int? ?? 0,
    discountTotal: json['discountTotal'] as int? ?? 0,
  );
}

class Discounts {
  const Discounts({required this.total, required this.byUser});

  final int total;
  final List<DiscountByUser> byUser;

  factory Discounts.fromJson(Map<String, dynamic> json) => Discounts(
    total: json['total'] as int? ?? 0,
    byUser: ((json['byUser'] as List<dynamic>?) ?? const [])
        .map((u) => DiscountByUser.fromJson(u as Map<String, dynamic>))
        .toList(),
  );
}

class VoidedBill {
  const VoidedBill({
    required this.id,
    required this.billNumber,
    required this.businessDate,
    required this.total,
    this.reason,
    this.voidedAt,
    this.voidedByName,
  });

  final String id;
  final String billNumber;
  final String businessDate;
  final int total;
  final String? reason;
  final String? voidedAt;
  final String? voidedByName;

  factory VoidedBill.fromJson(Map<String, dynamic> json) => VoidedBill(
    id: json['id'] as String? ?? '',
    billNumber: json['billNumber'] as String? ?? '',
    businessDate: json['businessDate'] as String? ?? '',
    total: json['total'] as int? ?? 0,
    reason: json['reason'] as String?,
    voidedAt: json['voidedAt'] as String?,
    voidedByName: json['voidedByName'] as String?,
  );
}

class VoidedSummary {
  const VoidedSummary({
    required this.billCount,
    required this.total,
    required this.bills,
  });

  final int billCount;
  final int total;
  final List<VoidedBill> bills;

  factory VoidedSummary.fromJson(Map<String, dynamic> json) => VoidedSummary(
    billCount: json['billCount'] as int? ?? 0,
    total: json['total'] as int? ?? 0,
    bills: ((json['bills'] as List<dynamic>?) ?? const [])
        .map((b) => VoidedBill.fromJson(b as Map<String, dynamic>))
        .toList(),
  );
}

class CancelledOrder {
  const CancelledOrder({
    required this.id,
    required this.orderNo,
    required this.businessDate,
    required this.type,
    required this.value,
    this.reason,
    this.cancelledAt,
  });

  final String id;
  final int? orderNo;
  final String businessDate;
  final OrderType type;

  /// What the lines were worth when the order was killed.
  final int value;

  final String? reason;
  final String? cancelledAt;

  factory CancelledOrder.fromJson(Map<String, dynamic> json) => CancelledOrder(
    id: json['id'] as String? ?? '',
    orderNo: json['orderNo'] as int?,
    businessDate: json['businessDate'] as String? ?? '',
    type: _orderTypeFrom(json['type']),
    value: json['value'] as int? ?? 0,
    reason: json['reason'] as String?,
    cancelledAt: json['cancelledAt'] as String?,
  );
}

class CancelledSummary {
  const CancelledSummary({
    required this.orderCount,
    required this.total,
    required this.orders,
  });

  final int orderCount;
  final int total;
  final List<CancelledOrder> orders;

  factory CancelledSummary.fromJson(Map<String, dynamic> json) =>
      CancelledSummary(
        orderCount: json['orderCount'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        orders: ((json['orders'] as List<dynamic>?) ?? const [])
            .map((o) => CancelledOrder.fromJson(o as Map<String, dynamic>))
            .toList(),
      );
}

/// Everything `GET /reports/summary` returns for a range of trading days.
class ReportSummary {
  const ReportSummary({
    required this.range,
    required this.sales,
    required this.collections,
    required this.byOrderType,
    required this.bySection,
    required this.discounts,
    required this.voided,
    required this.cancelled,
  });

  final ReportRange range;
  final SalesTotals sales;
  final Collections collections;
  final List<OrderTypeSales> byOrderType;
  final List<SectionSales> bySection;
  final Discounts discounts;
  final VoidedSummary voided;
  final CancelledSummary cancelled;

  /// True when nothing was billed and nothing was taken in the range. Voids and
  /// cancellations still count as activity worth showing.
  bool get isEmpty =>
      sales.billCount == 0 &&
      collections.total == 0 &&
      voided.billCount == 0 &&
      cancelled.orderCount == 0;

  factory ReportSummary.fromJson(Map<String, dynamic> json) => ReportSummary(
    range: ReportRange.fromJson(
      (json['range'] as Map<String, dynamic>?) ?? const {},
    ),
    sales: SalesTotals.fromJson(
      (json['sales'] as Map<String, dynamic>?) ?? const {},
    ),
    collections: Collections.fromJson(
      (json['collections'] as Map<String, dynamic>?) ?? const {},
    ),
    byOrderType: ((json['byOrderType'] as List<dynamic>?) ?? const [])
        .map((t) => OrderTypeSales.fromJson(t as Map<String, dynamic>))
        .toList(),
    bySection: ((json['bySection'] as List<dynamic>?) ?? const [])
        .map((s) => SectionSales.fromJson(s as Map<String, dynamic>))
        .toList(),
    discounts: Discounts.fromJson(
      (json['discounts'] as Map<String, dynamic>?) ?? const {},
    ),
    voided: VoidedSummary.fromJson(
      (json['voided'] as Map<String, dynamic>?) ?? const {},
    ),
    cancelled: CancelledSummary.fromJson(
      (json['cancelled'] as Map<String, dynamic>?) ?? const {},
    ),
  );
}

/// One dish's contribution over the range, already aggregated by the backend.
class ItemSales {
  const ItemSales({
    required this.itemName,
    required this.variantName,
    required this.qty,
    required this.revenue,
    required this.tax,
    required this.gross,
  });

  final String itemName;
  final String variantName;
  final int qty;

  /// Pre-tax, before any bill-level discount.
  final int revenue;

  final int tax;
  final int gross;

  /// The dish and its variant as one label, when the variant adds anything.
  String get displayName =>
      variantName.isEmpty ? itemName : '$itemName · $variantName';

  factory ItemSales.fromJson(Map<String, dynamic> json) => ItemSales(
    itemName: json['itemName'] as String? ?? '',
    variantName: json['variantName'] as String? ?? '',
    qty: json['qty'] as int? ?? 0,
    revenue: json['revenue'] as int? ?? 0,
    tax: json['tax'] as int? ?? 0,
    gross: json['gross'] as int? ?? 0,
  );
}

class ItemSalesTotals {
  const ItemSalesTotals({
    required this.qty,
    required this.revenue,
    required this.gross,
  });

  final int qty;
  final int revenue;
  final int gross;

  factory ItemSalesTotals.fromJson(Map<String, dynamic> json) =>
      ItemSalesTotals(
        qty: json['qty'] as int? ?? 0,
        revenue: json['revenue'] as int? ?? 0,
        gross: json['gross'] as int? ?? 0,
      );
}

/// `GET /reports/items` — item-wise sales, already sorted by revenue desc.
class ItemSalesReport {
  const ItemSalesReport({
    required this.range,
    required this.items,
    required this.totals,
  });

  final ReportRange range;
  final List<ItemSales> items;
  final ItemSalesTotals totals;

  factory ItemSalesReport.fromJson(Map<String, dynamic> json) =>
      ItemSalesReport(
        range: ReportRange.fromJson(
          (json['range'] as Map<String, dynamic>?) ?? const {},
        ),
        items: ((json['items'] as List<dynamic>?) ?? const [])
            .map((i) => ItemSales.fromJson(i as Map<String, dynamic>))
            .toList(),
        totals: ItemSalesTotals.fromJson(
          (json['totals'] as Map<String, dynamic>?) ?? const {},
        ),
      );
}

/// A bill with money still owed on it.
class OutstandingBill {
  const OutstandingBill({
    required this.id,
    required this.billNumber,
    required this.businessDate,
    required this.total,
    required this.amountPaid,
    required this.outstanding,
    required this.paymentStatus,
    required this.ageDays,
    this.orderNo,
    this.orderType,
    this.customerName,
    this.customerPhone,
  });

  final String id;
  final String billNumber;
  final String businessDate;
  final int total;
  final int amountPaid;
  final int outstanding;
  final PaymentStatus paymentStatus;

  /// Whole days from the bill's business date to the current trading day.
  final int ageDays;

  final int? orderNo;
  final OrderType? orderType;
  final String? customerName;
  final String? customerPhone;

  factory OutstandingBill.fromJson(Map<String, dynamic> json) => OutstandingBill(
    id: json['id'] as String? ?? '',
    billNumber: json['billNumber'] as String? ?? '',
    businessDate: json['businessDate'] as String? ?? '',
    total: json['total'] as int? ?? 0,
    amountPaid: json['amountPaid'] as int? ?? 0,
    outstanding: json['outstanding'] as int? ?? 0,
    paymentStatus: json['paymentStatus'] == 'partial'
        ? PaymentStatus.partial
        : PaymentStatus.unpaid,
    ageDays: json['ageDays'] as int? ?? 0,
    orderNo: json['orderNo'] as int?,
    orderType: json['orderType'] == null
        ? null
        : _orderTypeFrom(json['orderType']),
    customerName: json['customerName'] as String?,
    customerPhone: json['customerPhone'] as String?,
  );
}

/// `GET /reports/outstanding` — deliberately not range-filtered, because a debt
/// from three weeks ago is still owed today.
class OutstandingReport {
  const OutstandingReport({
    required this.asOf,
    required this.billCount,
    required this.total,
    required this.bills,
  });

  final String asOf;
  final int billCount;
  final int total;
  final List<OutstandingBill> bills;

  factory OutstandingReport.fromJson(Map<String, dynamic> json) =>
      OutstandingReport(
        asOf: json['asOf'] as String? ?? '',
        billCount: json['billCount'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        bills: ((json['bills'] as List<dynamic>?) ?? const [])
            .map((b) => OutstandingBill.fromJson(b as Map<String, dynamic>))
            .toList(),
      );
}

/// One trading day in the sales trend.
///
/// Days the restaurant took nothing still arrive as zero rows, so the chart
/// draws a dip rather than a straight line across a closed day.
class DailySales {
  const DailySales({
    required this.businessDate,
    required this.billCount,
    required this.totalSales,
    required this.collected,
  });

  final String businessDate;
  final int billCount;
  final int totalSales;
  final int collected;

  /// The day of the month, for a compact axis label.
  String get dayLabel {
    final parts = businessDate.split('-');
    return parts.length == 3 ? parts[2] : businessDate;
  }

  factory DailySales.fromJson(Map<String, dynamic> json) => DailySales(
    businessDate: json['businessDate'] as String? ?? '',
    billCount: json['billCount'] as int? ?? 0,
    totalSales: json['totalSales'] as int? ?? 0,
    collected: json['collected'] as int? ?? 0,
  );
}

/// `GET /reports/daily` — the per-day series behind the trend chart.
class DailySalesReport {
  const DailySalesReport({required this.range, required this.days});

  final ReportRange range;
  final List<DailySales> days;

  /// The largest day in the series, for scaling the chart's axis.
  int get peak =>
      days.isEmpty ? 0 : days.map((d) => d.totalSales).reduce((a, b) => a > b ? a : b);

  factory DailySalesReport.fromJson(Map<String, dynamic> json) => DailySalesReport(
    range: ReportRange.fromJson(
      (json['range'] as Map<String, dynamic>?) ?? const {},
    ),
    days: ((json['days'] as List<dynamic>?) ?? const [])
        .map((d) => DailySales.fromJson(d as Map<String, dynamic>))
        .toList(),
  );
}
