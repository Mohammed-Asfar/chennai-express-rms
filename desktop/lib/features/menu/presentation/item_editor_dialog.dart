import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../../settings/data/settings_repository.dart';
import '../data/menu_admin_models.dart';
import '../data/menu_admin_repository.dart';

/// Creates or edits a dish.
///
/// Portions are edited inline rather than behind a second dialog: a dish with
/// Half and Full is the common case here, and making that a separate trip would
/// turn the ordinary path into the slow one.
class ItemEditorDialog extends ConsumerStatefulWidget {
  const ItemEditorDialog({
    super.key,
    required this.categories,
    this.item,
    this.initialCategoryId,
  });

  final List<AdminCategory> categories;

  /// Null when creating.
  final AdminMenuItem? item;
  final String? initialCategoryId;

  static Future<bool?> show(
    BuildContext context, {
    required List<AdminCategory> categories,
    AdminMenuItem? item,
    String? initialCategoryId,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => ItemEditorDialog(
        categories: categories,
        item: item,
        initialCategoryId: initialCategoryId,
      ),
    );
  }

  @override
  ConsumerState<ItemEditorDialog> createState() => _ItemEditorDialogState();
}

class _ItemEditorDialogState extends ConsumerState<ItemEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _taxController = TextEditingController();

  late String _categoryId;
  final List<_PortionRow> _portions = [];

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;

    _categoryId = item?.categoryId ??
        widget.initialCategoryId ??
        (widget.categories.isNotEmpty ? widget.categories.first.id : '');

    if (item != null) {
      _nameController.text = item.name;
      _descriptionController.text = item.description ?? '';
      _taxController.text = Money.formatRate(item.taxRate);
      for (final v in item.variants) {
        _portions.add(_PortionRow.fromVariant(v));
      }
    } else {
      // A new dish starts with one unnamed portion, because the backend
      // guarantees every item has at least one.
      _portions.add(_PortionRow(name: 'Standard'));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _taxController.dispose();
    for (final p in _portions) {
      p.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Defaults to on while the settings load, so the field does not flicker
    // away and back on a screen someone is already typing into.
    final gstEnabled =
        ref.watch(branchSettingsProvider).valueOrNull?.gstEnabled ?? true;

    return AlertDialog(
      title: Text(_isEditing ? 'Edit ${widget.item!.name}' : 'New dish'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
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
                  label: 'Dish name',
                  autofocus: true,
                  enabled: !_saving,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Give the dish a name' : null,
                ),
                const SizedBox(height: AppSpacing.md),

                DropdownButtonFormField<String>(
                  initialValue: _categoryId.isEmpty ? null : _categoryId,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final c in widget.categories)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _categoryId = value ?? _categoryId),
                  validator: (v) => (v == null || v.isEmpty) ? 'Pick a category' : null,
                ),
                const SizedBox(height: AppSpacing.md),

                AppTextField(
                  controller: _descriptionController,
                  label: 'Description (optional)',
                  enabled: !_saving,
                ),
                const SizedBox(height: AppSpacing.md),

                // Hidden entirely with GST switched off in settings: a rate
                // set here would never be charged, and offering the field
                // invites someone to believe otherwise.
                if (gstEnabled) ...[
                AppTextField(
                  controller: _taxController,
                  label: 'GST %',
                  // Blank means "the branch default" when creating, and "leave
                  // it alone" when editing — saying so avoids someone clearing
                  // the field expecting one and getting the other.
                  hintText: _isEditing
                      ? 'Blank keeps the current rate'
                      : 'Blank uses the branch default',
                  enabled: !_saving,
                  validator: _validateTax,
                  onChanged: (_) => setState(() {}),
                ),

                // Zero is legal — some items genuinely carry no GST — but it is
                // also what a mistyped field looks like, and a bill printed with
                // no tax is only noticed at reconciliation.
                if (_taxRateBasisPoints() == 0) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          'No GST will be charged on this item.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
                ],

                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Text('PORTIONS', style: theme.textTheme.labelSmall),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(child: Divider(color: theme.colorScheme.outline)),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),

                for (var i = 0; i < _portions.length; i++) _portionRow(i),

                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving ? null : _addPortion,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add a portion'),
                  ),
                ),
              ],
            ),
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
              : Text(_isEditing ? 'Save changes' : 'Create dish'),
        ),
      ],
    );
  }

  Widget _portionRow(int index) {
    final portion = _portions[index];

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: AppTextField(
              controller: portion.nameController,
              label: 'Portion',
              hintText: 'Half, Full',
              enabled: !_saving,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name it' : null,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            flex: 2,
            child: AppTextField(
              controller: portion.priceController,
              label: 'Price ₹',
              enabled: !_saving,
              validator: _validatePrice,
            ),
          ),
          // Sold out for tonight, without deleting the portion or touching its
          // price — it goes back on tomorrow with one tap.
          Tooltip(
            message: portion.isAvailable ? 'On the menu' : 'Sold out',
            child: Switch(
              value: portion.isAvailable,
              onChanged: _saving
                  ? null
                  : (on) => setState(() => portion.isAvailable = on),
            ),
          ),

          // Removing the last portion would leave an item nobody can order, and
          // the backend rejects it anyway.
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: _portions.length > 1 ? 'Remove portion' : 'An item needs one portion',
            onPressed: (_saving || _portions.length <= 1) ? null : () => _removePortion(index),
          ),
        ],
      ),
    );
  }

  String? _validatePrice(String? value) {
    if (value == null || value.trim().isEmpty) return 'Price';
    final paise = Money.parse(value);
    if (paise == null) return 'Not a number';
    if (paise < 0) return 'Cannot be negative';
    return null;
  }

  String? _validateTax(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final rate = double.tryParse(value.trim());
    if (rate == null) return 'Not a number';
    if (rate < 0 || rate > 100) return 'Between 0 and 100';
    return null;
  }

  void _addPortion() {
    setState(() {
      // A second portion means the first is no longer "Standard" — but renaming
      // it automatically would fight anyone who meant it, so it is left alone.
      _portions.add(_PortionRow(name: ''));
    });
  }

  void _removePortion(int index) {
    setState(() {
      _portions.removeAt(index).dispose();
    });
  }

  /// Percentage text to basis points. `2.5` -> `250`.
  int? _taxRateBasisPoints() {
    final text = _taxController.text.trim();
    if (text.isEmpty) return null;
    final rate = double.tryParse(text);
    if (rate == null) return null;
    return (rate * 100).round();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final names = _portions.map((p) => p.nameController.text.trim().toLowerCase()).toList();
    if (names.toSet().length != names.length) {
      setState(() => _error = 'Two portions share a name. Give each one its own.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final repo = ref.read(menuAdminRepositoryProvider);

    try {
      if (_isEditing) {
        await _saveExisting(repo);
      } else {
        await repo.createItem(
          categoryId: _categoryId,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim(),
          taxRate: _taxRateBasisPoints(),
          variants: [
            for (final p in _portions)
              VariantDraft(
                name: p.nameController.text.trim(),
                price: Money.parse(p.priceController.text) ?? 0,
                isAvailable: p.isAvailable,
              ),
          ],
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = userMessage(error);
      });
    }
  }

  /// An edit is several calls: the item itself, then each portion. They are not
  /// atomic, so the dialog stays open on failure with the error shown rather
  /// than reporting a save that only partly happened.
  Future<void> _saveExisting(MenuAdminRepository repo) async {
    final item = widget.item!;

    await repo.updateItem(
      item.id,
      categoryId: _categoryId,
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      taxRate: _taxRateBasisPoints(),
    );

    final keptIds = <String>{};

    for (final portion in _portions) {
      final name = portion.nameController.text.trim();
      final price = Money.parse(portion.priceController.text) ?? 0;

      if (portion.id == null) {
        await repo.addVariant(item.id, name, price);
        continue;
      }

      keptIds.add(portion.id!);
      final original = item.variants.firstWhere((v) => v.id == portion.id);
      if (original.name != name ||
          original.price != price ||
          original.isAvailable != portion.isAvailable) {
        await repo.updateVariant(
          item.id,
          portion.id!,
          name: name,
          price: price,
          isAvailable: portion.isAvailable,
        );
      }
    }

    // Anything the user removed from the list.
    for (final existing in item.variants) {
      if (!keptIds.contains(existing.id)) {
        await repo.deleteVariant(item.id, existing.id);
      }
    }
  }
}

/// One editable portion row. Holds its own controllers so the list can grow and
/// shrink without losing what is typed in the other rows.
class _PortionRow {
  _PortionRow({this.id, String name = '', int? price, this.isAvailable = true})
      : nameController = TextEditingController(text: name),
        priceController = TextEditingController(
          text: price == null ? '' : Money.format(price),
        );

  factory _PortionRow.fromVariant(AdminVariant v) => _PortionRow(
        id: v.id,
        name: v.name,
        price: v.price,
        isAvailable: v.isAvailable,
      );

  final String? id;
  final TextEditingController nameController;
  final TextEditingController priceController;

  /// Whether this portion can be ordered. A kitchen runs out of the large size
  /// while the small one is still on — the order screen greys it out and
  /// refuses it, rather than the whole dish disappearing.
  bool isAvailable;

  void dispose() {
    nameController.dispose();
    priceController.dispose();
  }
}
