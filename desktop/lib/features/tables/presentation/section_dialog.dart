import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/table_admin_models.dart';
import '../data/table_admin_repository.dart';

/// Creates or renames a section — AC Hall, Terrace, Non-AC.
///
/// Also where the AC charge is set: a flat amount added to every item ordered
/// at a table here. It belongs on the section rather than in settings because a
/// branch may charge for an AC room and not a terrace, and one branch-wide
/// figure could not say so.
class SectionDialog extends ConsumerStatefulWidget {
  const SectionDialog({super.key, this.section});

  final AdminSection? section;

  static Future<bool?> show(BuildContext context, {AdminSection? section}) {
    return showDialog<bool>(
      context: context,
      builder: (_) => SectionDialog(section: section),
    );
  }

  @override
  ConsumerState<SectionDialog> createState() => _SectionDialogState();
}

class _SectionDialogState extends ConsumerState<SectionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _surchargeController = TextEditingController();

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.section != null;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.section?.name ?? '';

    // Left empty rather than showing 0.00, so a section that charges nothing
    // reads as charging nothing rather than as a figure someone set.
    final existing = widget.section?.surcharge ?? 0;
    _surchargeController.text = existing > 0 ? Money.format(existing) : '';
    _surchargeController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _surchargeController.dispose();
    super.dispose();
  }

  /// What the field currently reads, in paise. Empty means nothing extra.
  int get _surcharge {
    final text = _surchargeController.text.trim();
    if (text.isEmpty) return 0;
    return Money.parse(text) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Not "Rename": this dialog also sets what the room charges, and a title
      // naming only one of the two hides the other.
      title: Text(_isEditing ? 'Edit section' : 'New section'),
      content: SizedBox(
        width: 340,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                ErrorBanner(message: _error!),
                const SizedBox(height: AppSpacing.md),
              ],
              AppTextField(
                controller: _nameController,
                label: 'Name',
                hintText: 'AC Hall, Terrace, Non-AC',
                autofocus: true,
                enabled: !_saving,
                onSubmitted: (_) => _save(),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Give the section a name' : null,
              ),

              const SizedBox(height: AppSpacing.md),

              AppTextField(
                controller: _surchargeController,
                label: 'Extra per item',
                hintText: 'Leave empty for no extra charge',
                enabled: !_saving,
                onSubmitted: (_) => _save(),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                validator: (v) {
                  final text = v?.trim() ?? '';
                  if (text.isEmpty) return null;
                  final paise = Money.parse(text);
                  if (paise == null) return 'Enter an amount like 10';
                  // A negative would be a discount that skips the discount
                  // rules; the cap catches a stray extra zero here rather than
                  // on a customer's bill.
                  if (paise < 0) return 'An extra charge cannot be negative';
                  if (paise > 100000) return 'That is more than ₹1000 an item';
                  return null;
                },
              ),

              const SizedBox(height: AppSpacing.sm),
              _Explanation(surcharge: _surcharge, isEditing: _isEditing),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEditing ? 'Save' : 'Create'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final repo = ref.read(tableAdminRepositoryProvider);
    final name = _nameController.text.trim();

    try {
      if (_isEditing) {
        await repo.renameSection(
          widget.section!.id,
          name,
          surcharge: _surcharge,
        );
      } else {
        await repo.createSection(name, surcharge: _surcharge);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }
}

/// What the amount in the field will actually do.
///
/// "₹10 per item" is abstract until it is a real dish at a real price, and the
/// figure a restaurant cares about is the one the customer will read. Worked
/// through on a ₹75 plate, which is an ordinary main course here.
///
/// It also carries the one caveat that matters: the charge lands on items added
/// from now on, not on food a party has already ordered.
class _Explanation extends StatelessWidget {
  const _Explanation({required this.surcharge, required this.isEditing});

  final int surcharge;
  final bool isEditing;

  /// An ordinary main course, as something to work the example through on.
  static const _examplePrice = 7500;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final message = surcharge <= 0
        ? 'Items here cost what the menu says.'
        : 'Every item ordered here costs '
              '${Money.formatWithSymbol(surcharge)} more. '
              'A ${Money.formatWithSymbol(_examplePrice)} dish is billed at '
              '${Money.formatWithSymbol(_examplePrice + surcharge)}.';

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
          Text(message, style: theme.textTheme.bodySmall),

          // Only when editing: on a new section there is no order to protect,
          // so saying this would be answering a question nobody asked.
          if (isEditing) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Orders already placed keep the prices they were taken at.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.inkMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
