import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'core/backend/backend_process.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // A billing counter runs one window, maximised, all day.
  //
  // The minimum is deliberately modest: a counter PC is often 1366x768, and a
  // minimum larger than the screen would push content off the edge.
  //
  // This comes before the backend deliberately. Starting the backend first put
  // a second of process work between the window being created and maximise()
  // taking effect, and Windows painted the un-maximised 1280x800 frame in the
  // gap — the app opened looking half-sized on first launch.
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

  // Not awaited: the window is already up, and the UI's own "waiting for the
  // service" screen covers the seconds the backend needs to migrate and listen.
  // Awaiting it here would hold the first frame for no benefit.
  unawaited(BackendProcess.start());

  runApp(const ProviderScope(child: ChennaiExpressApp()));
}
