import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/providers.dart';

/// Branch settings that change how bills are calculated, numbered and printed.
class BranchSettings {
  const BranchSettings({
    required this.gstEnabled,
    required this.taxMode,
    required this.defaultTaxRate,
    required this.businessDayStart,
    required this.billPrefix,
    required this.billResetPeriod,
    required this.billNumberFormat,
    required this.billNumberPad,
    required this.billFooter,
    required this.roundOffEnabled,
  });

  /// Whether GST applies at all. Off for a restaurant below the registration
  /// threshold — no tax is charged, and no GST is shown anywhere.
  final bool gstEnabled;

  /// inclusive or exclusive.
  final String taxMode;

  /// Basis points: 5% is 500.
  final int defaultTaxRate;

  /// `HH:mm`, when a trading day rolls over.
  final String businessDayStart;

  final String billPrefix;

  /// daily, monthly, yearly, financial_year or never.
  final String billResetPeriod;

  /// Tokens: {PREFIX} {NO} {YYYY} {YY} {MM} {DD} {FY}
  final String billNumberFormat;
  final int billNumberPad;
  final String billFooter;
  final bool roundOffEnabled;

  factory BranchSettings.fromJson(Map<String, dynamic> json) => BranchSettings(
    gstEnabled: json['gstEnabled'] as bool? ?? true,
    taxMode: json['taxMode'] as String? ?? 'inclusive',
    defaultTaxRate: json['defaultTaxRate'] as int? ?? 500,
    businessDayStart: json['businessDayStart'] as String? ?? '05:00',
    billPrefix: json['billPrefix'] as String? ?? '',
    billResetPeriod: json['billResetPeriod'] as String? ?? 'daily',
    billNumberFormat: json['billNumberFormat'] as String? ?? '{NO}',
    billNumberPad: json['billNumberPad'] as int? ?? 4,
    billFooter: json['billFooter'] as String? ?? '',
    roundOffEnabled: json['roundOffEnabled'] as bool? ?? true,
  );
}

/// The details printed at the top of every bill.
class Branch {
  const Branch({
    required this.id,
    required this.name,
    this.tagline,
    this.address,
    this.phone,
    this.gstin,
    this.hasLogo = false,
    this.printLogo = true,
  });

  final String id;
  final String name;

  /// A line under the name on the bill — "Since 1998". Null for none.
  final String? tagline;

  final String? address;
  final String? phone;

  /// 15 characters. Null for a restaurant below the registration threshold.
  final String? gstin;

  /// Whether a logo has been uploaded. The raster itself never comes to the
  /// client — it is kilobytes the UI has no use for.
  final bool hasLogo;

  /// Whether it is printed. Switching it off keeps the image (FR-P15).
  final bool printLogo;

  factory Branch.fromJson(Map<String, dynamic> json) => Branch(
    id: json['id'] as String,
    name: json['name'] as String,
    tagline: json['tagline'] as String?,
    address: json['address'] as String?,
    phone: json['phone'] as String?,
    gstin: json['gstin'] as String?,
    hasLogo: json['hasLogo'] as bool? ?? false,
    printLogo: json['printLogo'] as bool? ?? true,
  );
}

class SettingsRepository {
  SettingsRepository(this._api);

  final ApiClient _api;

  Future<BranchSettings> settings() async {
    final json = await _api.get('/settings');
    return BranchSettings.fromJson(json['settings'] as Map<String, dynamic>);
  }

  Future<BranchSettings> updateSettings(Map<String, dynamic> changes) async {
    final json = await _api.patch('/settings', changes);
    return BranchSettings.fromJson(json['settings'] as Map<String, dynamic>);
  }

  /// What a bill number would look like, before it is saved.
  Future<String> previewBillNumber({
    required String format,
    required String prefix,
    required int pad,
  }) async {
    final json = await _api.post('/settings/bill-number-preview', {
      'format': format,
      'prefix': prefix,
      'pad': pad,
    });
    return json['preview'] as String? ?? '';
  }

