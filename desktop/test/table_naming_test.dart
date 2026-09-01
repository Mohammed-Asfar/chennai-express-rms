import 'package:flutter_test/flutter_test.dart';

/// Mirrors _namesToCreate in table_dialog.dart. Kept in step by hand; the logic
/// is small and naming twenty tables wrong at setup is worth guarding.
List<String> namesToCreate(String base, int count) {
  if (count <= 1) return [base];
  final match = RegExp(r'^(.*?)(\d+)$').firstMatch(base);
  final prefix = match?.group(1) ?? base;
  final start = match == null ? 1 : int.parse(match.group(2)!);
  final width = match?.group(2)?.length ?? 0;
  return [
    for (var i = 0; i < count; i++)
      '$prefix${(start + i).toString().padLeft(width, '0')}',
  ];
}

void main() {
  group('bulk table naming', () {
    test('counts up from a trailing number', () {
      expect(namesToCreate('A1', 3), ['A1', 'A2', 'A3']);
    });

    test('starts from whatever number is given', () {
      expect(namesToCreate('T5', 3), ['T5', 'T6', 'T7']);
    });

    test('preserves zero padding', () {
      expect(namesToCreate('T01', 3), ['T01', 'T02', 'T03']);
      // Padding holds until the number outgrows it.
      expect(namesToCreate('T08', 3), ['T08', 'T09', 'T10']);
    });

    test('a name with no number gets suffixes', () {
      expect(namesToCreate('Patio', 3), ['Patio1', 'Patio2', 'Patio3']);
    });

    test('a count of one is just the name', () {
      expect(namesToCreate('A1', 1), ['A1']);
      expect(namesToCreate('Corner', 1), ['Corner']);
    });

    test('multi-digit and embedded numbers', () {
      expect(namesToCreate('A10', 3), ['A10', 'A11', 'A12']);
      // Only the trailing run counts, so a name like this stays sensible.
      expect(namesToCreate('AC2-1', 2), ['AC2-1', 'AC2-2']);
    });

    test('names are unique across a run', () {
      final names = namesToCreate('A1', 20);
      expect(names.toSet().length, 20);
    });
  });
}
