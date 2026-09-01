import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/table_admin_models.dart';
import '../data/table_admin_repository.dart';

/// Creates or renames a section — AC Hall, Terrace, Non-AC.
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

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.section != null;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.section?.name ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Rename section' : 'New section'),
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
        await repo.renameSection(widget.section!.id, name);
      } else {
        await repo.createSection(name);
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
