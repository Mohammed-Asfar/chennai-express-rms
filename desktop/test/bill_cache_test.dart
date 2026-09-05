import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// The bill detail is a `FutureProvider.family` keyed on the bill id, and it
/// caches until invalidated. Refreshing only the list leaves the next open
/// showing the figures from before the change — a bill whose row reads
/// PART PAID ₹405 opening as PAID ₹125.
///
/// The provider is private, so a widget test cannot override or read it. What
/// can be checked, and what actually went wrong, is that nobody refreshes half
/// of it: `invalidateBill` does both, and every caller goes through it.
void main() {
  final lib = Directory('lib');

  test('nothing refreshes the bill list without the detail', () {
    // One offender is enough to reintroduce the bug, so this reads every file
    // rather than the ones that happen to be suspect today.
    final offenders = <String>[];

    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      if (!source.contains('invalidate(billListProvider)')) continue;

      // The two screens that only ever show the list are legitimate: they hold
      // no detail to go stale.
      final listOnly =
          file.path.endsWith('bills_screen.dart') || file.path.endsWith('home_screen.dart');
      if (listOnly) continue;

      // Everywhere else, the only place that line may appear is inside
      // invalidateBill itself.
      if (!source.contains('void invalidateBill(')) {
        offenders.add(file.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'these refresh the list but not the cached bill: $offenders',
    );
  });

  test('invalidateBill clears both', () {
    final source = File(
      'lib/features/billing/presentation/bill_detail_dialog.dart',
    ).readAsStringSync();

    final body = source.substring(source.indexOf('void invalidateBill('));
    final end = body.indexOf('\n}');
    final fn = body.substring(0, end);

    expect(fn, contains('_billDetailProvider'), reason: 'the cached bill');
    expect(fn, contains('billListProvider'), reason: 'and the list it sits in');
  });

  test('a delivery bill shows where it is going', () {
    // The phone and address are recorded at the till and printed on the bill,
    // so not showing them on screen left the one person holding the bill —
    // whoever hands it to the rider — with nowhere to read them.
    //
    // A widget test cannot reach this: the dialog fetches through a private
    // provider that cannot be overridden. What can be pinned is that the block
    // exists and is gated on the bill being a delivery.
    final source = File(
      'lib/features/billing/presentation/bill_detail_dialog.dart',
    ).readAsStringSync();

    expect(source, contains('Delivering to'));
    expect(
      source,
      contains('bill.isDelivery'),
      reason: 'shown on a delivery, not on every bill',
    );
    expect(
      source,
      contains('customerPhone'),
      reason: 'the number someone calls when the rider is lost',
    );
  });

  test('the order screen refreshes the bill it just amended', () {
    // Update bill lives on the order screen, outside the dialog that owns the
    // cache, which is exactly how it came to refresh nothing at all.
    final source = File(
      'lib/features/order/presentation/order_screen.dart',
    ).readAsStringSync();

    expect(source, contains('amend('));
    expect(
      source,
      contains('invalidateBill('),
      reason: 'amending from the order screen must not leave a stale bill',
    );
  });
}
