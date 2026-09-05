enum PaymentMode { cash, card, upi }

extension PaymentModeLabel on PaymentMode {
  String get label => switch (this) {
    PaymentMode.cash => 'Cash',
    PaymentMode.card => 'Card',
    PaymentMode.upi => 'UPI',
  };

  String get wire => name;
}

enum PaymentStatus { unpaid, partial, paid }

class BillPayment {
  const BillPayment({
    required this.id,
    required this.mode,
    required this.amount,
    required this.isReversed,
    this.reference,
  });

  final String id;
  final PaymentMode mode;
  final int amount;
  final bool isReversed;
  final String? reference;

  factory BillPayment.fromJson(Map<String, dynamic> json) => BillPayment(
    id: json['id'] as String,
    mode: switch (json['mode']) {
      'card' => PaymentMode.card,
      'upi' => PaymentMode.upi,
      _ => PaymentMode.cash,
    },
    amount: json['amount'] as int,
    isReversed: json['reversedAt'] != null,
    reference: json['reference'] as String?,
  );
}

/// One rate's share of the tax, as GST requires on the printout.
class TaxGroup {
  const TaxGroup({
    required this.rate,
    required this.base,
    required this.cgst,
    required this.sgst,
  });

  final int rate;
  final int base;
  final int cgst;
  final int sgst;

  factory TaxGroup.fromJson(Map<String, dynamic> json) => TaxGroup(
    rate: json['rate'] as int,
    base: json['base'] as int,
    cgst: json['cgst'] as int,
    sgst: json['sgst'] as int,
  );
}

/// One change made to a bill after it was created.
///
/// A bill is overwritten in place, so it holds only its latest figures. This is
/// the record of what it said before — the only place the original total
/// survives, and what someone reads when a number does not reconcile.
class BillAmendment {
  const BillAmendment({
    required this.id,
    required this.kind,
    required this.wasPrinted,
    required this.wasPaid,
    required this.createdAt,
    this.totalBefore,
    this.totalAfter,
    this.reason,
    this.amendedBy,
  });

  final String id;

  /// `items`, `discount`, or `customer`.
  final String kind;

  /// Null for a customer-detail edit, which moves no money.
  final int? totalBefore;
  final int? totalAfter;

  /// Whether a document already existed when this change was made.
  final bool wasPrinted;
  final bool wasPaid;

  final String? reason;
  final String? amendedBy;
  final DateTime? createdAt;

  String get label => switch (kind) {
    'items' => 'Items changed',
    'discount' => 'Discount changed',
    _ => 'Customer details changed',
  };

  bool get movedMoney => totalBefore != null && totalAfter != null;

  factory BillAmendment.fromJson(Map<String, dynamic> json) => BillAmendment(
    id: json['id'] as String,
    kind: json['kind'] as String? ?? 'items',
    totalBefore: json['totalBefore'] as int?,
    totalAfter: json['totalAfter'] as int?,
    wasPrinted: json['wasPrinted'] as bool? ?? false,
    wasPaid: json['wasPaid'] as bool? ?? false,
    reason: json['reason'] as String?,
    amendedBy: json['amendedBy'] as String?,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal(),
  );
}

/// A computed total that has not been persisted.
class BillPreview {
  const BillPreview({
    required this.subtotal,
    required this.discountAmount,
    required this.cgst,
    required this.sgst,
    required this.roundOff,
    required this.total,
    required this.taxBreakdown,
  });

  final int subtotal;
  final int discountAmount;
  final int cgst;
  final int sgst;
  final int roundOff;
  final int total;
  final List<TaxGroup> taxBreakdown;

  factory BillPreview.fromJson(Map<String, dynamic> json) => BillPreview(
    subtotal: json['subtotal'] as int,
    discountAmount: json['discountAmount'] as int,
    cgst: json['cgst'] as int,
    sgst: json['sgst'] as int,
    roundOff: json['roundOff'] as int,
    total: json['total'] as int,
    taxBreakdown: ((json['taxBreakdown'] as List<dynamic>?) ?? const [])
        .map((g) => TaxGroup.fromJson(g as Map<String, dynamic>))
        .toList(),
  );
}

