import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/printer_repository.dart';

/// Adds or edits a printer.
///
/// The address field changes meaning with the connection type, so the hint and
/// the help text follow the choice — a network address typed into a USB field
/// fails at print time, which is the worst moment to find out.
class PrinterDialog extends ConsumerStatefulWidget {
  const PrinterDialog({super.key, this.printer, this.discovered});

  final Printer? printer;

  /// A result from the scan, used to prefill name, connection and address.
  final DiscoveredPrinter? discovered;

  static Future<bool?> show(
    BuildContext context, {
    Printer? printer,
    DiscoveredPrinter? discovered,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (_) => PrinterDialog(printer: printer, discovered: discovered),
    );
  }

  @override
  ConsumerState<PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends ConsumerState<PrinterDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();

  String _connection = 'network';
  String _role = 'both';
  String _paperWidth = '80mm';

  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.printer != null;

  @override
  void initState() {
    super.initState();
    final printer = widget.printer;
    final discovered = widget.discovered;

    if (printer != null) {
      _nameController.text = printer.name;
      _addressController.text = printer.address;
      _connection = printer.connection;
      _role = printer.role;
      _paperWidth = printer.paperWidth;
    } else if (discovered != null) {
      // Role and paper are not discoverable — they stay at the defaults, and
      // the test print is what confirms the paper width.
      _nameController.text = discovered.name;
      _addressController.text = discovered.address;
      _connection = discovered.connection;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isNetwork = _connection == 'network';

    return AlertDialog(
      title: Text(
        _isEditing ? 'Edit ${widget.printer!.name}' : 'Add a printer',
      ),
      content: SizedBox(
        width: 440,
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
                  label: 'Name',
                  hintText: 'Billing counter, Kitchen',
                  autofocus: true,
                  enabled: !_saving,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Give the printer a name'
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),

                Text('CONNECTION', style: theme.textTheme.labelSmall),
                const SizedBox(height: AppSpacing.xs),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'network',
                      label: Text('Network'),
                      icon: Icon(Icons.lan_outlined, size: 16),
                    ),
                    ButtonSegment(
                      value: 'usb',
                      label: Text('USB'),
                      icon: Icon(Icons.usb, size: 16),
                    ),
                  ],
                  selected: {_connection},
                  onSelectionChanged: _saving
                      ? null
                      : (values) => setState(() => _connection = values.first),
                ),
                const SizedBox(height: AppSpacing.md),

                AppTextField(
                  controller: _addressController,
                  label: isNetwork
                      ? 'IP address and port'
                      : 'Device or share name',
                  hintText: isNetwork
                      ? '192.168.1.50:9100'
                      : r'\\.\COM3  or  LPT1',
                  enabled: !_saving,
                  validator: _validateAddress,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  isNetwork
                      ? 'Most thermal printers listen on port 9100. Find the IP in '
                            'the printer\'s own settings printout.'
                      : 'The Windows port or share the printer is connected to.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),

                Text('WHAT IT PRINTS', style: theme.textTheme.labelSmall),
                const SizedBox(height: AppSpacing.xs),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'both', label: Text('Both')),
                    ButtonSegment(value: 'bill', label: Text('Bills')),
                    ButtonSegment(value: 'kot', label: Text('Kitchen')),
                  ],
                  selected: {_role},
                  onSelectionChanged: _saving
                      ? null
                      : (values) => setState(() => _role = values.first),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  // The single-printer restaurant is the common case here.
                  _role == 'both'
                      ? 'One printer handles bills and kitchen tickets.'
                      : _role == 'bill'
                      ? 'Customer bills only.'
                      : 'Kitchen tickets only.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),

                Text('PAPER', style: theme.textTheme.labelSmall),
                const SizedBox(height: AppSpacing.xs),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: '80mm', label: Text('80mm')),
                    ButtonSegment(value: '58mm', label: Text('58mm')),
                  ],
                  selected: {_paperWidth},
                  onSelectionChanged: _saving
                      ? null
                      : (values) => setState(() => _paperWidth = values.first),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Send a test print after saving — it shows whether the width is right.',
                  style: theme.textTheme.bodySmall,
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
              : Text(_isEditing ? 'Save' : 'Add printer'),
        ),
      ],
    );
  }

  String? _validateAddress(String? value) {
    final address = (value ?? '').trim();
    if (address.isEmpty) return 'Enter the address';

    if (_connection == 'network') {
      // Checked here rather than at print time, when the queue would just
      // record a failure nobody is watching.
      final match = RegExp(r'^([\w.-]+)(?::(\d+))?$').firstMatch(address);
      if (match == null) return 'Use an address like 192.168.1.50:9100';
      final port = match.group(2);
      if (port != null) {
        final value = int.tryParse(port);
        if (value == null || value < 1 || value > 65535) {
          return 'Port must be 1 to 65535';
        }
      }
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    final repo = ref.read(printerRepositoryProvider);
    var address = _addressController.text.trim();
    // Default the port rather than making everyone type the same four digits.
    if (_connection == 'network' && !address.contains(':')) {
      address = '$address:9100';
    }

    try {
      if (_isEditing) {
        await repo.update(
          widget.printer!.id,
          name: _nameController.text.trim(),
          connection: _connection,
          address: address,
          role: _role,
          paperWidth: _paperWidth,
        );
      } else {
        await repo.create(
          name: _nameController.text.trim(),
          connection: _connection,
          address: address,
          role: _role,
          paperWidth: _paperWidth,
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
    }
  }
}
