import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/settings_repository.dart';

/// The restaurant's own details, as they appear on the printed bill.
class BranchScreen extends ConsumerStatefulWidget {
  const BranchScreen({super.key});

  @override
  ConsumerState<BranchScreen> createState() => _BranchScreenState();
}

class _BranchScreenState extends ConsumerState<BranchScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  final _gstinController = TextEditingController();

  /// Kept so the logo card knows whether one exists.
  Branch? _branch;

  bool _loaded = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _gstinController.dispose();
    super.dispose();
  }

  void _fill(Branch branch) {
    _nameController.text = branch.name;
    _addressController.text = branch.address ?? '';
    _phoneController.text = branch.phone ?? '';
    _gstinController.text = branch.gstin ?? '';
    _branch = branch;
    _loaded = true;
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(branchProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Branch'),
        actions: [
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
      body: branch.when(
        loading: () => const AppLoading(message: 'Loading branch details'),
        error: (error, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: ErrorBanner(message: '$error'),
            ),
          ),
        ),
        data: (loaded) {
          if (!_loaded) {
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

          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Printed on every bill',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'These appear at the top of the customer copy.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.md),

                  AppTextField(
                    controller: _nameController,
                    label: 'Restaurant name',
                    enabled: !_saving,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'The bill needs a name on it'
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.md),

                  AppTextField(
                    controller: _addressController,
                    label: 'Address',
                    hintText: '12 Mount Road, Chennai 600002',
                    enabled: !_saving,
                  ),
                  const SizedBox(height: AppSpacing.md),

                  AppTextField(
                    controller: _phoneController,
                    label: 'Phone',
                    enabled: !_saving,
                  ),
                  const SizedBox(height: AppSpacing.md),

                  AppTextField(
                    controller: _gstinController,
                    label: 'GSTIN',
                    hintText: '33ABCDE1234F1Z5',
                    enabled: !_saving,
                    validator: _validateGstin,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    // A restaurant below the registration threshold has
                    // none, and the bill simply omits the line.
                    'Leave blank if the restaurant is not GST registered.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: AppSpacing.md),
          _LogoCard(branch: _branch!, onChanged: _reloadBranch),
        ],
      ),
    );
  }

  void _reloadBranch() {
    setState(() => _loaded = false);
    ref.invalidate(branchProvider);
    // The name, address, GSTIN and logo all print, so the sample bill on the
    // tax screen is now out of date.
    ref.invalidate(billPreviewProvider);
  }

  /// 15 characters: two state digits, a PAN, then three more.
  String? _validateGstin(String? value) {
    final gstin = (value ?? '').trim().toUpperCase();
    if (gstin.isEmpty) return null;
    if (!RegExp(r'^\d{2}[A-Z]{5}\d{4}[A-Z]\d[A-Z\d][A-Z\d]$').hasMatch(gstin)) {
      return 'Should be 15 characters, like 33ABCDE1234F1Z5';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    // An empty field means "no value", not an empty string on the printout.
    String? orNull(String text) => text.trim().isEmpty ? null : text.trim();

    try {
      await ref.read(settingsRepositoryProvider).updateBranch({
        'name': _nameController.text.trim(),
        'address': orNull(_addressController.text),
        'phone': orNull(_phoneController.text),
        'gstin': orNull(_gstinController.text),
      });

      if (!mounted) return;
      ref.invalidate(branchProvider);
      ref.invalidate(billPreviewProvider);
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Branch details saved')));
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }
}

/// Upload, switch off, or remove the logo printed above the bill.
///
/// The image itself is never fetched back — the raster is for the printer, not
/// the screen, and shipping kilobytes of base64 to draw a thumbnail would be
/// wasted work. The card reports whether one is set, not what it looks like.
class _LogoCard extends ConsumerStatefulWidget {
  const _LogoCard({required this.branch, required this.onChanged});

  final Branch branch;
  final VoidCallback onChanged;

  @override
  ConsumerState<_LogoCard> createState() => _LogoCardState();
}

class _LogoCardState extends ConsumerState<_LogoCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branch = widget.branch;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Logo', style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              'Printed above the name. A simple, high-contrast image works '
              'best — a thermal printer has no greys.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),

            Row(
              children: [
                Icon(
                  branch.hasLogo
                      ? Icons.image_outlined
                      : Icons.image_not_supported_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    branch.hasLogo ? 'A logo is set' : 'No logo',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                if (_busy)
                  const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  if (branch.hasLogo)
                    TextButton(onPressed: _remove, child: const Text('Remove')),
                  const SizedBox(width: AppSpacing.sm),
                  OutlinedButton.icon(
                    onPressed: _pick,
                    icon: const Icon(Icons.upload_outlined, size: 18),
                    label: Text(branch.hasLogo ? 'Replace' : 'Choose image'),
                  ),
                ],
              ],
            ),

            if (branch.hasLogo) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Print it on bills',
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          // Switching off keeps the image, so it can come back
                          // without uploading again.
                          'Switch off to keep the logo without printing it.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Switch(
                    value: branch.printLogo,
                    onChanged: _busy ? null : _togglePrint,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pick() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
      withData: true,
    );
    final bytes = result?.files.singleOrNull?.bytes;
    if (bytes == null) return;

    // Guarded here as well as on the server: a photograph straight off a phone
    // is several megabytes, and the useful part is a few hundred dots wide.
    if (bytes.length > 3 * 1024 * 1024) {
      _say('That image is too large. Use one under 3 MB.');
      return;
    }

    setState(() => _busy = true);
    try {
      await ref
          .read(settingsRepositoryProvider)
          .uploadLogo(base64Encode(bytes));
      if (!mounted) return;
      widget.onChanged();
      _say('Logo saved. Print a bill to check how it looks.');
    } on ApiException catch (error) {
      if (!mounted) return;
      _say(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await ref.read(settingsRepositoryProvider).removeLogo();
      if (!mounted) return;
      widget.onChanged();
    } on ApiException catch (error) {
      if (!mounted) return;
      _say(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePrint(bool value) async {
    setState(() => _busy = true);
    try {
      await ref.read(settingsRepositoryProvider).updateBranch({
        'printLogo': value,
      });
      if (!mounted) return;
      widget.onChanged();
    } on ApiException catch (error) {
      if (!mounted) return;
      _say(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
