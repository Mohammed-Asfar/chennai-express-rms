import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // A billing counter runs one window, maximised, all day. A minimum size keeps
  // the order and bill panes usable if a user drags it smaller.
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1400, 900),
      minimumSize: Size(1024, 700),
      center: true,
      title: 'Chennai Express',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(const ProviderScope(child: ChennaiExpressApp()));
}
