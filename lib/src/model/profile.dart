/// A subscription profile managed by the app.
library;

import '../util/url.dart';

class Profile {
  const Profile({
    required this.name,
    required this.url,
    this.updatedAt,
    this.size,
    this.trafficUpload,
    this.trafficDownload,
    this.trafficTotal,
    this.trafficExpireAt,
  });

  final String name;
  final String url;
  final DateTime? updatedAt;
  final int? size;

  /// Provider reported traffic (bytes) from `Subscription-Userinfo`.
  final int? trafficUpload;
  final int? trafficDownload;
  final int? trafficTotal;
  final DateTime? trafficExpireAt;

  int? get trafficUsed {
    if (trafficUpload == null && trafficDownload == null) return null;
    return (trafficUpload ?? 0) + (trafficDownload ?? 0);
  }

  bool get hasTraffic => trafficTotal != null || trafficUsed != null;

  Profile copyWith({
    String? name,
    String? url,
    DateTime? updatedAt,
    int? size,
    int? trafficUpload,
    int? trafficDownload,
    int? trafficTotal,
    DateTime? trafficExpireAt,
  }) {
    return Profile(
      name: name ?? this.name,
      url: url ?? this.url,
      updatedAt: updatedAt ?? this.updatedAt,
      size: size ?? this.size,
      trafficUpload: trafficUpload ?? this.trafficUpload,
      trafficDownload: trafficDownload ?? this.trafficDownload,
      trafficTotal: trafficTotal ?? this.trafficTotal,
      trafficExpireAt: trafficExpireAt ?? this.trafficExpireAt,
    );
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'url': url,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        if (size != null) 'size': size,
        if (trafficUpload != null) 'trafficUpload': trafficUpload,
        if (trafficDownload != null) 'trafficDownload': trafficDownload,
        if (trafficTotal != null) 'trafficTotal': trafficTotal,
        if (trafficExpireAt != null)
          'trafficExpire': trafficExpireAt!.toIso8601String(),
      };

  static Profile? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final url = json['url'];
    if (name is! String || name.isEmpty) return null;
    final updated = json['updatedAt'];
    DateTime? updatedAt;
    if (updated is String) updatedAt = DateTime.tryParse(updated);
    final size = json['size'];
    final expire = json['trafficExpire'];
    return Profile(
      name: name,
      url: url is String ? url : '',
      updatedAt: updatedAt,
      size: size is int ? size : null,
      trafficUpload:
          json['trafficUpload'] is int ? json['trafficUpload'] as int : null,
      trafficDownload: json['trafficDownload'] is int
          ? json['trafficDownload'] as int
          : null,
      trafficTotal:
          json['trafficTotal'] is int ? json['trafficTotal'] as int : null,
      trafficExpireAt: expire is String ? DateTime.tryParse(expire) : null,
    );
  }
}

/// Rejects names that cannot safely become file names.
String? validateProfileName(String name) {
  if (name.trim().isEmpty) return 'Enter a name.';
  if (name.trim() != name) {
    return 'Remove leading and trailing spaces from the name.';
  }
  if (name.length > 64) return 'Use a name of at most 64 characters.';
  const invalid = r'<>:"/\|?*';
  for (final rune in name.runes) {
    final char = String.fromCharCode(rune);
    if (rune < 0x20 || invalid.contains(char)) {
      return 'Names cannot contain $char or control characters.';
    }
  }
  if (name.endsWith('.')) return 'Names cannot end with a period.';
  const reserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  if (reserved.contains(name.toUpperCase())) {
    return 'This name is reserved by the OS.';
  }
  return null;
}

String? validateSubscriptionUrl(String url) {
  if (url.trim().isEmpty) return 'Enter a subscription URL.';
  if (normalizeHttpUri(url) == null) {
    return 'Enter an HTTP or HTTPS URL with a valid hostname.';
  }
  return null;
}
