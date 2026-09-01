import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import 'auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    ref.read(authControllerProvider.notifier).login(
          _usernameController.text.trim(),
          _passwordController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
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
                        Icons.restaurant,
                        size: AppSpacing.xxl,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'Chennai Express',
                        style: theme.textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        'Billing Counter',
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.xl),

                      if (state.errorMessage != null) ...[
                        ErrorBanner(message: state.errorMessage!),
                        const SizedBox(height: AppSpacing.md),
                      ],

                      AppTextField(
                        controller: _usernameController,
                        label: 'Username',
                        autofocus: true,
                        enabled: !state.isSubmitting,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _passwordFocus.requestFocus(),
                        validator: (value) =>
                            (value == null || value.trim().isEmpty) ? 'Enter your username' : null,
                      ),
                      const SizedBox(height: AppSpacing.md),

                      AppTextField(
                        controller: _passwordController,
                        focusNode: _passwordFocus,
                        label: 'Password',
                        obscureText: _obscurePassword,
                        enabled: !state.isSubmitting,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword ? Icons.visibility_off : Icons.visibility,
                          ),
                          tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                        validator: (value) =>
                            (value == null || value.isEmpty) ? 'Enter your password' : null,
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
                            : const Text('Sign in'),
                      ),
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
