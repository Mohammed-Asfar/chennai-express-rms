import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';

/// A titled card. The reports screen is long, so each block is bounded and
/// labelled rather than running together as one wall of figures.
class ReportSection extends StatelessWidget {
  const ReportSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;

  /// The one-line explanation of what the numbers mean, where the distinction
  /// is not obvious from the title alone.
  final String? subtitle;

  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleLarge),
                    if (subtitle != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(subtitle!, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }
}

/// A labelled figure. Used for the headline stats and inside sections.
class ReportStat extends StatelessWidget {
  const ReportStat({
    super.key,
    required this.label,
    required this.value,
    this.note,
    this.emphasis = false,
  });

  final String label;
  final String value;

  /// Fine print under the figure, for the two totals an owner would otherwise
  /// read as contradicting each other.
  final String? note;

  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          value,
          style: theme.textTheme.headlineMedium?.copyWith(
            color: emphasis ? theme.colorScheme.error : null,
          ),
        ),
        if (note != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(note!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// A name, an optional count, and an amount — the shape almost every breakdown
/// in this screen takes.
class ReportRow extends StatelessWidget {
  const ReportRow({
    super.key,
    required this.label,
    required this.amount,
    this.detail,
    this.trailingDetail,
    this.emphasis = false,
  });

  final String label;
  final String amount;
  final String? detail;
  final String? trailingDetail;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amount,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: emphasis ? theme.colorScheme.error : null,
                ),
              ),
              if (trailingDetail != null) ...[
                const SizedBox(height: 2),
                Text(trailingDetail!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A hairline between rows in a breakdown.
class ReportDivider extends StatelessWidget {
  const ReportDivider({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: AppColors.border);
}

/// What a section shows when the range produced none of its kind of activity.
class ReportEmpty extends StatelessWidget {
  const ReportEmpty({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Text(message, style: theme.textTheme.bodySmall),
    );
  }
}
