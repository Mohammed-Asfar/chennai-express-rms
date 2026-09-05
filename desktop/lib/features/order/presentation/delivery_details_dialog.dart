import 'package:flutter/material.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_text_field.dart';

/// Who a delivery is for and where it is going.
///
/// Asked before the order opens rather than after, because at the end of an
/// order the food is already being packed and whoever took the call has moved
/// on. A phone number is the one detail a delivery cannot do without — a rider
/// who cannot find the door rings it — so the field is focused and Enter moves
/// straight on.
///
/// Nothing is mandatory. A regular whose address the shop knows, or an order
/// already logged in a notebook, must not be blocked at the till; the point is
/// to make recording the details the easy path, not the enforced one.
class DeliveryDetailsDialog extends StatefulWidget {
  const DeliveryDetailsDialog({super.key});

  /// Null when dismissed. Otherwise the details, either of which may be blank.
  static Future<({String name, String phone})?> show(BuildContext context) {
    return showDialog<({String name, String phone})>(
      context: context,
      builder: (_) => const DeliveryDetailsDialog(),
    );
  }

  @override
  State<DeliveryDetailsDialog> createState() => _DeliveryDetailsDialogState();
}

class _DeliveryDetailsDialogState extends State<DeliveryDetailsDialog> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _phoneFocus = FocusNode();
  final _nameFocus = FocusNode();

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    _phoneFocus.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop((
      name: _name.text.trim(),
      phone: _phone.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delivery details'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextField(
              controller: _phone,
              focusNode: _phoneFocus,
              label: 'Phone',
              autofocus: true,
              textInputAction: TextInputAction.next,
              // Enter moves on rather than submitting: the address is the part
              // the rider actually needs, so stopping at the phone number would
              // be the wrong shortcut.
              onSubmitted: (_) => _nameFocus.requestFocus(),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _name,
              focusNode: _nameFocus,
              label: 'Name and address',
              hintText: 'Ravi, 3rd cross, ECR Road',
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
        // One button, and it works with the fields empty. A separate "Skip"
        // would do exactly what this does, and two buttons for one outcome is
        // a decision staff have to make at the counter for no reason.
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Start order'),
        ),
      ],
    );
  }
}
