import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
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
    ref
        .read(authControllerProvider.notifier)
        .login(_usernameController.text.trim(), _passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);

    // The card carries the 30% charcoal — the same dark that anchors the
    // sidebar — so the app's identity is set before anyone signs in. It is the
    // only dark mass on a light page, which puts the eye where the work is.
    //
    // The subtree gets the shell theme rather than per-widget colour overrides,
    // so the fields and labels stay readable without any screen-level colour.
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Theme(
              data: AppTheme.onShell,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.shell,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                  border: Border.all(color: AppColors.shellBorder),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.xxl,
                ),
                child: Builder(
                  // Reads the shell theme above, not the page theme — otherwise
                  // the headline and caption stay dark ink on a dark card.
                  builder: (context) {
                    final theme = Theme.of(context);
                    return Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Large here, where there is room. The login screen is
                          // the one place the restaurant's own identity gets to
                          // be the whole point rather than a corner of a toolbar.
                          Center(
                            child: Image.asset(
                              'assets/logo.png',
                              width: 132,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          // The name stays under the logo: the mark carries it
                          // as artwork, but a screen reader gets nothing from an
                          // image, and a faint print reads as decoration.
                          Text(
                            'Chennai Express',
                            style: theme.textTheme.headlineMedium,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Center(
                            child: Container(
                              width: 32,
                              height: 2,
                              color: AppColors.accent,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Restaurant management system',
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
                                (value == null || value.trim().isEmpty)
                                ? 'Enter your username'
                                : null,
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
                                _obscurePassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                size: 18,
                              ),
                              tooltip: _obscurePassword
                                  ? 'Show password'
                                  : 'Hide password',
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                            validator: (value) =>
                                (value == null || value.isEmpty)
                                ? 'Enter your password'
                                : null,
                          ),

                          const SizedBox(height: AppSpacing.lg),

                          SizedBox(
                            height: AppSpacing.primaryActionHeight,
                            child: ElevatedButton(
                              onPressed: state.isSubmitting ? null : _submit,
                              child: state.isSubmitting
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('Sign in'),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
