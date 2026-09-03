import 'dart:io';

/// Starts and stops the bundled backend.
///
/// The backend runs as a child of this app rather than as a Windows service.
///
/// **Why not a service.** `node.exe` never calls `StartServiceCtrlDispatcher`,
/// so the Service Control Manager waits ninety seconds for a handshake that
/// never arrives and kills it with error 1053. A wrapper such as WinSW solves
/// that, but it adds an 18 MB vendored binary, an XML config, an elevated
/// install step, and a registration that can fail in half a dozen ways — all so
/// a process can run that this app could simply start itself.
///
/// A child process needs no elevation, no registration, and no service account.
/// It is what Electron and Tauri applications do with a local server, and the
/// failure modes are ones this code can see and report.
///
/// **The trade-off** is that the backend stops when the app closes. For a till
/// that is arguably right: nothing is orphaned, and no stale process holds port
/// 4000 the next morning.
class BackendProcess {
  BackendProcess._(this._process);

  final Process _process;
  int get pid => _process.pid;

  static BackendProcess? _current;

  /// True when running from an installed build rather than `flutter run`.
  ///
  /// A development machine runs the backend itself with `pnpm run dev`, and
  /// starting a second copy would fight over the port and the database.
  static bool get isPackaged => _executable() != null;

  /// Launches the backend and returns once the process exists.
  ///
  /// It does not wait for the server to answer — `waitForBackend` in the auth
  /// layer already does that, and it has to handle a slow start regardless.
  ///
  /// Returns null when there is nothing to launch, which is the normal case in
  /// development.
  static Future<BackendProcess?> start() async {
    if (_current != null) return _current;

    final executable = _executable();
    if (executable == null) return null;

    final directory = executable.parent.parent;
    final server = File('${directory.path}${Platform.pathSeparator}server.mjs');
    if (!server.existsSync()) return null;

    final process = await Process.start(
      executable.path,
      [server.path],
      workingDirectory: directory.path,
      // detachedWithStdio, not normal: the child must not hold this app open,
      // but its output is still wanted for the log below.
      mode: ProcessStartMode.detachedWithStdio,
      // Never through a shell. Flutter on Windows shows a console window for a
      // shell-spawned child, in front of the till, every launch.
      runInShell: false,
    );

    _current = BackendProcess._(process);
    return _current;
  }

  /// Stops the backend.
  ///
  /// Called when the window closes. A detached child would otherwise outlive
  /// the app and hold port 4000 against the next launch.
  static Future<void> stop() async {
    final current = _current;
    if (current == null) return;

    _current = null;

    // SIGTERM first so the server can close SQLite cleanly — a WAL left
    // uncheckpointed is recoverable, but an orderly shutdown is free here.
    current._process.kill(ProcessSignal.sigterm);

    // Windows does not deliver SIGTERM, so kill() falls back to terminating the
    // process anyway. The wait is for the orderly case.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    current._process.kill(ProcessSignal.sigkill);
  }

  /// The bundled Node runtime, or null when running from source.
  ///
  /// An installed build has `backend\node\node.exe` beside the app executable.
  /// A development run has neither.
  static File? _executable() {
    if (!Platform.isWindows) return null;

    final root = File(Platform.resolvedExecutable).parent;
    final node = File(
      '${root.path}${Platform.pathSeparator}backend'
      '${Platform.pathSeparator}node'
      '${Platform.pathSeparator}node.exe',
    );

    return node.existsSync() ? node : null;
  }
}
