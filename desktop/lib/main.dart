import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // A billing counter runs one window, maximised, all day.
  //
  // The minimum is deliberately modest: a counter PC is often 1366x768, and a
  // minimum larger than the screen would push content off the edge.
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      title: 'Chennai Express',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.maximize();
      await windowManager.focus();
    },
  );

  runApp(const ProviderScope(child: ChennaiExpressApp()));
}
