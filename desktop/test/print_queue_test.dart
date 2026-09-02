import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/printers/data/printer_repository.dart';

PrintJob job(Map<String, dynamic> overrides) => PrintJob.fromJson({
  'id': 'j1',
  'type': 'kot',
  'status': 'pending',
  'attempts': 0,
  'createdAt': '2026-09-02T10:30:00.000Z',
  ...overrides,
});

void main() {
  group('a queued job', () {
    test('names a kitchen ticket in the words used elsewhere', () {
      expect(job({'type': 'kot'}).label, 'Kitchen ticket');
      expect(job({'type': 'bill'}).label, 'Bill');
      expect(job({'type': 'test'}).label, 'Test page');
    });

    test('distinguishes an added-items ticket from a fresh one', () {
      // Cooking the whole order again because the panel called both "Kitchen
      // ticket" is the mistake this guards against.
      expect(job({'type': 'kot_additional'}).label, isNot(job({'type': 'kot'}).label));
      expect(job({'type': 'kot_cancel'}).label, contains('cancellation'));
    });

    test('falls back to the raw type rather than showing nothing', () {
      expect(job({'type': 'something_new'}).label, 'something_new');
    });

    test('knows whether it gave up', () {
      expect(job({'status': 'failed'}).hasFailed, isTrue);
      expect(job({'status': 'pending'}).hasFailed, isFalse);
    });

    test('survives a printer that has since been removed', () {
      // printerName is null when the printer was deleted; the panel must not
      // throw on a job it is trying to tell someone about.
      final removed = job({'printerName': null});
      expect(removed.printerName, isNull);
      expect(removed.label, isNotEmpty);
    });

    test('reads the error text the panel shows', () {
      expect(
        job({'status': 'failed', 'lastError': 'Printer offline'}).lastError,
        'Printer offline',
      );
    });

    test('parses the queued time to local', () {
      expect(job({}).createdAt, isNotNull);
      expect(job({}).createdAt!.isUtc, isFalse);
    });

    test('tolerates a missing timestamp instead of failing to render', () {
      expect(job({'createdAt': null}).createdAt, isNull);
    });
  });
}
