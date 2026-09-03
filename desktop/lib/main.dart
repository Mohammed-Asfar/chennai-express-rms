import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'core/backend/backend_process.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Before the window: the backend takes a few seconds to migrate and listen,
  // and starting it first means that happens while the UI is drawing rather
  // than after. In development this does nothing — `pnpm run dev` already has
  // one running, and a second would fight over the port.
  await BackendProcess.start();

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

  // The backend is a detached child, so it outlives this app unless it is told
  // otherwise — and a stale one holds port 4000 against the next launch.
  await windowManager.setPreventClose(BackendProcess.isPackaged);

  runApp(const ProviderScope(child: ChennaiExpressApp()));
}
