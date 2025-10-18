import 'package_version.dart';

/// Represents a Dart package with all its versions
class Package {
  final String name;
  final bool isDiscontinued;
  final String? replacedBy;
  final DateTime? advisoriesUpdated;
  final PackageVersion? latest;
  final List<PackageVersion> versions;

  Package({
    required this.name,
    this.isDiscontinued = false,
    this.replacedBy,
    this.advisoriesUpdated,
    this.latest,
    required this.versions,
  });

  /// API Response json according to
  /// https://github.com/dart-lang/pub/blob/master/doc/repository-spec-v2.md#list-all-versions-of-a-package
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'name': name,
      'versions': versions.map((v) => v.toJson()).toList(),
    };

    if (isDiscontinued) {
      json['isDiscontinued'] = true;
    }

    if (replacedBy != null) {
      json['replacedBy'] = replacedBy;
    }

    if (advisoriesUpdated != null) {
      json['advisoriesUpdated'] = advisoriesUpdated!.toIso8601String();
    }

    if (latest != null) {
      json['latest'] = latest!.toJson();
    }

    return json;
  }
}
