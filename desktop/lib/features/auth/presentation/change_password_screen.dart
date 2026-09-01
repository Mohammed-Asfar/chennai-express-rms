import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import 'auth_controller.dart';

/// Shown when the backend reports `mustChangePassword`.
///
/// There is no skip: a restaurant PC left on the seeded password is a known
/// login anyone can walk up and use.
class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key, this.forced = true});

  final bool forced;

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    ref
        .read(authControllerProvider.notifier)
        .changePassword(_currentController.text, _newController.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: widget.forced
          ? null
          : AppBar(
              title: const Text('Change password'),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.lock_outline,
                        size: AppSpacing.xxl,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        widget.forced ? 'Set a new password' : 'Change password',
                        style: theme.textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                      if (widget.forced) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Choose your own password before continuing.',
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.xl),

                      if (state.errorMessage != null) ...[
                        ErrorBanner(message: state.errorMessage!),
                        const SizedBox(height: AppSpacing.md),
                      ],

                      AppTextField(
                        controller: _currentController,
                        label: 'Current password',
                        obscureText: _obscure,
                        autofocus: true,
                        enabled: !state.isSubmitting,
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            (value == null || value.isEmpty) ? 'Enter your current password' : null,
                      ),
                      const SizedBox(height: AppSpacing.md),

                      AppTextField(
                        controller: _newController,
                        label: 'New password',
                        obscureText: _obscure,
                        enabled: !state.isSubmitting,
                        textInputAction: TextInputAction.next,
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                          tooltip: _obscure ? 'Show passwords' : 'Hide passwords',
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) return 'Enter a new password';
                          if (value.length < 6) return 'Use at least 6 characters';
                          if (value == _currentController.text) {
                            return 'The new password must be different';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: AppSpacing.md),

                      AppTextField(
                        controller: _confirmController,
                        label: 'Confirm new password',
                        obscureText: _obscure,
                        enabled: !state.isSubmitting,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        validator: (value) =>
                            value != _newController.text ? 'Passwords do not match' : null,
                      ),
                      const SizedBox(height: AppSpacing.lg),

                      ElevatedButton(
                        onPressed: state.isSubmitting ? null : _submit,
                        child: state.isSubmitting
                            ? const SizedBox(
                                height: AppSpacing.md,
                                width: AppSpacing.md,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Save password'),
                      ),

                      if (widget.forced) ...[
                        const SizedBox(height: AppSpacing.sm),
                        TextButton(
                          onPressed: state.isSubmitting
                              ? null
                              : () => ref.read(authControllerProvider.notifier).logout(),
                          child: const Text('Sign out'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
