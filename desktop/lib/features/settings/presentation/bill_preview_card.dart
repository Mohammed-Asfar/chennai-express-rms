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

  /// How wide the paper box must be to hold every line without clipping.
  ///
  /// Normally the full column count, but an enlarged line is drawn in a bigger
  /// face and can be wider than that. Measuring the widest one is what stops a
  /// name being cut off on screen when it prints perfectly well — the failure
  /// the box width exists to catch.
  double _widestLine(BuildContext context, double columnWidth) {
    var widest = columnWidth * bill.width;

    for (final line in bill.lines) {
      if (line.heightScale <= 1 || line.text.isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(
          text: line.text,
          style: AppTextStyles.receipt.copyWith(
            fontSize: AppTextStyles.receipt.fontSize! * line.heightScale,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      if (painter.width > widest) widest = painter.width;
    }
    return widest;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            // Sized from measured text rather than a guessed multiplier: too
            // narrow and the longest line is clipped, which is how an amount
            // goes missing from a bill that prints correctly.
            constraints: BoxConstraints(
              maxWidth:
                  _widestLine(context, _characterWidth(context)) +
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
    // Enlarged by font size, which lays out properly.
    //
    // A transform would not: it paints outside the space it reserves, so a
    // taller line bleeds over the rules above and below it. The paper box is
    // measured against the largest line, so a bigger face cannot clip.
    final scale = line.heightScale;
    final style = AppTextStyles.receipt.copyWith(
      fontWeight: line.bold || line.large ? FontWeight.w700 : FontWeight.w400,
      fontSize: AppTextStyles.receipt.fontSize! * scale,
      // Enlarged lines otherwise inherit leading proportional to their size,
      // which opens a gap the printer does not leave.
      height: scale > 1 ? 1.1 : null,
      color: AppColors.ink,
    );

    return Align(
      alignment: switch (line.align) {
        'center' => Alignment.center,
        'right' => Alignment.centerRight,
        _ => Alignment.centerLeft,
      },
      child: Text(
        // A blank line still occupies its height on paper.
        line.text.isEmpty ? ' ' : line.text,
        style: style,
        softWrap: false,
      ),
    );
  }
}
