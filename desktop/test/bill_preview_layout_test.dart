import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_theme.dart';
import 'package:chennai_express_pos/features/settings/data/settings_repository.dart';
import 'package:chennai_express_pos/features/settings/presentation/bill_preview_card.dart';

PreviewLine line(String text, {int height = 1, String align = 'left'}) =>
    PreviewLine(
      text: text,
      large: height > 1,
      bold: false,
      align: align,
      heightScale: height,
    );

const _rule = '================================================'; // 48

/// A sample bill shaped like the real one: an enlarged name, then rules either
/// side of an enlarged total — the places where breakage was visible.
final _bill = BillPreview(
  paper: '80mm',
  width: 48,
  hasLogo: false,
  lines: [
    line('CHENNAI EXPRESS', height: 3, align: 'center'),
    line('NORTH INDIAN FOOD', align: 'center'),
    line(''),
    line(_rule),
    line('TOTAL                                     790.00', height: 2),
    line(_rule),
    line(''),
    line('Thank you, visit again!', align: 'center'),
  ],
);

Future<void> pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [billPreviewProvider.overrideWith((_) async => _bill)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
          body: SingleChildScrollView(child: BillPreviewCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The rendered rows, in order. Lines are painted rather than laid out as Text,
/// so they are found by their painter.
List<Rect> rows(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .where((paint) => paint.painter.runtimeType.toString() == '_LinePainter')
    .map((paint) => tester.getRect(find.byWidget(paint)))
    .toList();

void main() {
  group('the sample bill lays out', () {
    testWidgets('every line is drawn', (tester) async {
      await pump(tester);
      expect(rows(tester).length, _bill.lines.length);
    });

    testWidgets('an enlarged line is taller than a normal one', (tester) async {
      // The original bug: every line rendered at one size, so the preview
      // showed the name unchanged however large it was set to print.
      await pump(tester);
      final r = rows(tester);

      final name = r[0]; // 3x
      final tagline = r[1]; // 1x
      final total = r[4]; // 2x

      expect(name.height, greaterThan(tagline.height), reason: 'name is taller');
      expect(total.height, greaterThan(tagline.height), reason: 'total is taller');
      expect(name.height, greaterThan(total.height), reason: '3x beats 2x');
    });

    testWidgets('a taller line does not overlap its neighbours', (
      tester,
    ) async {
      // A transform paints outside the space it reserves, so the total bled
      // over the rules above and below it.
      await pump(tester);
      final r = rows(tester);

      for (var i = 1; i < r.length; i++) {
        expect(
          r[i].top,
          greaterThanOrEqualTo(r[i - 1].bottom - 0.5),
          reason: 'row $i starts before row ${i - 1} ends',
        );
      }
    });

    testWidgets('an enlarged line does not widen the paper', (tester) async {
      // Scaling the font grew glyphs both ways, so the 3x name was far wider
      // than the columns it occupies and stretched the box around it.
      await pump(tester);
      final r = rows(tester);

      final rule = r[3].width; // a full 48-column line
      for (final row in r) {
        expect(
          row.width,
          lessThanOrEqualTo(rule + 1),
          reason: 'a row is wider than the paper',
        );
      }
    });

    testWidgets('the paper is the column count wide, whatever prints on it', (
      tester,
    ) async {
      // Same assertion from the paper's side: the box must not grow to fit an
      // enlarged line, or every margin on the preview is wrong.
      await pump(tester);

      final withLarge = rows(tester)[3].width;

      // The same bill with nothing enlarged must be exactly as wide.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            billPreviewProvider.overrideWith(
              (_) async => BillPreview(
                paper: '80mm',
                width: 48,
                hasLogo: false,
                lines: [line('CHENNAI EXPRESS', align: 'center'), line(_rule)],
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(
              body: SingleChildScrollView(child: BillPreviewCard()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(rows(tester)[1].width, closeTo(withLarge, 1));
    });

    testWidgets('a blank line does not open a large gap', (tester) async {
      // Blank lines decode at 1x. One inheriting an enlarged size would push
      // the whole lower half of the bill down.
      await pump(tester);
      final r = rows(tester);

      expect(r[2].height, closeTo(r[1].height, 1), reason: 'blank line is normal height');
    });
  });
}
