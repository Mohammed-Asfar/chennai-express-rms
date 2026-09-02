import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../billing/data/bill_models.dart' show PaymentModeLabel;
import '../data/report_models.dart';
import 'report_section.dart';

/// Charts on this screen never carry meaning by colour alone.
///
/// Every slice, bar and point is printed as a figure beside its swatch. This is
/// financial data read by whoever is on shift, and a hue someone cannot
/// separate must never be the only thing distinguishing two numbers.

/// Where money came from, as a donut with the total in the middle.
class PaymentModeDonut extends StatelessWidget {
  const PaymentModeDonut({
    super.key,
    required this.byMode,
    required this.total,
  });

  final List<CollectionByMode> byMode;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (byMode.isEmpty || total == 0) {
      return const ReportEmpty(message: 'Nothing was taken in this range.');
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          height: 180,
          width: 180,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 56,
                  startDegreeOffset: -90,
                  sections: [
                    for (var i = 0; i < byMode.length; i++)
                      PieChartSectionData(
                        value: byMode[i].amount.toDouble(),
                        color: AppColors
                            .chartSeries[i % AppColors.chartSeries.length],
                        radius: 26,
                        showTitle: false,
                      ),
                  ],
                ),
              ),

              // The total sits in the hole rather than in a caption, so the
              // parts and the whole are read in one glance.
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('TAKEN', style: theme.textTheme.labelSmall),
                  const SizedBox(height: 2),
                  Text(
                    Money.formatWithSymbol(total),
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(width: AppSpacing.lg),

        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < byMode.length; i++)
                _LegendRow(
                  colour:
                      AppColors.chartSeries[i % AppColors.chartSeries.length],
                  label: byMode[i].mode.label,
                  detail:
                      '${byMode[i].count} ${byMode[i].count == 1 ? 'payment' : 'payments'}',
                  amount: Money.formatWithSymbol(byMode[i].amount),
                  share: total == 0 ? 0 : byMode[i].amount / total,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A swatch, a name, and the figure it stands for.
class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.colour,
    required this.label,
    required this.detail,
    required this.amount,
    required this.share,
  });

  final Color colour;
  final String label;
  final String detail;
  final String amount;
  final double share;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: colour,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(amount, style: theme.textTheme.titleMedium),
              const SizedBox(height: 2),
              // The percentage is spelled out; the slice size only echoes it.
              Text(
                '${(share * 100).round()}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The headline dishes, as proportional bars against the best seller.
///
/// Drawn as plain containers rather than a chart widget: the bar is a share of
/// the row's own width, which keeps the name, quantity and revenue on the same
/// line as the bar instead of on a detached axis.
class TopDishesChart extends StatelessWidget {
  const TopDishesChart({super.key, required this.items});

  final List<ItemSales> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const ReportEmpty(message: 'Nothing was sold in this range.');
    }

    // Scaled against the top seller, so the leader always fills the row and the
    // rest read as a share of it.
    final peak = items.first.revenue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++)
          _DishBar(
            item: items[i],
            colour: AppColors.chartSeries[i % AppColors.chartSeries.length],
            share: peak == 0 ? 0 : items[i].revenue / peak,
            rank: i + 1,
          ),
      ],
    );
  }
}

class _DishBar extends StatelessWidget {
  const _DishBar({
    required this.item,
    required this.colour,
    required this.share,
    required this.rank,
  });

  final ItemSales item;
  final Color colour;
  final double share;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                child: Text('$rank', style: theme.textTheme.bodySmall),
              ),
              Expanded(
                child: Text(
                  item.displayName,
                  style: theme.textTheme.bodyLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('${item.qty} sold', style: theme.textTheme.bodySmall),
              const SizedBox(width: AppSpacing.md),
              Text(
                Money.formatWithSymbol(item.revenue),
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.xs),

          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              child: LinearProgressIndicator(
                value: share.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: AppColors.chartTrack,
                valueColor: AlwaysStoppedAnimation<Color>(colour),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sales across the days in the range.
///
/// A single day has no trend to draw, so the caller shows the figure instead.
class SalesTrendChart extends StatelessWidget {
  const SalesTrendChart({super.key, required this.days});

  final List<DailySales> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (days.length < 2) {
      return const ReportEmpty(
        message: 'A trend needs more than one day. Widen the range to see one.',
      );
    }

    final peak = days.map((d) => d.totalSales).reduce((a, b) => a > b ? a : b);

    // A flat zero series would collapse the axis onto itself.
    final maxY = peak == 0 ? 1.0 : peak.toDouble() * 1.15;

    // Labelling every day would overlap on a 30-day range.
    final labelEvery = (days.length / 6).ceil();

    return SizedBox(
      height: 200,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: maxY / 4,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: AppColors.border, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 56,
                interval: maxY / 4,
                getTitlesWidget: (value, meta) => Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.xs),
                  child: Text(
                    // Whole rupees on the axis; the tooltip carries the paise.
                    '₹${(value / 100).round()}',
                    style: theme.textTheme.labelSmall,
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final index = value.round();
                  if (index < 0 || index >= days.length) {
                    return const SizedBox.shrink();
                  }
                  if (index % labelEvery != 0 && index != days.length - 1) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xs),
                    child: Text(
                      days[index].dayLabel,
                      style: theme.textTheme.labelSmall,
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => AppColors.shell,
              getTooltipItems: (spots) => spots.map((spot) {
                final day = days[spot.x.round()];
                return LineTooltipItem(
                  '${day.businessDate}\n'
                  '${Money.formatWithSymbol(day.totalSales)}  ·  '
                  '${day.billCount} ${day.billCount == 1 ? 'bill' : 'bills'}',
                  theme.textTheme.bodySmall!.copyWith(
                    color: AppColors.onShell,
                  ),
                );
              }).toList(),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              isCurved: false,
              color: AppColors.chart1,
              barWidth: 2,
              // Dots would crowd a 30-day range; the tooltip gives the values.
              dotData: FlDotData(show: days.length <= 10),
              belowBarData: BarAreaData(
                show: true,
                color: AppColors.chartAreaFill,
              ),
              spots: [
                for (var i = 0; i < days.length; i++)
                  FlSpot(i.toDouble(), days[i].totalSales.toDouble()),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
