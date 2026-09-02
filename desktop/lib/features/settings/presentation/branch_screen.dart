import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
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

          _LogoCard(branch: _branch!, onChanged: _reloadBranch),
          const SizedBox(height: AppSpacing.md),

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

  void _reloadBranch() {
    setState(() => _loaded = false);
    ref.invalidate(branchProvider);
    // The thumbnail is fetched separately, so it will not refresh on its own
    // after an upload or a removal.
    ref.invalidate(branchLogoProvider);
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
/// Shows the rasterised logo rather than the uploaded file: the original is not
/// kept, and the dithered version is the one worth checking — it is what burns
/// onto the paper. "A logo is set" cannot tell you it is the wrong image.
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wording and controls on the left, the image itself on the right:
            // the logo is the thing being judged, so it gets the room.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Logo', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    'Printed above the name. A simple, high-contrast image '
                    'works best — a thermal printer has no greys.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.md),

                  Row(
                    children: [
                      if (_busy)
                        const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else ...[
                        OutlinedButton.icon(
                          onPressed: _pick,
                          icon: const Icon(Icons.upload_outlined, size: 18),
                          label: Text(
                            branch.hasLogo ? 'Replace' : 'Choose image',
                          ),
                        ),
                        if (branch.hasLogo) ...[
                          const SizedBox(width: AppSpacing.sm),
                          TextButton(
                            onPressed: _remove,
                            child: const Text('Remove'),
                          ),
                        ],
                      ],
                    ],
                  ),

                  if (branch.hasLogo) ...[
                    const SizedBox(height: AppSpacing.md),
                    Text('Print it on bills', style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            // Switching off keeps the image, so it can come
                            // back without uploading again.
                            'Switch off to keep the logo without printing it.',
                            style: theme.textTheme.bodySmall,
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

            const SizedBox(width: AppSpacing.xl),
            _LogoThumbnail(hasLogo: branch.hasLogo),
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

/// The stored logo, drawn as the printer will render it.
///
/// A white plate behind it, because the raster is black-on-transparent and the
/// card is white — on a tinted ground the dots would read as a different weight
/// than they print at.
class _LogoThumbnail extends ConsumerWidget {
  const _LogoThumbnail({required this.hasLogo});

  final bool hasLogo;

  /// Wide and short, matching the shape of a receipt-width raster. A square
  /// would letterbox it down to a strip and waste the height.
  static const double _width = 260;
  static const double _height = 120;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Container(
      height: _height,
      width: _width,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: !hasLogo
          ? Icon(
              Icons.image_not_supported_outlined,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            )
          : ref
                .watch(branchLogoProvider)
                .when(
                  loading: () => const Center(
                    child: SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  // The logo failing to draw must not look like no logo: it is
                  // still set, and still prints.
                  error: (_, _) => Icon(
                    Icons.broken_image_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  data: (image) => image == null
                      ? Icon(
                          Icons.image_outlined,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        )
                      : Image.memory(
                          base64Decode(image.split(',').last),
                          // Nearest-neighbour keeps the one-bit dots crisp;
                          // smoothing would blur them into greys the thermal
                          // head cannot actually print.
                          filterQuality: FilterQuality.none,
                          fit: BoxFit.contain,
                        ),
                ),
    );
  }
}
