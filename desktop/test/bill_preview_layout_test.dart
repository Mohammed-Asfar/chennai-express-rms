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

/// A sample bill shaped like the real one: an enlarged name, then rules either
/// side of an enlarged total — the places overlapping was visible.
final _bill = BillPreview(
  paper: '80mm',
  width: 48,
  hasLogo: false,
  lines: [
    line('CHENNAI EXPRESS', height: 3, align: 'center'),
    line('NORTH INDIAN FOOD', align: 'center'),
    line(''),
    line('=' * 48),
    line('TOTAL                                     790.00', height: 2),
    line('=' * 48),
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

void main() {
  group('the sample bill lays out', () {
    testWidgets('an enlarged line is drawn larger than a normal one', (
      tester,
    ) async {
      // The bug this guards: every line rendered at one size, so the preview
      // showed the name unchanged however large it was set to print.
      await pump(tester);

      final name = tester.widget<Text>(find.text('CHENNAI EXPRESS'));
      final tagline = tester.widget<Text>(find.text('NORTH INDIAN FOOD'));

      expect(name.style!.fontSize, greaterThan(tagline.style!.fontSize!));
    });

    testWidgets('a taller line does not overlap the one below it', (
      tester,
    ) async {
      // The second bug: a transform paints outside the space it reserves, so
      // the total bled over the rules above and below it.
      await pump(tester);

      final rules = find.text('=' * 48);
      final above = tester.getRect(rules.first);
      final total = tester.getRect(find.textContaining('TOTAL'));
      final below = tester.getRect(rules.last);

      expect(
        total.top,
        greaterThanOrEqualTo(above.bottom - 0.5),
        reason: 'the total starts below the rule above it',
      );
      expect(
        total.bottom,
        lessThanOrEqualTo(below.top + 0.5),
        reason: 'and ends above the rule below it',
      );
    });

    testWidgets('every line stays inside the paper', (tester) async {
      // The box is measured against the largest line, so an enlarged name must
      // not be clipped — that is the failure the width exists to catch.
      await pump(tester);

      final paper = tester.getRect(
        find.ancestor(of: find.text('CHENNAI EXPRESS'), matching: find.byType(Container)).first,
      );

      for (final text in ['CHENNAI EXPRESS', 'NORTH INDIAN FOOD']) {
        final rect = tester.getRect(find.text(text));
        expect(rect.left, greaterThanOrEqualTo(paper.left - 0.5), reason: '$text overflows left');
        expect(rect.right, lessThanOrEqualTo(paper.right + 0.5), reason: '$text overflows right');
      }
    });

    testWidgets('an enlarged line does not widen the paper', (tester) async {
      // The paper stayed 48 columns while the name was drawn in a 3x face, so
      // the box grew to fit it and the whole receipt stretched — the total's
      // amount ended up far out to the right of everything else.
      await pump(tester);

      final rule = tester.getRect(find.text('=' * 48).first);
      final name = tester.getRect(find.text('CHENNAI EXPRESS'));

      // 48 columns of rule is the paper's full width. The 15-character name
      // must occupy less than that, as it does on paper.
      expect(
        name.width,
        lessThan(rule.width),
        reason: 'name ${name.width} vs paper ${rule.width}',
      );
    });

    testWidgets('the amount stays in the column the rules mark out', (
      tester,
    ) async {
      // The total is right-aligned within 48 columns. If the box is wider than
      // the paper, the amount drifts past the rules and the preview stops
      // showing where it really prints.
      await pump(tester);

      final rule = tester.getRect(find.text('=' * 48).first);
      final total = tester.getRect(find.textContaining('TOTAL'));

      expect(
        total.right,
        lessThanOrEqualTo(rule.right + 1),
        reason: 'total ends at ${total.right}, rule at ${rule.right}',
      );
    });

    testWidgets('a blank line does not open a large gap', (tester) async {
      // Blank lines decode at 1x. If one ever inherited the enlarged size it
      // would push the whole lower half of the bill down.
      await pump(tester);

      final tagline = tester.getRect(find.text('NORTH INDIAN FOOD'));
      final rule = tester.getRect(find.text('=' * 48).first);
      final gap = rule.top - tagline.bottom;

      // One blank line between them, so at most a couple of line heights.
      expect(gap, lessThan(tagline.height * 3), reason: 'gap was $gap');
    });
  });
}