/// One line on an issued bill.
///
/// These are the values snapshotted when the item was ordered, not the menu as
/// it stands today — renaming a dish must not rewrite a bill already printed.
class BillItem {
  const BillItem({
    required this.itemName,
    required this.variantName,
    required this.qty,
    required this.unitPrice,
    required this.taxRate,
    required this.lineTax,
    required this.lineTotal,
  });

  final String itemName;
  final String variantName;
  final int qty;

  /// Paise, as charged.
  final int unitPrice;

  /// Basis points, as charged.
  final int taxRate;
  final int lineTax;
  final int lineTotal;

  /// Portions named `Standard` are the only size, so naming them adds nothing.
  String get displayName => variantName.isEmpty || variantName == 'Standard'
      ? itemName
      : '$itemName ($variantName)';

  factory BillItem.fromJson(Map<String, dynamic> json) => BillItem(
    itemName: json['itemName'] as String? ?? '',
    variantName: json['variantName'] as String? ?? '',
    qty: json['qty'] as int? ?? 0,
    unitPrice: json['unitPrice'] as int? ?? 0,
    taxRate: json['taxRate'] as int? ?? 0,
    lineTax: json['lineTax'] as int? ?? 0,
    lineTotal: json['lineTotal'] as int? ?? 0,
  );
}

/// Totals for a listed range.
///
/// Computed by the backend over every matching bill, not over the page that was
/// returned — a day with more bills than the page limit must still report its
/// real takings.
class BillSummary {
  const BillSummary({
    required this.count,
    required this.total,
    required this.collected,
    required this.outstanding,
  });

  final int count;

  /// Paise billed.
  final int total;

  /// Paise actually taken. Lower than [total] when something is unpaid.
  final int collected;
  final int outstanding;

  static const empty = BillSummary(
    count: 0,
    total: 0,
    collected: 0,
    outstanding: 0,
  );

  factory BillSummary.fromJson(Map<String, dynamic> json) => BillSummary(
    count: json['count'] as int? ?? 0,
    total: json['total'] as int? ?? 0,
    collected: json['collected'] as int? ?? 0,
    outstanding: json['outstanding'] as int? ?? 0,
  );
}

class BillList {
  const BillList({required this.bills, required this.summary});

  final List<Bill> bills;
  final BillSummary summary;
}

class Bill {
  const Bill({
    required this.id,
    required this.orderId,
    required this.billNumber,
    required this.businessDate,
    required this.createdAt,
    required this.subtotal,
    required this.discountAmount,
    required this.cgst,
    required this.sgst,
    required this.roundOff,
    required this.total,
    required this.amountPaid,
    required this.outstanding,
    required this.paymentStatus,
    required this.taxBreakdown,
    required this.payments,
    this.items = const [],
    this.orderNo,
    this.orderType,
    this.tableName,
    this.customerName,
    this.customerPhone,
    this.orderReopened = false,
    this.amendmentCount = 0,
  });

  final String id;
  final String orderId;

  /// The formatted string as printed, e.g. `CE/2026-27/0042`.
  final String billNumber;

  /// The trading day this bill belongs to, which is not always the calendar day
  /// it was created on — a 1 AM sale counts as the previous evening.
  final String businessDate;

  /// When it was created, for showing the time on the list.
  final DateTime? createdAt;

  final int subtotal;
  final int discountAmount;
  final int cgst;
  final int sgst;
  final int roundOff;
  final int total;
  final int amountPaid;
  final int outstanding;
  final PaymentStatus paymentStatus;
  final List<TaxGroup> taxBreakdown;
  final List<BillPayment> payments;

  /// Only populated by the single-bill endpoint; the list omits them.
  final List<BillItem> items;

  /// Sent by both endpoints — the list joins it in so a row can be traced
  /// back to the order it was billed from.
  final int? orderNo;

  /// dine_in or takeaway.
  final String? orderType;
  final String? tableName;

