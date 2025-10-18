import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'gcp_artifact_registry_service_exception.dart';

final _logger = Logger('GcpArtifactRegistryService');

/// Provides the authentication header for API requests.
typedef AuthHeaderProvider = String? Function();

/// Provides the GCP project ID.
typedef ProjectIdProvider = String Function();

/// Provides the GCP location/region.
typedef LocationProvider = String Function();

/// Provides the Artifact Registry repository name.
typedef RepositoryProvider = String Function();

class GcpArtifactRegistryService {
  GcpArtifactRegistryService(this._client);

  final http.Client _client;

  AuthHeaderProvider? _authHeaderProvider;
  ProjectIdProvider? _projectIdProvider;
  LocationProvider? _locationProvider;
  RepositoryProvider? _repositoryProvider;

  set authHeaderProvider(AuthHeaderProvider provider) {
    _authHeaderProvider = provider;
  }

  set projectIdProvider(ProjectIdProvider provider) {
    _projectIdProvider = provider;
  }

  set locationProvider(LocationProvider provider) {
    _locationProvider = provider;
  }

  set repositoryProvider(RepositoryProvider provider) {
    _repositoryProvider = provider;
  }

  Map<String, String> _buildHeaders() {
    final headers = <String, String>{};
    final authHeader = _authHeaderProvider?.call();
    if (authHeader != null) {
      headers['Authorization'] = authHeader;
    }
    return headers;
  }

  String _getProjectId() {
    final projectId = _projectIdProvider?.call();
    if (projectId == null) {
      throw ArtifactRegistryException('Project ID provider not configured');
    }
    return projectId;
  }

  String _getLocation() {
    final location = _locationProvider?.call();
    if (location == null) {
      throw ArtifactRegistryException('Location provider not configured');
    }
    return location;
  }

  String _getRepository() {
    final repository = _repositoryProvider?.call();
    if (repository == null) {
      throw ArtifactRegistryException('Repository provider not configured');
    }
    return repository;
  }

