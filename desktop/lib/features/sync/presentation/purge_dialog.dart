import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../data/purge_repository.dart';

/// Clears old trading data from this PC and the cloud.
///
/// Deliberately slow. The operator picks how far back, sees exactly what will
/// go, is told whether a copy exists, and confirms against a count — because
/// this is the one screen in the product that destroys bills, and there is no
/// undo behind it.
class PurgeDialog extends ConsumerStatefulWidget {
  const PurgeDialog({super.key});

  @override
  ConsumerState<PurgeDialog> createState() => _PurgeDialogState();
}

/// How far back to keep. Anything older goes.
enum _KeepFor {
  oneMonth('Older than 1 month', 30),
  threeMonths('Older than 3 months', 90),
  sixMonths('Older than 6 months', 180),
  oneYear('Older than 1 year', 365);

  const _KeepFor(this.label, this.days);
  final String label;
  final int days;
}

class _PurgeDialogState extends ConsumerState<PurgeDialog> {
  _KeepFor _keep = _KeepFor.oneYear;
  PurgePreview? _preview;
  PurgeResult? _result;
  bool _busy = false;
  String? _error;

  /// Everything from the beginning up to the cutoff.
  ///
  /// The start is deliberately far back rather than a second date the operator
  /// has to choose: "clear anything older than a year" is the question people
  /// actually ask, and a second field is a second thing to get wrong.
  String get _from => '2000-01-01';

  String get _to {
    final cutoff = DateTime.now().subtract(Duration(days: _keep.days));
    return '${cutoff.year.toString().padLeft(4, '0')}-'
        '${cutoff.month.toString().padLeft(2, '0')}-'
        '${cutoff.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview =
          await ref.read(purgeRepositoryProvider).preview(from: _from, to: _to);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _busy = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _busy = false;
      });
    }
  }

  Future<void> _purge() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(purgeRepositoryProvider).purge(from: _from, to: _to);
      if (!mounted) return;
      setState(() {
        _result = result;
        _busy = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;

    if (result != null) return _done(context, theme, result);

    final preview = _preview;

    return AlertDialog(
      title: const Text('Clear old data'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Removes bills, orders and payments from this PC and the cloud. '
              'Your menu, tables, staff and settings are kept.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),

            // Plain tiles rather than RadioListTile: the Radio group API is
            // mid-deprecation, and `flutter analyze` fails the build on the
            // warning. A checked icon says the same thing.
            for (final option in _KeepFor.values)
              ListTile(
                onTap: _busy
                    ? null
                    : () {
                        setState(() => _keep = option);
                        _load();
                      },
                leading: Icon(
                  _keep == option
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: _keep == option
                      ? theme.colorScheme.primary
                      : AppColors.inkFaint,
                ),
                title: Text(option.label),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),

            const SizedBox(height: AppSpacing.sm),

            if (_busy && preview == null)
              const Center(child: CircularProgressIndicator())
            else if (preview != null) ...[
              _Summary(preview: preview, upTo: _to),
              if (!preview.isEmpty && !preview.exported) ...[
                const SizedBox(height: AppSpacing.md),
                _NotExportedWarning(missing: preview.missingExports),
              ],
            ],

            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Nothing to delete is not an error, but the button must not invite a
          // press that does nothing and reports success.
          onPressed: _busy || preview == null || preview.isEmpty ? null : _confirm,
          style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
          child: Text(
            preview == null || preview.isEmpty
                ? 'Nothing to clear'
                : 'Delete ${preview.bills} bills',
          ),
        ),
      ],
    );
  }

  /// The last gate.
  ///
  /// A second dialog rather than a checkbox: this destroys financial records,
  /// and the count is repeated so the operator confirms a number rather than
  /// clicking through a shape they have seen before.
  Future<void> _confirm() async {
    final preview = _preview;
    if (preview == null) return;

    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This cannot be undone'),
        content: Text(
          '${preview.bills} bills, ${preview.orders} orders and '
          '${preview.payments} payments dated on or before $_to will be '
          'permanently deleted from this PC and the cloud.'
          '${preview.exported ? '' : '\n\nThey have not been exported.'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );

    if (sure == true) await _purge();
  }

  Widget _done(BuildContext context, ThemeData theme, PurgeResult result) {
    return AlertDialog(
      title: const Text('Cleared'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${result.bills} bills, ${result.orders} orders and '
              '${result.payments} payments removed from this PC.',
              style: theme.textTheme.bodyMedium,
            ),
            if (result.cloudError != null) ...[
              const SizedBox(height: AppSpacing.md),
              // Not a failure: the local rows are gone. But the cloud still
              // holds them, and saying nothing would leave someone believing
              // otherwise.
              Text(
                'The cloud could not be reached, so its copy is still there. '
                'It will not come back to this PC — sync only sends upward.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
            ] else if (result.cloudRemoved != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${result.cloudRemoved} rows removed from the cloud.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.preview, required this.upTo});

  final PurgePreview preview;
  final String upTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (preview.isEmpty) {
      return Text(
        'Nothing on or before $upTo.',
        style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.inkMuted),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('On or before $upTo', style: theme.textTheme.labelMedium),
          const SizedBox(height: AppSpacing.sm),
          _row(theme, 'Bills', preview.bills),
          _row(theme, 'Orders', preview.orders),
          _row(theme, 'Order lines', preview.orderItems),
          _row(theme, 'Payments', preview.payments),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, String label, int count) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            Text('$count', style: theme.textTheme.bodySmall),
          ],
        ),
      );
}

/// Shown when no export covers the range being cleared.
class _NotExportedWarning extends StatelessWidget {
  const _NotExportedWarning({required this.missing});

  final List<String> missing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This has not been exported',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Once deleted these bills are gone from both this PC and the '
                  'cloud. Export them from Reports first if you may need them '
                  'for GST.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
