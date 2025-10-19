import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

import '../../../domain/models/package.dart';
import '../../../domain/models/package_archive.dart';
import '../../../domain/models/package_version.dart';
import '../../services/gcp_artifact_registry_api_service/gcp_artifact_registry_api_service.dart';

final _logger = Logger('PackageManagerRepository');

class PackageManagerRepository {
  PackageManagerRepository({
    required GcpArtifactRegistryApiService gcpArtifactRegistryService,
    required String baseUrl,
  }) : _gcpArtifactRegistryService = gcpArtifactRegistryService,
       _baseUrl = baseUrl;

  final GcpArtifactRegistryApiService _gcpArtifactRegistryService;
  final String _baseUrl;

  /// Get all versions of a package
  Future<Package?> getPackage(String packageName) async {
    try {
      _logger.info('Getting package: $packageName');

      // Get all versions from Artifact Registry
      final versionStrings = await _gcpArtifactRegistryService
          .listPackageVersions(packageName);

      if (versionStrings.isEmpty) {
        _logger.info('Package not found: $packageName');
        return null;
      }

      // Build package versions
      final versions = <PackageVersion>[];
      PackageVersion? latestVersion;

      for (final versionString in versionStrings) {
        try {
          // Download the package to get pubspec
          final archiveData = await _gcpArtifactRegistryService
              .downloadArtifact(
                packageName: packageName,
                version: versionString,
                filename: '$packageName-$versionString.tar.gz',
              );

          // Extract pubspec from archive
          final pubspec = await _extractPubspecFromArchive(archiveData);

          // Calculate SHA256
          final sha256Hash = sha256.convert(archiveData).toString();

          // Build archive URL
          final archiveUrl =
              '$_baseUrl/packages/$packageName/versions/$versionString.tar.gz';

          final version = PackageVersion(
            version: versionString,
            archiveUrl: archiveUrl,
            archiveSha256: sha256Hash,
            pubspec: pubspec,
          );

          versions.add(version);

          // Track latest version (simple semver comparison)
          if (latestVersion == null ||
              _isNewerVersion(versionString, latestVersion.version)) {
            latestVersion = version;
          }
        } catch (e) {
          _logger.warning('Failed to process version $versionString: $e');
        }
      }

      if (versions.isEmpty) {
        return null;
      }

      return Package(
        name: packageName,
        versions: versions,
        latest: latestVersion,
      );
    } catch (e, stackTrace) {
      _logger.severe('Error getting package', e, stackTrace);
      throw Exception('Failed to get package: $e');
    }
  }

  /// Publish a package
  Future<void> publishPackage(PackageArchive archive) async {
    try {
      _logger.info(
        'Publishing package: ${archive.packageName}@${archive.version}',
      );

      // Validate package doesn't already exist
      final exists = await _gcpArtifactRegistryService.packageVersionExists(
        packageName: archive.packageName,
        version: archive.version,
      );

      if (exists) {
        throw Exception(
          'Version ${archive.version} of package ${archive.packageName} already exists',
        );
      }

      // Upload to Artifact Registry
      await _gcpArtifactRegistryService.uploadArtifact(
        packageName: archive.packageName,
        version: archive.version,
        archiveData: Uint8List.fromList(archive.data),
        filename: '${archive.packageName}-${archive.version}.tar.gz',
      );

      _logger.info(
        'Successfully published package: ${archive.packageName}@${archive.version}',
      );
    } catch (e, stackTrace) {
      _logger.severe('Error publishing package', e, stackTrace);
      throw Exception('Failed to publish package: $e');
    }
  }

  /// Download a package archive
  Future<Uint8List?> downloadPackageArchive({
    required String packageName,
    required String version,
  }) async {
    try {
      _logger.info('Downloading package archive: $packageName@$version');

      // Download from Artifact Registry
      final archiveData = await _gcpArtifactRegistryService.downloadArtifact(
        packageName: packageName,
        version: version,
        filename: '$packageName-$version.tar.gz',
      );

      _logger.info(
        'Successfully downloaded package archive: $packageName@$version (${archiveData.length} bytes)',
      );

      return archiveData;
    } catch (e, stackTrace) {
      _logger.warning('Error downloading package archive: $e', e, stackTrace);
      return null;
    }
  }

  /// Extract and parse pubspec.yaml from a tar.gz archive
  Future<Map<String, dynamic>> _extractPubspecFromArchive(
    List<int> archiveData,
  ) async {
    try {
      // Decode gzip
      final gzipDecoded = GZipDecoder().decodeBytes(archiveData);

      // Decode tar
      final tarArchive = TarDecoder().decodeBytes(gzipDecoded);

      // Find pubspec.yaml
      for (final file in tarArchive.files) {
        if (file.name.endsWith('pubspec.yaml')) {
          final content = utf8.decode(file.content as List<int>);
          final yaml = loadYaml(content);

          // Convert YamlMap to regular Map
          return _yamlToJson(yaml) as Map<String, dynamic>;
        }
      }

      throw Exception('pubspec.yaml not found in archive');
    } catch (e) {
      _logger.warning('Error extracting pubspec: $e');
      throw Exception('Failed to extract pubspec.yaml: $e');
    }
  }

  /// Convert YAML to JSON-compatible Map
  dynamic _yamlToJson(dynamic yaml) {
    if (yaml is YamlMap) {
      return Map.fromEntries(
        yaml.entries.map(
          (e) => MapEntry(e.key.toString(), _yamlToJson(e.value)),
        ),
      );
    } else if (yaml is YamlList) {
      return yaml.map(_yamlToJson).toList();
    } else {
      return yaml;
    }
  }

  /// Simple version comparison (newer if lexicographically greater)
  /// For production, use proper semantic versioning
  bool _isNewerVersion(String v1, String v2) {
    final parts1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    for (var i = 0; i < 3; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;

      if (p1 > p2) return true;
      if (p1 < p2) return false;
    }

    return false;
  }

  /// Parse package archive and extract metadata
  Future<PackageArchive> parsePackageArchive(List<int> archiveData) async {
    try {
      // Extract pubspec
      final pubspec = await _extractPubspecFromArchive(archiveData);

      final packageName = pubspec['name'] as String?;
      final version = pubspec['version'] as String?;

      if (packageName == null || version == null) {
        throw Exception('Invalid pubspec: missing name or version');
      }

      return PackageArchive(
        packageName: packageName,
        version: version,
        pubspec: pubspec,
        data: archiveData,
      );
    } catch (e) {
      throw Exception('Failed to parse package archive: $e');
    }
  }
}