  /// Upload a generic artifact (Dart package) to Artifact Registry
  ///
  /// Parameters:
  /// - [packageName]: Name of the Dart package (e.g., 'my_package')
  /// - [version]: Version string (e.g., '1.0.0')
  /// - [archiveData]: Compressed tar.gz package data
  /// - [filename]: Name of the archive file (e.g., 'package.tar.gz')
  Future<void> uploadArtifact({
    required String packageName,
    required String version,
    required Uint8List archiveData,
    required String filename,
  }) async {
    try {
      _logger.info('Uploading artifact: $packageName@$version');

      // Construct the upload URL
      final projectId = _getProjectId();
      final location = _getLocation();
      final repository = _getRepository();
      final parent =
          'projects/$projectId/locations/$location/repositories/$repository';
      final uploadUrl =
          'https://artifactregistry.googleapis.com/upload/v1/$parent/genericArtifacts:create?alt=json';

      // Create multipart request
      final request = http.MultipartRequest('POST', Uri.parse(uploadUrl));

      // Add authorization header
      request.headers.addAll(_buildHeaders());

      // Add metadata
      final metadata = {
        'filename': filename,
        'package_id': packageName,
        'version_id': version,
      };

      request.fields['meta'] = jsonEncode(metadata);

      // Add file data
      request.files.add(
        http.MultipartFile.fromBytes('blob', archiveData, filename: filename),
      );

      // Send request
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw ArtifactRegistryException(
          'Failed to upload artifact',
          statusCode: response.statusCode,
          details: response.body,
        );
      }

      _logger.info('Successfully uploaded artifact: $packageName@$version');
    } catch (e, stackTrace) {
      _logger.severe('Error uploading artifact', e, stackTrace);
      if (e is ArtifactRegistryException) rethrow;
      throw ArtifactRegistryException(
        'Failed to upload artifact: $e',
        details: e,
      );
    }
  }

  /// Download a generic artifact from Artifact Registry
  ///
  /// Returns the artifact data as bytes
  Future<Uint8List> downloadArtifact({
    required String packageName,
    required String version,
    required String filename,
  }) async {
    try {
      _logger.info('Downloading artifact: $packageName@$version/$filename');

      // Construct the download path
      final projectId = _getProjectId();
      final location = _getLocation();
      final repository = _getRepository();
      final parent =
          'projects/$projectId/locations/$location/repositories/$repository';
      final downloadUrl =
          'https://artifactregistry.googleapis.com/v1/$parent/genericArtifacts/$packageName:$version/$filename?alt=media';

      // Make download request
      final response = await _client.get(
        Uri.parse(downloadUrl),
        headers: _buildHeaders(),
      );

      if (response.statusCode != 200) {
        throw ArtifactRegistryException(
          'Failed to download artifact',
          statusCode: response.statusCode,
          details: response.body,
        );
      }

      _logger.info(
        'Successfully downloaded artifact: $packageName@$version/$filename',
      );
      return response.bodyBytes;
    } catch (e, stackTrace) {
      _logger.severe('Error downloading artifact', e, stackTrace);
      if (e is ArtifactRegistryException) rethrow;
      throw ArtifactRegistryException(
        'Failed to download artifact: $e',
        details: e,
      );
    }
  }

  /// List all versions of a package
  ///
  /// Returns a list of version strings
  Future<List<String>> listPackageVersions(String packageName) async {
    try {
      _logger.info('Listing versions for package: $packageName');

      // Use the Files API to list artifacts
      final projectId = _getProjectId();
      final location = _getLocation();
      final repository = _getRepository();
      final parent =
          'projects/$projectId/locations/$location/repositories/$repository';

      final url =
          'https://artifactregistry.googleapis.com/v1/$parent/files?filter=package_id="$packageName"';

      final response = await _client.get(
        Uri.parse(url),
        headers: _buildHeaders(),
      );

      if (response.statusCode != 200) {
        throw ArtifactRegistryException(
          'Failed to list package versions',
          statusCode: response.statusCode,
          details: response.body,
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      // Extract unique versions from the files
      final versions = <String>{};
      final files = json['files'] as List<dynamic>?;
      if (files != null) {
        for (final file in files) {
          // File names typically include version information
          // Parse version from metadata or name
          final name = file['name'] as String? ?? '';
          // Extract version from name pattern: packages/{package}/versions/{version}/...
          final versionMatch = RegExp(r'/versions/([^/]+)/').firstMatch(name);
          if (versionMatch != null) {
            versions.add(versionMatch.group(1)!);
          }
        }
      }

      _logger.info('Found ${versions.length} versions for $packageName');
      return versions.toList()..sort();
    } catch (e, stackTrace) {
      _logger.severe('Error listing package versions', e, stackTrace);
      if (e is ArtifactRegistryException) rethrow;
      throw ArtifactRegistryException(
        'Failed to list package versions: $e',
        details: e,
      );
    }
  }

  /// Check if a specific version of a package exists
  Future<bool> packageVersionExists({
    required String packageName,
    required String version,
  }) async {
    try {
      final versions = await listPackageVersions(packageName);
      return versions.contains(version);
    } catch (e) {
      _logger.warning('Error checking package existence: $e');
      return false;
    }
  }

  /// Get artifact details
  Future<Map<String, dynamic>?> getArtifactDetails({
    required String packageName,
    required String version,
  }) async {
    try {
      final projectId = _getProjectId();
      final location = _getLocation();
      final repository = _getRepository();
      final parent =
          'projects/$projectId/locations/$location/repositories/$repository';
      final filter = 'package_id="$packageName" AND version_id="$version"';

      final url =
          'https://artifactregistry.googleapis.com/v1/$parent/files?filter=$filter';

      final response = await _client.get(
        Uri.parse(url),
        headers: _buildHeaders(),
      );

      if (response.statusCode != 200) {
        _logger.warning('Failed to get artifact details: ${response.body}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final files = json['files'] as List<dynamic>?;

      if (files == null || files.isEmpty) {
        return null;
      }

      final file = files.first as Map<String, dynamic>;
      return {
        'name': file['name'],
        'size': file['sizeBytes'],
        'createTime': file['createTime'],
        'updateTime': file['updateTime'],
        'owner': file['owner'],
      };
    } catch (e) {
      _logger.warning('Error getting artifact details: $e');
      return null;
    }
  }
}
