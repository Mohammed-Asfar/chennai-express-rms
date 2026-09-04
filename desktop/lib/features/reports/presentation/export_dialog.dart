import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../data/export_repository.dart';
import 'report_range.dart';

/// Saves the trading record for a date range as CSV.
///
/// Three files rather than one: bills, the lines within them, and payments.
/// They answer different questions — what was sold, what was on each bill, and
/// what money came in on which day — and an accountant asked for "the sales"
/// wants the first without the other two getting in the way.
class ExportDialog extends ConsumerStatefulWidget {
  const ExportDialog({required this.range, super.key});

  final ReportDateRange range;

  @override
  ConsumerState<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<ExportDialog> {
  final _selected = {ExportKind.bills, ExportKind.billItems, ExportKind.payments};
  bool _saving = false;
  String? _error;
  List<File>? _saved;

  Future<void> _export() async {
    if (_selected.isEmpty) return;

    final repository = ref.read(exportRepositoryProvider);
    final directory = await repository.chooseDirectory();
    if (directory == null || !mounted) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final written = <File>[];
      for (final kind in ExportKind.values) {
        if (!_selected.contains(kind)) continue;
        written.add(
          await repository.save(
            kind: kind,
            from: ReportDateRange.wire(widget.range.from),
            to: ReportDateRange.wire(widget.range.to),
            directory: directory,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = written;
      });
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
        // Most likely a folder that cannot be written to — a read-only drive,
        // or a USB stick pulled out mid-save.
        _error = 'The files could not be written. $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saved = _saved;

    if (saved != null) {
      return AlertDialog(
        title: const Text('Saved'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${saved.length} file${saved.length == 1 ? '' : 's'} written to:',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              // The folder, selectable: someone will want to paste it into an
              // email or a file dialog.
              SelectableText(
                saved.first.parent.path,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.md),
              for (final file in saved)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Row(
                    children: [
                      const Icon(Icons.description_outlined, size: 16),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          file.uri.pathSegments.last,
                          style: theme.textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
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

    return AlertDialog(
      title: const Text('Export to CSV'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.range.spoken, style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.md),

            for (final kind in ExportKind.values)
              CheckboxListTile(
                value: _selected.contains(kind),
                onChanged: _saving
                    ? null
                    : (checked) => setState(() {
                          if (checked ?? false) {
                            _selected.add(kind);
                          } else {
                            _selected.remove(kind);
                          }
                        }),
                title: Text(kind.label),
                subtitle: Text(kind.description),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),

            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving || _selected.isEmpty ? null : _export,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined),
          label: Text(_saving ? 'Saving…' : 'Choose folder and save'),
        ),
      ],
    );
  }
}
