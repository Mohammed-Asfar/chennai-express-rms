import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Enforces the single-source-of-truth rule for colours and typography
/// (CLAUDE.md section 6.1).
///
/// The analyzer cannot express "no Color literals outside app_colors.dart", so
/// this test reads the source. Without it the rule is a convention that decays
/// the first time someone is in a hurry.
void main() {
  final libDir = Directory('lib');

  List<File> dartFiles() => libDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  bool isThemeFile(String path) {
    final normalised = path.replaceAll(r'\', '/');
    return normalised.contains('core/theme/');
  }

  /// Strips comments so an example in a doc comment is not read as real code.
  String withoutComments(String source) {
    return source
        .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
  }

  test('no Color literals outside core/theme', () {
    final offenders = <String>[];
    final colorLiteral = RegExp(r'Color\(0x[0-9a-fA-F]{6,8}\)');

    for (final file in dartFiles()) {
      if (isThemeFile(file.path)) continue;
      final source = withoutComments(file.readAsStringSync());
      for (final match in colorLiteral.allMatches(source)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Colours belong in core/theme/app_colors.dart. Found:\n'
          '${offenders.join('\n')}',
    );
  });

  test('no Colors.* constants outside core/theme', () {
    final offenders = <String>[];
    // Colors.transparent is a structural value, not a brand colour.
    final materialColor = RegExp(r'\bColors\.(?!transparent\b)[a-zA-Z]+');

    for (final file in dartFiles()) {
      if (isThemeFile(file.path)) continue;
      final source = withoutComments(file.readAsStringSync());
      for (final match in materialColor.allMatches(source)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Use Theme.of(context).colorScheme instead of Material palette '
          'constants. Found:\n${offenders.join('\n')}',
    );
  });

  test('no inline TextStyle construction outside core/theme', () {
    final offenders = <String>[];
    final inlineStyle = RegExp(r'(?<!\.)\bTextStyle\(');

    for (final file in dartFiles()) {
      if (isThemeFile(file.path)) continue;
      final source = withoutComments(file.readAsStringSync());
      for (final match in inlineStyle.allMatches(source)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Read text styles from Theme.of(context).textTheme, or add one to '
          'core/theme/app_text_styles.dart. Found:\n${offenders.join('\n')}',
    );
  });

  test('no hardcoded fontSize outside core/theme', () {
    final offenders = <String>[];
    final fontSize = RegExp(r'fontSize:\s*\d');

    for (final file in dartFiles()) {
      if (isThemeFile(file.path)) continue;
      final source = withoutComments(file.readAsStringSync());
      for (final match in fontSize.allMatches(source)) {
        offenders.add('${file.path}: ${match.group(0)}');
      }
    }

    expect(offenders, isEmpty, reason: 'Font sizes belong in app_text_styles.dart.');
  });
}
