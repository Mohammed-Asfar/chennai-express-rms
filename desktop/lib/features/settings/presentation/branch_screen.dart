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
        ],
      ),
    );
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
