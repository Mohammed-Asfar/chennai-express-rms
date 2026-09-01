import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/release_info.dart';
import '../data/update_repository.dart';

enum UpdatePhase { idle, downloading, verifying, ready, failed }

class UpdateState {
  const UpdateState({
    this.result,
    this.phase = UpdatePhase.idle,
    this.received = 0,
    this.total = 0,
    this.errorMessage,
    this.installer,
  });

  final UpdateCheckResult? result;
  final UpdatePhase phase;
  final int received;
  final int total;
  final String? errorMessage;
  final File? installer;

  bool get hasUpdate => result?.updateAvailable ?? false;
  bool get isForced => result?.isForced ?? false;
  ReleaseInfo? get release => result?.release;

  double get progress => total == 0 ? 0 : received / total;

  UpdateState copyWith({
    UpdateCheckResult? result,
    UpdatePhase? phase,
    int? received,
    int? total,
    String? errorMessage,
    File? installer,
    bool clearError = false,
  }) {
    return UpdateState(
      result: result ?? this.result,
      phase: phase ?? this.phase,
      received: received ?? this.received,
      total: total ?? this.total,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      installer: installer ?? this.installer,
    );
  }
}

class UpdateController extends StateNotifier<UpdateState> {
  UpdateController(this._repository) : super(const UpdateState());

  final UpdateRepository _repository;
  bool _cancelRequested = false;

  /// Checks for an update and decides whether to surface it.
  ///
  /// Silent on failure — an offline restaurant sees nothing, which is correct.
  Future<void> check({bool respectDismissal = true}) async {
    final result = await _repository.check();
    if (!mounted || result == null) return;

    if (result.updateAvailable && respectDismissal && !result.isForced) {
      final release = result.release;
      if (release != null && await _repository.wasDismissedToday(release.buildNumber)) {
        if (!mounted) return;
        // Known about, but not shown again today.
        state = state.copyWith(result: result, phase: UpdatePhase.idle);
        return;
      }
    }

    if (!mounted) return;
    state = state.copyWith(result: result);
  }

  Future<void> dismiss() async {
    final release = state.release;
    // A forced update cannot be postponed: an old build after a billing fix
    // would keep producing wrong bills.
    if (release == null || state.isForced) return;
    await _repository.dismissForToday(release.buildNumber);
    if (!mounted) return;
    state = const UpdateState();
  }

  Future<void> downloadAndInstall() async {
    final release = state.release;
    if (release == null) return;

    _cancelRequested = false;
    state = state.copyWith(
      phase: UpdatePhase.downloading,
      received: 0,
      total: release.fileSize,
      clearError: true,
    );

    try {
      final file = await _repository.download(
        release,
        onProgress: (received, total) {
          if (!mounted) return;
          state = state.copyWith(received: received, total: total);
        },
        isCancelled: () async => _cancelRequested,
      );

      if (!mounted) return;
      state = state.copyWith(phase: UpdatePhase.ready, installer: file);

      await _repository.launchInstaller(file);
    } on UpdateException catch (error) {
      if (!mounted) return;
      state = state.copyWith(phase: UpdatePhase.failed, errorMessage: error.message);
    } catch (error) {
      if (!mounted) return;
      // A failed update must leave the working version running.
      state = state.copyWith(
        phase: UpdatePhase.failed,
        errorMessage: 'The update could not be installed. $error',
      );
    }
  }

  void cancelDownload() {
    _cancelRequested = true;
    state = state.copyWith(phase: UpdatePhase.idle, received: 0);
  }

  void clearError() => state = state.copyWith(phase: UpdatePhase.idle, clearError: true);
}

final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateState>((ref) {
  return UpdateController(ref.watch(updateRepositoryProvider));
});
