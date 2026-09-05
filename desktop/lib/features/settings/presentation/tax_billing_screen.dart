import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/settings_repository.dart';
import 'bill_preview_card.dart';

/// How bills are taxed, numbered and closed off.
///
/// Every field here changes money or the audit trail, so nothing is applied
/// until Save — a half-typed tax rate must not reach the till.
class TaxBillingScreen extends ConsumerStatefulWidget {
  const TaxBillingScreen({super.key});

  @override
  ConsumerState<TaxBillingScreen> createState() => _TaxBillingScreenState();
}

class _TaxBillingScreenState extends ConsumerState<TaxBillingScreen> {
  final _formKey = GlobalKey<FormState>();
  final _taxRateController = TextEditingController();
  final _dayStartController = TextEditingController();
  final _prefixController = TextEditingController();
  final _formatController = TextEditingController();
  final _footerController = TextEditingController();

  String _taxMode = 'inclusive';
  bool _gstEnabled = true;
  String _resetPeriod = 'daily';
  int _pad = 4;
  bool _roundOff = true;

  bool _loaded = false;
  bool _saving = false;
  String? _error;

  String _preview = '';
  Timer? _previewDebounce;

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _taxRateController.dispose();
    _dayStartController.dispose();
    _prefixController.dispose();
    _formatController.dispose();
    _footerController.dispose();
    super.dispose();
  }

  void _fill(BranchSettings settings) {
    _taxRateController.text = Money.formatRate(settings.defaultTaxRate);
    _dayStartController.text = settings.businessDayStart;
    _prefixController.text = settings.billPrefix;
    _formatController.text = settings.billNumberFormat;
    _footerController.text = settings.billFooter;
    _taxMode = settings.taxMode;
    _gstEnabled = settings.gstEnabled;
    _resetPeriod = settings.billResetPeriod;
    _pad = settings.billNumberPad;
    _roundOff = settings.roundOffEnabled;
    _loaded = true;
    _refreshPreview();
  }

  /// Debounced: the preview is a round trip, and it should not fire on every
  /// keystroke while a format is being typed.
  void _refreshPreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 350), () async {
      final format = _formatController.text.trim();
      if (format.isEmpty) return;
      try {
        final preview = await ref
            .read(settingsRepositoryProvider)
            .previewBillNumber(
              format: format,
              prefix: _prefixController.text.trim(),
              pad: _pad,
            );
        if (mounted) setState(() => _preview = preview);
      } on ApiException {
        // An invalid format is reported on save, not while typing.
        if (mounted) setState(() => _preview = '');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(branchSettingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tax and billing'),
        actions: [
          // In the bar rather than a footer: a settings page is read top to
          // bottom and saved once, so the action belongs with the title, not
          // pinned over the content.
          if (_loaded)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ),
        ],
      ),
      body: settings.when(
        loading: () => const AppLoading(message: 'Loading settings'),
        error: (error, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: ErrorBanner(message: userMessage(error)),
            ),
          ),
        ),
        data: (loaded) {
          if (!_loaded) {
            // Populated once; rebuilding must not overwrite what is being typed.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_loaded) setState(() => _fill(loaded));
            });
            return const AppLoading();
          }
          return _form(context);
        },
      ),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (_error != null) ...[
            ErrorBanner(
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          _Card(
            title: 'GST',
            subtitle:
                'Applies to new items. Bills already issued keep the '
                'mode and rate they were calculated with.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Charge GST', style: theme.textTheme.bodyLarge),
                          const SizedBox(height: 2),
                          Text(
                            'Off for a restaurant below the registration '
                            'threshold. No tax is charged and no GST appears '
                            'anywhere.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Switch(
                      value: _gstEnabled,
                      onChanged: _saving
                          ? null
                          : (on) => setState(() => _gstEnabled = on),
                    ),
                  ],
                ),

                // The mode and rate mean nothing with GST off, and leaving
                // them on screen invites setting a rate that never applies.
                if (_gstEnabled) ...[
                  const SizedBox(height: AppSpacing.md),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'inclusive',
                        label: Text('Included in price'),
                      ),
                      ButtonSegment(
                        value: 'exclusive',
                        label: Text('Added on top'),
                      ),
                    ],
                    selected: {_taxMode},
                    onSelectionChanged: _saving
                        ? null
                        : (v) => setState(() => _taxMode = v.first),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _taxMode == 'inclusive'
                        ? 'A dish priced ₹100 is billed at ₹100, with the '
                              'GST worked out of it.'
                        : 'A dish priced ₹100 is billed at ₹105 at 5% GST.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppTextField(
                    controller: _taxRateController,
                    label: 'Default GST %',
                    hintText: '5',
                    enabled: !_saving,
                    validator: _validateRate,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Used for new dishes. Each dish can override it.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          _Card(
            title: 'Bill numbers',
            subtitle: 'How each bill is numbered and when the count restarts.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: AppTextField(
                        controller: _prefixController,
                        label: 'Prefix',
                        hintText: 'CE',
                        enabled: !_saving,
                        // setState so the "not in the format" hint
                        // appears and clears as it is typed.
                        onChanged: (_) {
                          setState(() {});
                          _refreshPreview();
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: AppTextField(
                        controller: _formatController,
                        label: 'Format',
                        enabled: !_saving,
                        onChanged: (_) {
                          setState(() {});
                          _refreshPreview();
                        },
                        validator: _validateFormat,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Tokens: {PREFIX} {NO} {YYYY} {YY} {MM} {DD} {FY}',
                  style: theme.textTheme.bodySmall,
                ),

                // The prefix only appears if the format places it. Two
                // fields that look related, where one silently does
                // nothing, is a trap worth calling out.
                if (_prefixController.text.trim().isNotEmpty &&
                    !_formatController.text.contains('{PREFIX}')) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          'The prefix will not appear: the format has no '
                          '{PREFIX} in it.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: _saving ? null : _addPrefixToken,
                        child: const Text('Add it'),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _pad,
                        decoration: const InputDecoration(
                          labelText: 'Number width',
                        ),
                        items: [
                          for (final width in [1, 3, 4, 5, 6])
                            DropdownMenuItem(
                              value: width,
                              child: Text(
                                width == 1
                                    ? 'No padding (42)'
                                    : '${'0' * (width - 2)}42'.padLeft(
                                        width,
                                        '0',
                                      ),
                              ),
                            ),
                        ],
                        onChanged: _saving
                            ? null
                            : (v) {
                                setState(() => _pad = v ?? 4);
                                _refreshPreview();
                              },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _resetPeriod,
                        decoration: const InputDecoration(
                          labelText: 'Restart counting',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'daily',
                            child: Text('Every day'),
                          ),
                          DropdownMenuItem(
                            value: 'monthly',
                            child: Text('Every month'),
                          ),
                          DropdownMenuItem(
                            value: 'yearly',
                            child: Text('Every year'),
                          ),
                          DropdownMenuItem(
                            value: 'financial_year',
                            child: Text('Financial year'),
                          ),
                          DropdownMenuItem(
                            value: 'never',
                            child: Text('Never'),
                          ),
                        ],
                        onChanged: _saving
                            ? null
                            : (v) =>
                                  setState(() => _resetPeriod = v ?? 'daily'),
                      ),
                    ),
                  ],
                ),

                if (_preview.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.accentTint,
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    child: Row(
                      children: [
                        Text(
                          'The 42nd bill would read',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(_preview, style: theme.textTheme.titleMedium),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          _Card(
            title: 'Trading day',
            subtitle:
                'A restaurant open past midnight keeps late sales on the '
                'previous day. Reports and bill numbering follow this.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppTextField(
                  controller: _dayStartController,
                  label: 'Day starts at',
                  hintText: '05:00',
                  enabled: !_saving,
                  validator: _validateTime,
                ),
                const SizedBox(height: AppSpacing.md),
                // A plain row rather than SwitchListTile: that widget makes the
                // whole strip tappable and paints its own band across the card,
                // which reads as a separate surface. Only the switch toggles.
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Round totals to the rupee',
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'A total of ₹180.50 is billed as ₹181.00.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Switch(
                      value: _roundOff,
                      onChanged: _saving
                          ? null
                          : (v) => setState(() => _roundOff = v),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          _Card(
            title: 'Bill footer',
            subtitle: 'Printed at the foot of every bill.',
            child: AppTextField(
              controller: _footerController,
              label: 'Message',
              hintText: 'Thank you, visit again',
              enabled: !_saving,
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          // Last, because it reflects everything above it — and only what has
          // been saved, so it is a check rather than a live echo of the form.
          const BillPreviewCard(),
        ],
      ),
    );
  }

  /// Puts {PREFIX} at the front of the format, where a prefix belongs.
  void _addPrefixToken() {
    setState(() {
      _formatController.text = '{PREFIX}${_formatController.text}';
    });
    _refreshPreview();
  }

  String? _validateRate(String? value) {
    final rate = double.tryParse((value ?? '').trim());
    if (rate == null) return 'Enter a percentage';
    if (rate < 0 || rate > 100) return 'Between 0 and 100';
    return null;
  }

  String? _validateFormat(String? value) {
    final format = (value ?? '').trim();
    if (format.isEmpty) return 'Enter a format';
    // Without {NO} every bill in the period prints the same string.
    if (!format.contains('{NO}')) return 'Must include {NO}';
    return null;
  }

  String? _validateTime(String? value) {
    final text = (value ?? '').trim();
    if (!RegExp(r'^\d{2}:\d{2}$').hasMatch(text)) {
      return 'Use HH:mm, like 05:00';
    }
    final parts = text.split(':').map(int.parse).toList();
    if (parts[0] > 23 || parts[1] > 59) return 'Not a real time';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await ref.read(settingsRepositoryProvider).updateSettings({
        'gstEnabled': _gstEnabled,
        'taxMode': _taxMode,
        // Percent to basis points at the boundary, as everywhere else.
        'defaultTaxRate': (double.parse(_taxRateController.text.trim()) * 100)
            .round(),
        'businessDayStart': _dayStartController.text.trim(),
        'billPrefix': _prefixController.text.trim(),
        'billResetPeriod': _resetPeriod,
        'billNumberFormat': _formatController.text.trim(),
        'billNumberPad': _pad,
        'billFooter': _footerController.text.trim(),
        'roundOffEnabled': _roundOff,
      });

      if (!mounted) return;
      ref.invalidate(branchSettingsProvider);
      // The sample bill reflects saved settings, so it has to be rebuilt.
      ref.invalidate(billPreviewProvider);
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Settings saved')));
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(subtitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: AppSpacing.md),
            child,
          ],
        ),
      ),
    );
  }
}
