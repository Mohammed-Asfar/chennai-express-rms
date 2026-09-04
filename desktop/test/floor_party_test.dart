import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/features/floor/data/floor_models.dart';

DiningTable _table(List<SeatedParty> parties) => DiningTable(
      id: 't1',
      sectionId: 's1',
      name: 'T1',
      seats: 4,
      status: parties.isEmpty ? TableStatus.free : TableStatus.occupied,
      parties: parties,
    );

const _one = SeatedParty(orderId: 'o1', orderNo: 1, seatLabel: 'A', itemCount: 3);
const _two = SeatedParty(orderId: 'o2', orderNo: 2, seatLabel: 'B', itemCount: 1);

void main() {
  group('seating a second party', () {
    test('a free table starts an order without asking', () {
      // On an empty table "who is this for" has one possible answer, and asking
      // it during a rush is a tap nobody needs.
      expect(_table(const []).needsPartyChoice, isFalse);
    });

    test('a table holding one party still asks', () {
      // The regression. Opening the only party's order directly reads like a
      // helpful shortcut, but the option to seat another party lives in the
      // dialog it skips — so a second party could never be created, and the
      // first party's order reopened for ever instead.
      expect(_table(const [_one]).needsPartyChoice, isTrue);
    });

    test('a table holding two parties asks', () {
      expect(_table(const [_one, _two]).needsPartyChoice, isTrue);
    });
  });

  group('party labels', () {
    test('a labelled party shows its label', () {
      expect(_one.label, 'A');
    });

    test('an unlabelled party falls back to its order number', () {
      // Skipping the label dialog must still leave the two distinguishable on
      // the floor tile and the KOT.
      const unlabelled = SeatedParty(orderId: 'o3', orderNo: 7);
      expect(unlabelled.label, '#7');
    });
  });
}
