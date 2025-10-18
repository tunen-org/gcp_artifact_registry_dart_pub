/// Represents a specific version of a package
class PackageVersion {
  final String version;
  final String archiveUrl;
  final String? archiveSha256;
  final bool retracted;
  final Map<String, dynamic> pubspec;

  PackageVersion({
    required this.version,
    required this.archiveUrl,
    this.archiveSha256,
    this.retracted = false,
    required this.pubspec,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'version': version,
      'archive_url': archiveUrl,
      'pubspec': pubspec,
    };

    if (archiveSha256 != null) {
      json['archive_sha256'] = archiveSha256;
    }

    if (retracted) {
      json['retracted'] = true;
    }

    return json;
  }

  factory PackageVersion.fromJson(Map<String, dynamic> json) {
    return PackageVersion(
      version: json['version'] as String,
      archiveUrl: json['archive_url'] as String,
      archiveSha256: json['archive_sha256'] as String?,
      retracted: json['retracted'] as bool? ?? false,
      pubspec: json['pubspec'] as Map<String, dynamic>,
    );
  }
}
