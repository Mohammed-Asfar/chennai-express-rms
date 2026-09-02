import 'package:flutter/material.dart';
import '../../../core/theme/app_spacing.dart';

/// Asks why, before something on a bill is undone.
///
/// Voiding a bill and reversing a payment both leave a permanent record, and
/// the record is worth little without the reason. Required rather than
/// optional: "voided" with no explanation is what an auditor asks about, and
/// by then nobody remembers.
class ReasonDialog extends StatefulWidget {
  const ReasonDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.hint,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String? hint;

  /// Resolves to the reason, or null if it was dismissed.
  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    String? hint,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => ReasonDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        hint: hint,
      ),
    );
  }

  @override
  State<ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<ReasonDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 200,
              decoration: InputDecoration(
                labelText: 'Reason',
                hintText: widget.hint,
                isDense: true,
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }

  void _submit() {
    final reason = _controller.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Say why, so the record makes sense later.');
      return;
    }
    Navigator.of(context).pop(reason);
  }
}
