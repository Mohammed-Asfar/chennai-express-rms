import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/sync/data/purge_repository.dart';
import 'package:chennai_express_pos/features/reports/data/export_repository.dart';

void main() {
  group('purge preview', () {
    test('an unexported range is flagged', () {
      // The warning is the only thing standing between an operator and losing
      // bills they have no copy of.
      const preview = PurgePreview(
        bills: 40,
        orders: 45,
        payments: 38,
        orderItems: 120,
        exported: false,
        missingExports: ['bills', 'bill_items', 'payments'],
      );

      expect(preview.exported, isFalse);
      expect(preview.missingExports, hasLength(3));
      expect(preview.isEmpty, isFalse);
    });

    test('nothing to clear is not the same as nothing exported', () {
      // An empty range must not show a scary warning about unexported data
      // that does not exist. The button says "Nothing to clear" instead.
      const preview = PurgePreview(
        bills: 0,
        orders: 0,
        payments: 0,
        orderItems: 0,
        exported: false,
        missingExports: ['bills'],
      );

      expect(preview.isEmpty, isTrue);
    });

    test('a response missing fields does not crash the screen', () {
      // A backend one version behind must not break the dialog that decides
      // whether records are destroyed.
      final preview = PurgePreview.fromJson(const {});
      expect(preview.bills, 0);
      expect(preview.exported, isFalse, reason: 'absent means unexported, not safe');
      expect(preview.missingExports, isEmpty);
    });

    test('the counts are read as sent', () {
      final preview = PurgePreview.fromJson(const {
        'bills': 12,
        'orders': 14,
        'payments': 11,
        'orderItems': 38,
        'exported': true,
        'missingExports': <String>[],
      });

      expect(preview.bills, 12);
      expect(preview.orderItems, 38);
      expect(preview.exported, isTrue);
      expect(preview.isEmpty, isFalse);
    });
  });

  group('purge result', () {
    test('a cloud failure is carried back, not swallowed', () {
      // The till is cleared and the cloud is not. Not a failed purge, but the
      // operator has to be told or they will believe both are gone.
      final result = PurgeResult.fromJson(const {
        'bills': 40,
        'orders': 45,
        'payments': 38,
        'cloudRemoved': null,
        'cloudError': 'connection refused',
      });

      expect(result.bills, 40);
      expect(result.cloudRemoved, isNull);
      expect(result.cloudError, 'connection refused');
    });

    test('a clean run reports what the cloud removed', () {
      final result = PurgeResult.fromJson(const {
        'bills': 40,
        'orders': 45,
        'payments': 38,
        'cloudRemoved': 123,
        'cloudError': null,
      });

      expect(result.cloudRemoved, 123);
      expect(result.cloudError, isNull);
    });
  });

  group('export kinds', () {
    test('every kind has a path the backend serves', () {
      // The paths are half of a contract with the backend routes. A typo here
      // is a 404 at the moment someone is trying to save their records.
      expect(ExportKind.bills.path, 'bills');
      expect(ExportKind.billItems.path, 'bill-items');
      expect(ExportKind.payments.path, 'payments');
    });

    test('every kind is described for someone who is not an accountant', () {
      for (final kind in ExportKind.values) {
        expect(kind.label, isNotEmpty);
        expect(kind.description, isNotEmpty);
      }
    });
  });
}
