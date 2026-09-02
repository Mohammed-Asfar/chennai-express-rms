/// What the backend says about this installation's licence.
///
/// Every field is served from the backend's local cache, so this arrives even
/// with no internet. See `LICENSING.md` for the grace period rules.
class ActivationStatus {
  const ActivationStatus({
    required this.allowed,
    required this.activated,
    this.status,
    this.branchCode,
    this.restaurant,
    this.graceDaysRemaining,
    this.warn = false,
    this.message,
    this.lastVerifiedAt,
  });

  /// False only when the app must refuse to run.
  final bool allowed;

  /// False before a key has ever been entered on this PC.
  final bool activated;

  /// `active` or `revoked` as of the last successful check.
  final String? status;

  final String? branchCode;
  final String? restaurant;

  /// Whole days before billing stops. Null when not in a grace period.
  final int? graceDaysRemaining;

  /// True when staff should be told something without being blocked.
  final bool warn;

  /// Written for staff, never a raw error.
  final String? message;

  final String? lastVerifiedAt;

  factory ActivationStatus.fromJson(Map<String, dynamic> json) => ActivationStatus(
        allowed: json['allowed'] as bool? ?? false,
        activated: json['activated'] as bool? ?? false,
        status: json['status'] as String?,
        branchCode: json['branchCode'] as String?,
        restaurant: json['restaurant'] as String?,
        graceDaysRemaining: json['graceDaysRemaining'] as int?,
        warn: json['warn'] as bool? ?? false,
        message: json['message'] as String?,
        lastVerifiedAt: json['lastVerifiedAt'] as String?,
      );

  /// True when the licence works but the client should be told why it might not
  /// tomorrow. Drives the banner on the home screen.
  bool get showBanner => allowed && warn && message != null;
}
