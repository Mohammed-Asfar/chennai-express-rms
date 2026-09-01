import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/menu_admin_models.dart';
import '../data/menu_admin_repository.dart';

/// Creates or renames a category.
class CategoryDialog extends ConsumerStatefulWidget {
  const CategoryDialog({super.key, this.category});

  /// Null when creating.
  final AdminCategory? category;

  static Future<bool?> show(BuildContext context, {AdminCategory? category}) {
    return showDialog<bool>(
      context: context,
      builder: (_) => CategoryDialog(category: category),
    );
  }

  @override
  ConsumerState<CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends ConsumerState<CategoryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.category != null;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.category?.name ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Rename category' : 'New category'),
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
                hintText: 'Starters, Biryani, Drinks',
                autofocus: true,
                enabled: !_saving,
                onSubmitted: (_) => _save(),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Give the category a name' : null,
              ),
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

    final repo = ref.read(menuAdminRepositoryProvider);
    final name = _nameController.text.trim();

    try {
      if (_isEditing) {
        await repo.renameCategory(widget.category!.id, name);
      } else {
        await repo.createCategory(name);
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
