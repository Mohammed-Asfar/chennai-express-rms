import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/floor/data/floor_models.dart';

SeatedParty party({required int items}) =>
    SeatedParty(orderId: 'o$items', orderNo: 1, itemCount: items);

/// Mirrors the condition in floor_screen.dart: the option appears only when a
/// table is held, and nothing has been ordered on any party.
bool canFree(List<SeatedParty> parties) =>
    parties.isNotEmpty && parties.every((p) => p.isEmpty);

void main() {
  group('freeing a stranded table', () {
    test('offered when the only order has nothing on it', () {
      // The case that strands a table: an order opened, nothing added, the
      // screen left. The floor shows SEATED with no way back.
      expect(canFree([party(items: 0)]), isTrue);
    });

    test('not offered once something is ordered', () {
      // A table with real food is freed by billing or cancelling, both of
      // which ask for a reason. Discarding it silently would lose the order.
      expect(canFree([party(items: 1)]), isFalse);
    });

    test('not offered on a free table', () {
      expect(canFree(const []), isFalse);
    });

    test('needs every party empty, not just one', () {
      // Two parties share the table; one has ordered. Freeing would discard
      // their order along with the empty one.
      expect(canFree([party(items: 0), party(items: 2)]), isFalse);
    });

    test('offered when both parties are empty', () {
      expect(canFree([party(items: 0), party(items: 0)]), isTrue);
    });
  });

  group('the seated party model', () {
    test('reads the item count from the backend', () {
      final parsed = SeatedParty.fromJson({
        'orderId': 'o1',
        'orderNo': 14,
        'seatLabel': null,
        'itemCount': 3,
      });
      expect(parsed.itemCount, 3);
      expect(parsed.isEmpty, isFalse);
    });

    test('treats a missing count as empty rather than crashing', () {
      // An older backend must not break the floor. Empty is the safe reading:
      // it offers a correction rather than hiding a stranded table.
      final parsed = SeatedParty.fromJson({'orderId': 'o1', 'orderNo': 14});
      expect(parsed.itemCount, 0);
      expect(parsed.isEmpty, isTrue);
    });
  });
}
