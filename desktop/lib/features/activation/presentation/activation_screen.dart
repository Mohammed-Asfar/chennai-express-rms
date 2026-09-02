import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/error_banner.dart';
import 'activation_controller.dart';

/// Asks for the activation key, before anyone can sign in.
///
/// Deliberately built like the login screen: the same dark card on the same
/// light page. This is the first thing anyone sees on a new install, and it
/// should read as part of the product rather than a licensing gate bolted on.
class ActivationScreen extends ConsumerStatefulWidget {
  const ActivationScreen({super.key});

  @override
  ConsumerState<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends ConsumerState<ActivationScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    ref.read(activationControllerProvider.notifier).activate(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(activationControllerProvider);
    final status = state.status;

    // Already activated but out of grace, or revoked. There is no key to enter —
    // the one they have is the right one, so offering the field would send staff
    // round a loop that cannot succeed.
    final expired = status?.activated == true;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
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
                  builder: (context) {
                    final theme = Theme.of(context);
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Image.asset(
                            'assets/logo.png',
                            width: 104,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          expired ? 'Licence expired' : 'Activate this PC',
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
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          expired
                              ? status?.message ??
                                  'This installation can no longer be used. Please contact support.'
                              : 'Enter the activation key supplied with your licence. '
                                  'It will be linked to this PC.',
                          style: theme.textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),

                        if (!expired) ...[
                          const SizedBox(height: AppSpacing.xl),

                          if (state.errorMessage != null) ...[
                            ErrorBanner(message: state.errorMessage!),
                            const SizedBox(height: AppSpacing.md),
                          ],

                          AppTextField(
                            controller: _controller,
                            label: 'Activation key',
                            hintText: 'CX-XXXX-XXXX-XXXX',
                            autofocus: true,
                            enabled: !state.isSubmitting,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _submit(),
                            inputFormatters: const [_KeyFormatter()],
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
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Text('Activate'),
                            ),
                          ),
                        ] else ...[
                          const SizedBox(height: AppSpacing.lg),
                          SizedBox(
                            height: AppSpacing.primaryActionHeight,
                            child: OutlinedButton(
                              onPressed: () =>
                                  ref.read(activationControllerProvider.notifier).check(),
                              child: const Text('Check again'),
                            ),
                          ),
                        ],

                        if (status?.restaurant != null) ...[
                          const SizedBox(height: AppSpacing.lg),
                          Text(
                            '${status!.restaurant}'
                            '${status.branchCode != null ? ' · ${status.branchCode}' : ''}',
                            style: theme.textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
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

/// Upper-cases as you type and inserts the dashes.
///
/// Someone reading a key off a phone screen should not have to get the dashes
/// right, and a lowercase paste should not look like a wrong key. The backend
/// normalises too — this is so the field looks correct while being typed.
class _KeyFormatter extends TextInputFormatter {
  const _KeyFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue next) {
    final raw = next.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (raw.isEmpty) return next.copyWith(text: '');

    // Everything after the CX prefix is grouped in fours.
    final body = raw.startsWith('CX') ? raw.substring(2) : raw;
    final buffer = StringBuffer('CX');
    for (var i = 0; i < body.length && i < 12; i++) {
      if (i % 4 == 0) buffer.write('-');
      buffer.write(body[i]);
    }

    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
