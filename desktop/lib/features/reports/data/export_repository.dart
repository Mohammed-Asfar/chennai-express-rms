import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';

/// Which export. The backend names them the same way.
enum ExportKind {
  bills('bills', 'Bills', 'One row per bill, with totals and tax'),
  billItems('bill-items', 'Bill items', 'One row per dish sold'),
  payments('payments', 'Payments', 'One row per payment, by the day it was taken');

  const ExportKind(this.path, this.label, this.description);

  final String path;
  final String label;
  final String description;
}

/// Saves the CSV exports to a folder the user chooses.
///
/// The file is written where they ask, not into a fixed downloads folder: these
/// go to an accountant, onto a USB stick, or into a shared drive, and a till
/// that hides them somewhere under AppData makes that harder than it needs to
/// be.
class ExportRepository {
  ExportRepository(this._api);

  final ApiClient _api;

  /// Writes one export and returns the file it wrote.
  Future<File> save({
    required ExportKind kind,
    required String from,
    required String to,
    required String directory,
  }) async {
    final csv = await _api.getText('/exports/${kind.path}.csv?from=$from&to=$to');

    final file = File('$directory${Platform.pathSeparator}${kind.path}-$from-to-$to.csv');
    await file.writeAsString(csv);
    return file;
  }

  /// Asks where to put them. Null when the dialog is dismissed.
  Future<String?> chooseDirectory() =>
      FilePicker.getDirectoryPath(dialogTitle: 'Where should the files go?');
}

final exportRepositoryProvider = Provider<ExportRepository>((ref) {
  return ExportRepository(ref.watch(apiClientProvider));
});
