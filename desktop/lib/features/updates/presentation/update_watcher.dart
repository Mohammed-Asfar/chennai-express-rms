import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'update_controller.dart';
import 'update_dialog.dart';

/// Checks for updates on startup and once a day, and shows the dialog.
///
/// Wraps the authenticated part of the app so the prompt can never appear over
/// the login screen.
class UpdateWatcher extends ConsumerStatefulWidget {
  const UpdateWatcher({super.key, required this.child, this.canPrompt});

  final Widget child;

  /// Returns false while it would be disruptive to interrupt — an open order or
  /// a bill being taken. The check still runs; only the dialog waits.
  final bool Function()? canPrompt;

  @override
  ConsumerState<UpdateWatcher> createState() => _UpdateWatcherState();
}

class _UpdateWatcherState extends ConsumerState<UpdateWatcher> {
  Timer? _dailyTimer;
  Timer? _retryTimer;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    // Deferred so the first frame renders before any network work.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    _dailyTimer = Timer.periodic(const Duration(hours: 24), (_) => _check());
  }

  @override
  void dispose() {
    _dailyTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    await ref.read(updateControllerProvider.notifier).check();
    if (mounted) _maybePrompt();
  }

  void _maybePrompt() {
    if (_dialogOpen) return;

    final state = ref.read(updateControllerProvider);
    if (!state.hasUpdate) return;

    // Never interrupt a transaction. Try again shortly rather than dropping it.
    if (widget.canPrompt != null && !widget.canPrompt!()) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(minutes: 5), () {
        if (mounted) _maybePrompt();
      });
      return;
    }

    _dialogOpen = true;
    UpdateDialog.show(context).whenComplete(() {
      if (mounted) _dialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // A forced update that arrives while the app is running must still surface.
    ref.listen(updateControllerProvider, (previous, next) {
      if (next.hasUpdate && next.isForced && !_dialogOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
      }
    });

    return widget.child;
  }
}
