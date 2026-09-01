import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/table_admin_models.dart';
import '../data/table_admin_repository.dart';

/// Creates or edits a table.
///
/// Creating supports a run — `A1` with a count of 6 makes A1 through A6 — because
/// setting up a restaurant means entering twenty tables at once, and doing that
/// one dialog at a time is the kind of chore that makes people give up halfway.
class TableDialog extends ConsumerStatefulWidget {
  const TableDialog({
    super.key,
    required this.sections,
    this.table,
    this.initialSectionId,
  });

  final List<AdminSection> sections;
  final AdminTable? table;
  final String? initialSectionId;

  static Future<bool?> show(
    BuildContext context, {
    required List<AdminSection> sections,
    AdminTable? table,
    String? initialSectionId,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => TableDialog(
        sections: sections,
        table: table,
        initialSectionId: initialSectionId,
      ),
    );
  }

  @override
  ConsumerState<TableDialog> createState() => _TableDialogState();
}

class _TableDialogState extends ConsumerState<TableDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _seatsController = TextEditingController(text: '4');
  final _countController = TextEditingController(text: '1');

  late String _sectionId;
  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.table != null;

  @override
  void initState() {
    super.initState();
    final table = widget.table;

    _sectionId = table?.sectionId ??
        widget.initialSectionId ??
        (widget.sections.isNotEmpty ? widget.sections.first.id : '');

    if (table != null) {
      _nameController.text = table.name;
      _seatsController.text = '${table.seats}';
    } else {
      // The preview is only useful if it tracks what is being typed.
      _nameController.addListener(_refreshPreview);
      _countController.addListener(_refreshPreview);
    }
  }

  void _refreshPreview() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nameController.dispose();
    _seatsController.dispose();
    _countController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(_isEditing ? 'Edit ${widget.table!.name}' : 'Add tables'),
      content: SizedBox(
        width: 380,
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

              DropdownButtonFormField<String>(
                initialValue: _sectionId.isEmpty ? null : _sectionId,
                decoration: const InputDecoration(labelText: 'Section'),
                items: [
                  for (final s in widget.sections)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _sectionId = value ?? _sectionId),
                validator: (v) => (v == null || v.isEmpty) ? 'Pick a section' : null,
              ),
              const SizedBox(height: AppSpacing.md),

              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: AppTextField(
                      controller: _nameController,
                      label: _isEditing ? 'Name' : 'First name',
                      hintText: 'A1, T1',
                      autofocus: true,
                      enabled: !_saving,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Name it' : null,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AppTextField(
                      controller: _seatsController,
                      label: 'Seats',
                      enabled: !_saving,
                      validator: _validateSeats,
                    ),
                  ),
                ],
              ),

              if (!_isEditing) ...[
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _countController,
                  label: 'How many',
                  enabled: !_saving,
                  validator: _validateCount,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(_previewText(), style: theme.textTheme.bodySmall),
              ],
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
              : Text(_isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }

  /// Shows exactly what will be created, so a run of twenty is not a surprise.
  String _previewText() {
    final count = int.tryParse(_countController.text.trim()) ?? 1;
    final base = _nameController.text.trim();
    if (base.isEmpty) return 'Enter a name to see what will be created.';
    if (count <= 1) return 'Creates $base.';

    final names = _namesToCreate(base, count);
    if (names.length <= 3) return 'Creates ${names.join(', ')}.';
    return 'Creates ${names.first}, ${names[1]} … ${names.last} '
        '(${names.length} tables).';
  }

  /// Splits a trailing number off the name and counts up from it. `A1` with a
  /// count of 3 gives A1, A2, A3. A name with no trailing number gets suffixes
  /// starting at 1.
  List<String> _namesToCreate(String base, int count) {
    // One table keeps exactly the name typed. Numbering a single "Corner" into
    // "Corner1" would rename it behind the user's back.
    if (count <= 1) return [base];

    final match = RegExp(r'^(.*?)(\d+)$').firstMatch(base);
    final prefix = match?.group(1) ?? base;
    final start = match == null ? 1 : int.parse(match.group(2)!);
    // Preserve zero padding: T01 continues T02, not T2.
    final width = match?.group(2)?.length ?? 0;

    return [
      for (var i = 0; i < count; i++)
        '$prefix${(start + i).toString().padLeft(width, '0')}',
    ];
  }

  String? _validateSeats(String? value) {
    final seats = int.tryParse((value ?? '').trim());
    if (seats == null) return 'Number';
    if (seats < 1 || seats > 64) return '1 to 64';
    return null;
  }

  String? _validateCount(String? value) {
    final count = int.tryParse((value ?? '').trim());
    if (count == null) return 'Enter a number';
    if (count < 1 || count > 50) return 'Between 1 and 50';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final repo = ref.read(tableAdminRepositoryProvider);
    final name = _nameController.text.trim();
    final seats = int.parse(_seatsController.text.trim());

    try {
      if (_isEditing) {
        await repo.updateTable(
          widget.table!.id,
          sectionId: _sectionId,
          name: name,
          seats: seats,
        );
      } else {
        final count = int.parse(_countController.text.trim());
        final names = _namesToCreate(name, count);

        // Created one at a time. A name clash partway through leaves the
        // earlier tables in place, which is why the error names the table it
        // stopped on rather than claiming nothing happened.
        for (final tableName in names) {
          await repo.createTable(
            sectionId: _sectionId,
            name: tableName,
            seats: seats,
          );
        }
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
