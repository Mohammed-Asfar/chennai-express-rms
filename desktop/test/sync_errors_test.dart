import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/sync/data/sync_repository.dart';

SyncFailure _failure(String error) =>
    SyncFailure(table: 'orders', error: error, count: 3, attempts: 5);

void main() {
  group('the message a restaurant reads', () {
    test('a missing parent names what is being waited for', () {
      // The message a live branch got for three days running.
      final failure = _failure(
        'insert or update on table "orders" violates foreign key constraint '
        '"orders_branch_id_fkey"',
      );

      expect(failure.plain, 'Waiting for the restaurant record to reach the cloud first.');
    });

    test('a staff reference reads as staff, not as a column name', () {
      final failure = _failure(
        'insert or update on table "bills" violates foreign key constraint '
        '"bills_voided_by_fkey"',
      );

      expect(failure.plain, contains('staff'));
      expect(failure.plain, isNot(contains('voided_by')));
    });

    test('a table whose name contains an underscore still resolves', () {
      // order_items_menu_item_variant_id_fkey cannot be split on underscores,
      // which is why the column is matched rather than parsed out.
      final failure = _failure(
        'insert or update on table "order_items" violates foreign key constraint '
        '"order_items_menu_item_variant_id_fkey"',
      );

      expect(failure.plain, isNot(contains('items_menu')));
      expect(failure.plain, contains('cloud'));
    });

    test('an unrecognised foreign key still says something useful', () {
      final failure = _failure(
        'insert or update on table "x" violates foreign key constraint "x_mystery_fkey"',
      );

      expect(failure.plain, 'Something this record points at has not reached the cloud yet.');
    });

    test('a missing column points at the cloud needing an update', () {
      final failure = _failure(
        'column "surcharge" of relation "sections" does not exist',
      );

      expect(failure.plain, contains('needs updating'));
    });

    test('anything unrecognised is passed through rather than invented', () {
      // Better a raw message than a confident wrong one.
      final failure = _failure('deadlock detected');
      expect(failure.plain, 'deadlock detected');
    });

    test('the raw error is always kept for support', () {
      const raw = 'insert or update on table "orders" violates foreign key '
          'constraint "orders_branch_id_fkey"';
      expect(_failure(raw).error, raw);
    });
  });

  test('failures parse from the API shape', () {
    final failure = SyncFailure.fromJson(const {
      'table': 'orders',
      'error': 'boom',
      'count': 28,
      'attempts': 5,
    });

    expect(failure.table, 'orders');
    expect(failure.count, 28);
    expect(failure.attempts, 5);
  });
}