  /// One line of a sample bill, as it would print.
  Future<BillPreview> billPreview() async {
    final json = await _api.get('/settings/bill-preview');
    final preview = json['preview'] as Map<String, dynamic>;
    return BillPreview(
      paper: json['paper'] as String? ?? '80mm',
      width: preview['width'] as int? ?? 48,
      hasLogo: preview['hasLogo'] as bool? ?? false,
      logoImage: json['logoImage'] as String?,
      lines: ((preview['lines'] as List<dynamic>?) ?? const [])
          .map((l) => PreviewLine.fromJson(l as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<Branch> branch() async {
    final json = await _api.get('/branch');
    return Branch.fromJson(json['branch'] as Map<String, dynamic>);
  }

  Future<Branch> updateBranch(Map<String, dynamic> changes) async {
    final json = await _api.patch('/branch', changes);
    return Branch.fromJson(json['branch'] as Map<String, dynamic>);
  }

  /// Uploads a logo, which the backend rasterises for the till's paper width.
  Future<void> uploadLogo(String base64Image) async {
    await _api.post('/branch/logo', {'image': base64Image});
  }

  /// The stored logo as a PNG data URL, or null when none is set.
  ///
  /// Fetched separately from the branch because it is kilobytes of base64 that
  /// only the screens actually drawing it need.
  Future<String?> fetchLogo() async {
    final json = await _api.get('/branch/logo');
    return json['logoImage'] as String?;
  }

  Future<void> removeLogo() async {
    await _api.delete('/branch/logo');
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(apiClientProvider));
});

final branchSettingsProvider = FutureProvider<BranchSettings>((ref) {
  return ref.watch(settingsRepositoryProvider).settings();
});

final branchProvider = FutureProvider<Branch>((ref) {
  return ref.watch(settingsRepositoryProvider).branch();
});

/// The logo as a PNG data URL, or null when none is set.
///
/// Separate from [branchProvider] so the base64 is fetched only by screens that
/// draw it. Invalidate it alongside the branch after an upload or a removal.
final branchLogoProvider = FutureProvider<String?>((ref) {
  return ref.watch(settingsRepositoryProvider).fetchLogo();
});

/// One line of the sample bill.
class PreviewLine {
  const PreviewLine({
    required this.text,
    required this.large,
    required this.bold,
    required this.align,
    this.heightScale = 1,
    this.widthScale = 1,
  });

  final String text;

  /// Enlarged on paper in either direction — the total, and the branch name.
  final bool large;
  final bool bold;

  /// left, center or right.
  final String align;

  /// How many times taller the printer draws this line, 1-8.
  final int heightScale;

  /// How many times wider. Not rendered on screen: a wider face would overflow
  /// the paper box even where the line prints correctly, and the box width is
  /// what proves an amount fits.
  final int widthScale;

  factory PreviewLine.fromJson(Map<String, dynamic> json) => PreviewLine(
    text: json['text'] as String? ?? '',
    large: json['large'] as bool? ?? false,
    bold: json['bold'] as bool? ?? false,
    align: json['align'] as String? ?? 'left',
    heightScale: json['heightScale'] as int? ?? 1,
    widthScale: json['widthScale'] as int? ?? 1,
  );
}

/// A sample bill decoded back from what the printer would receive.
class BillPreview {
  const BillPreview({
    required this.lines,
    required this.width,
    required this.paper,
    required this.hasLogo,
    this.logoImage,
  });

  final List<PreviewLine> lines;

  /// Characters across, so the preview can be sized like the paper.
  final int width;
  final String paper;

  /// A logo is included but cannot be shown as text.
  final bool hasLogo;

  /// The rasterised logo as a PNG data URL — what actually burns onto the
  /// paper, dithering and all, rather than the image that was uploaded.
  final String? logoImage;
}

final billPreviewProvider = FutureProvider<BillPreview>((ref) {
  return ref.watch(settingsRepositoryProvider).billPreview();
});
