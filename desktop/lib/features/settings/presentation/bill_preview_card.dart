import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_text_styles.dart';
import '../data/settings_repository.dart';

/// A sample bill, as it would come out of the printer.
///
/// Decoded from the same bytes the printer receives, so what is shown here
/// cannot drift from the paper. Lets someone check a footer, a bill number
/// format or a logo without spending a roll.
class BillPreviewCard extends ConsumerWidget {
  const BillPreviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final preview = ref.watch(billPreviewProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sample bill', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        'How a bill prints with the settings as saved.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Refresh',
                  onPressed: () => ref.invalidate(billPreviewProvider),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            preview.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Text(
                'Could not build a preview: $error',
                style: theme.textTheme.bodySmall,
              ),
              data: (bill) => _Paper(bill: bill),
            ),
          ],
        ),
      ),
    );
  }
}

class _Paper extends StatelessWidget {
  const _Paper({required this.bill});

  final BillPreview bill;

  /// Measures one character of the receipt face.
  ///
  /// Monospaced, so every character is this wide, and the paper box can be
  /// sized to hold exactly the column count the printer uses.
  double _characterWidth(BuildContext context) {
    final painter = TextPainter(
      text: const TextSpan(text: '0', style: AppTextStyles.receipt),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            // Exactly the paper's column count, measured from a real character
            // rather than a guessed multiplier. Enlarged lines are squeezed
            // back to their true width, so none of them widens this box —
            // a preview wider than the paper would misrepresent every margin
            // on the bill.
            constraints: BoxConstraints(
              maxWidth: _characterWidth(context) * bill.width +
                  AppSpacing.lg * 2,
            ),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              border: Border.all(color: AppColors.borderStrong),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (bill.logoImage != null) ...[
                  // The rasterised logo, not the uploaded image: this is what
                  // burns onto the paper, dithering and all, which is the one
                  // thing worth checking before printing a roll.
                  Center(
                    child: Image.memory(
                      base64Decode(bill.logoImage!.split(',').last),
                      // Nearest-neighbour keeps the one-bit dots crisp; smooth
                      // scaling would blur the dithering into fake greys and
                      // hide how it will really look.
                      filterQuality: FilterQuality.none,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ] else if (bill.hasLogo) ...[
                  // A logo is set but could not be drawn.
                  Container(
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceSunken,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                      border: Border.all(color: AppColors.border),
                    ),
                    alignment: Alignment.center,
                    child: Text('logo', style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],

                for (final line in bill.lines) _Line(line: line),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.sm),
        Text(
          '${bill.paper} paper · ${bill.width} characters wide',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line});

  final PreviewLine line;

  @override
  Widget build(BuildContext context) {
    final style = AppTextStyles.receipt.copyWith(
      fontWeight: line.bold || line.large ? FontWeight.w700 : FontWeight.w400,
      color: AppColors.ink,
    );

    // A blank line still occupies its height on paper.
    final painter = TextPainter(
      text: TextSpan(text: line.text.isEmpty ? ' ' : line.text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();

    // Painted rather than laid out, because the two axes have to move
    // independently: the printer's height command makes a glyph taller while
    // it still occupies one column. Every widget-level approach ties the axes
    // together — a bigger font widens the line and stretches the paper around
    // it, and constraining the width back truncates the text instead.
    return CustomPaint(
      // The row's own size: the text's true width, and the taller height. This
      // is what keeps the paper 48 columns wide however large a line prints.
      size: Size(painter.width, painter.height * line.heightScale),
      painter: _LinePainter(
        painter: painter,
        heightScale: line.heightScale.toDouble(),
        align: line.align,
      ),
    );
  }
}

/// Draws one receipt line, stretched vertically only.
class _LinePainter extends CustomPainter {
  const _LinePainter({
    required this.painter,
    required this.heightScale,
    required this.align,
  });

  final TextPainter painter;
  final double heightScale;
  final String align;

  @override
  void paint(Canvas canvas, Size size) {
    final x = switch (align) {
      'center' => (size.width - painter.width) / 2,
      'right' => size.width - painter.width,
      _ => 0.0,
    };

    if (heightScale == 1) {
      painter.paint(canvas, Offset(x, 0));
      return;
    }

    // Scaling the canvas on one axis stretches the glyphs without touching
    // their advance widths, which is exactly what the printer does.
    canvas.save();
    canvas.scale(1, heightScale);
    painter.paint(canvas, Offset(x, 0));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.painter != painter ||
      old.heightScale != heightScale ||
      old.align != align;
}