  /// Taken on the order when it was a phone or takeaway job. Usually null for
  /// a walk-in, which is why search must never require it to match.
  final String? customerName;
  final String? customerPhone;

  /// The order is open again for its items to be changed.
  ///
  /// While it is, the lines and these totals can disagree — the bill is only
  /// brought back in step when the amendment is saved. Payment is held back
  /// until then, because the figure on screen may already be wrong.
  final bool orderReopened;

  /// How many times this bill has been amended. Zero for most bills.
  final int amendmentCount;

  bool get wasAmended => amendmentCount > 0;

  /// Whether [query] matches anything a person would search a bill by.
  ///
  /// Matched against the bill number, the order number, and the customer —
  /// the four things someone holding a printed slip or answering the phone
  /// actually has to hand. Case-insensitive, and the caller passes [query]
  /// already lowercased and trimmed so a long list is not re-normalising it
  /// per row.
  bool matches(String query) {
    if (query.isEmpty) return true;
    if (billNumber.toLowerCase().contains(query)) return true;
    // Bare digits are how a bill number is read aloud: "fourteen", not
    // "BILL/20260902/014". Both the padded and unpadded forms match.
    if (orderNo != null && '$orderNo'.contains(query)) return true;
    if (customerName != null && customerName!.toLowerCase().contains(query)) {
      return true;
    }
    if (customerPhone != null && customerPhone!.contains(query)) return true;
    return false;
  }

  /// Where the order was taken, for the detail header.
  String get placeLabel {
    if (orderType == 'takeaway') return 'Takeaway';
    if (orderType == 'delivery') return 'Delivery';
    return tableName ?? 'Dine-in';
  }

  /// A delivery, where a name and a phone number are worth having.
  ///
  /// On a takeaway or a dine-in they are almost always empty — the customer
  /// was standing at the counter — so offering the fields on every bill put
  /// two blank boxes in front of staff on most of them.
  bool get isDelivery => orderType == 'delivery';

  bool get isPaid => paymentStatus == PaymentStatus.paid;

  /// Reversed payments stay on the record for audit but do not count.
  List<BillPayment> get livePayments =>
      payments.where((p) => !p.isReversed).toList();

  factory Bill.fromJson(Map<String, dynamic> json) => Bill(
    id: json['id'] as String,
    orderId: json['orderId'] as String,
    billNumber: json['billNumber'] as String? ?? '${json['billNo']}',
    businessDate: json['businessDate'] as String? ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '')?.toLocal(),
    items: ((json['items'] as List<dynamic>?) ?? const [])
        .map((i) => BillItem.fromJson(i as Map<String, dynamic>))
        .toList(),
    orderNo: json['orderNo'] as int?,
    orderType: json['orderType'] as String?,
    tableName: json['tableName'] as String?,
    customerName: json['customerName'] as String?,
    customerPhone: json['customerPhone'] as String?,
    // Absent on the list endpoint, which does not join the order's status.
    orderReopened: json['orderReopened'] as bool? ?? false,
    amendmentCount: json['amendmentCount'] as int? ?? 0,
    subtotal: json['subtotal'] as int,
    discountAmount: json['discountAmount'] as int? ?? 0,
    cgst: json['cgst'] as int? ?? 0,
    sgst: json['sgst'] as int? ?? 0,
    roundOff: json['roundOff'] as int? ?? 0,
    total: json['total'] as int,
    amountPaid: json['amountPaid'] as int? ?? 0,
    outstanding: json['outstanding'] as int? ?? 0,
    paymentStatus: switch (json['paymentStatus']) {
      'paid' => PaymentStatus.paid,
      'partial' => PaymentStatus.partial,
      _ => PaymentStatus.unpaid,
    },
    taxBreakdown: ((json['taxBreakdown'] as List<dynamic>?) ?? const [])
        .map((g) => TaxGroup.fromJson(g as Map<String, dynamic>))
        .toList(),
    payments: ((json['payments'] as List<dynamic>?) ?? const [])
        .map((p) => BillPayment.fromJson(p as Map<String, dynamic>))
        .toList(),
  );
}
