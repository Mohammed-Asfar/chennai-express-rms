import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/app_loading.dart';
import 'core/widgets/backend_unreachable.dart';
import 'features/activation/presentation/activation_controller.dart';
import 'features/activation/presentation/activation_screen.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/auth/presentation/change_password_screen.dart';
import 'features/auth/presentation/login_screen.dart';
import 'features/home/presentation/home_screen.dart';
import 'features/updates/presentation/update_watcher.dart';

class ChennaiExpressApp extends StatelessWidget {
  const ChennaiExpressApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chennai Express',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const _ActivationGate(),
    );
  }
}

/// Decides whether the app may run at all.
///
/// Ahead of the auth gate: an unlicensed installation must not reach a login
/// screen, and the backend answers this from a local cache so it works offline.
class _ActivationGate extends ConsumerWidget {
  const _ActivationGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(activationControllerProvider);

    return switch (state.phase) {
      ActivationPhase.checking =>
        const Scaffold(body: AppLoading(message: 'Starting up...')),
      // The service being slow to start is not a licensing failure, and must not
      // put an activated till in front of the key screen.
      ActivationPhase.backendDown => BackendUnreachable(
          onRetry: () => ref.read(activationControllerProvider.notifier).check(),
        ),
      ActivationPhase.blocked => const ActivationScreen(),
      ActivationPhase.allowed => const _AuthGate(),
    };
  }
}

/// Chooses the screen from auth state.
///
/// Routing lives here rather than in each screen so there is one place that
/// decides what an unauthenticated or must-change-password user can see.
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(authControllerProvider).status;

    return switch (status) {
      AuthStatus.checking => const Scaffold(body: AppLoading(message: 'Starting up...')),
      // A stored session is kept: the service is probably still starting.
      AuthStatus.backendDown => BackendUnreachable(
          onRetry: () => ref.read(authControllerProvider.notifier).retryConnection(),
        ),
      AuthStatus.unauthenticated => const LoginScreen(),
      AuthStatus.mustChangePassword => const ChangePasswordScreen(),
      // Wrapped so an update prompt can never appear over the login screen.
      AuthStatus.authenticated => const UpdateWatcher(child: HomeScreen()),
    };
  }
}
