class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    required this.fileSize,
    required this.sha256,
    required this.releaseNotes,
    required this.isMandatory,
    required this.releasedAt,
  });

  final String version;
  final int buildNumber;
  final String downloadUrl;
  final int fileSize;
  final String sha256;
  final String releaseNotes;
  final bool isMandatory;
  final String releasedAt;

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) => ReleaseInfo(
        version: json['version'] as String,
        buildNumber: json['buildNumber'] as int,
        downloadUrl: json['downloadUrl'] as String,
        fileSize: json['fileSize'] as int,
        sha256: json['sha256'] as String,
        releaseNotes: json['releaseNotes'] as String? ?? '',
        isMandatory: json['isMandatory'] as bool? ?? false,
        releasedAt: json['releasedAt'] as String? ?? '',
      );

  String get readableSize {
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(0)} KB';
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.currentBuild,
    required this.updateAvailable,
    required this.isForced,
    this.release,
  });

  final String currentVersion;
  final int currentBuild;
  final bool updateAvailable;

  /// The dialog cannot be dismissed: either the release is mandatory, or this
  /// build is below the minimum the release supports.
  final bool isForced;
  final ReleaseInfo? release;

  factory UpdateCheckResult.fromJson(Map<String, dynamic> json) => UpdateCheckResult(
        currentVersion: json['currentVersion'] as String,
        currentBuild: json['currentBuild'] as int,
        updateAvailable: json['updateAvailable'] as bool? ?? false,
        isForced: json['isForced'] as bool? ?? false,
        release: json['release'] == null
            ? null
            : ReleaseInfo.fromJson(json['release'] as Map<String, dynamic>),
      );
}
