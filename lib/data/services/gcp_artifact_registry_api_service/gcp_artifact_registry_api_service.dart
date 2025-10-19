import 'dart:typed_data';

import 'package:googleapis/artifactregistry/v1.dart';
import 'package:logging/logging.dart';

import 'gcp_artifact_registry_service_exception.dart';

final _logger = Logger('GcpArtifactRegistryApiService');

class GcpArtifactRegistryApiService {
  GcpArtifactRegistryApiService({
    required ArtifactRegistryApi artifactRegistryApi,
    required String projectId,
    required String location,
    required String repository,
  }) : _artifactRegistryApi = artifactRegistryApi,
       _projectId = projectId,
       _location = location,
       _repository = repository;

  final ArtifactRegistryApi _artifactRegistryApi;
  final String _projectId;
  final String _location;
  final String _repository;

  /// Returns the parent path for the repository
  String get _parent =>
      'projects/$_projectId/locations/$_location/repositories/$_repository';

  /// Upload a generic artifact (Dart package) to Artifact Registry using Generic Artifacts API
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

      // Create an UploadGenericArtifactRequest with the package data
      final uploadRequest = UploadGenericArtifactRequest(
        packageId: packageName,
        versionId: version,
        filename: filename,
      );

      // The generic artifacts API expects the file content as the request body
      // We need to use the upload method from the generic artifacts resource
      final genericArtifactsResource =
          _artifactRegistryApi.projects.locations.repositories.genericArtifacts;

      _logger.info('Calling uploadGenericArtifact for $_parent');

      // Upload using the generic artifacts API
      final response = await genericArtifactsResource.upload(
        uploadRequest,
        _parent,
        uploadMedia: Media(
          Stream.value(archiveData.toList()),
          archiveData.length,
        ),
      );

      _logger.info(
        'Successfully uploaded artifact: $packageName@$version, response: ${response.toJson()}',
      );
    } catch (e, stackTrace) {
      _logger.severe('Error uploading artifact', e, stackTrace);
      if (e is ArtifactRegistryException) rethrow;
      throw ArtifactRegistryException(
        'Failed to upload artifact: $e',
        details: e,
      );
    }
  }

  /// Download a generic artifact from Artifact Registry using Files API
  ///
  /// Returns the artifact data as bytes
  Future<Uint8List> downloadArtifact({
    required String packageName,
    required String version,
    required String filename,
  }) async {
    try {
      _logger.info('Downloading artifact: $packageName@$version/$filename');

      // The file name in the Files API uses colons as separators
      final fileId = '$packageName:$version:$filename';
      final filePath = '$_parent/files/$fileId';

      _logger.info('Downloading file: $filePath');

      // Use the Files API to download
      final filesResource =
          _artifactRegistryApi.projects.locations.repositories.files;

      // Download the file with alt=media to get the raw content
      final media =
          await filesResource.download(
                filePath,
                downloadOptions: DownloadOptions.fullMedia,
              )
              as Media;

      // Read the media stream into bytes
      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }

      _logger.info(
        'Successfully downloaded artifact: $packageName@$version/$filename (${bytes.length} bytes)',
      );

      return Uint8List.fromList(bytes);
    } catch (e, stackTrace) {
      _logger.severe('Error downloading artifact', e, stackTrace);
      if (e is ArtifactRegistryException) rethrow;
      throw ArtifactRegistryException(
        'Failed to download artifact: $e',
        details: e,
      );
    }
  }

  /// List all versions of a package using Files API
  ///
  /// Returns a list of version strings
  Future<List<String>> listPackageVersions(String packageName) async {
    try {
      _logger.info('Listing versions for package: $packageName');

      final filesResource =
          _artifactRegistryApi.projects.locations.repositories.files;

      // List all files in the repository
      final response = await filesResource.list(_parent);

      _logger.info('Received ${response.files?.length ?? 0} files');

      // Extract version names from the files
      final versions = <String>{};

      if (response.files != null) {
        for (final file in response.files!) {
          // The owner field contains the package/version path:
          // e.g., "projects/.../packages/package-name/versions/1.0.0"
          final owner = file.owner ?? '';

          // Check if this file belongs to our package
          if (owner.contains('/packages/$packageName/versions/')) {
            // Extract version from owner path (last segment after /versions/)
            final segments = owner.split('/versions/');
            if (segments.length > 1) {
              final versionStr = segments.last;
              if (versionStr.isNotEmpty) {
                versions.add(versionStr);
              }
            }
          }
        }
      }

      _logger.info('Found ${versions.length} versions for $packageName');
      final sortedVersions = versions.toList()..sort();
      return sortedVersions;
    } catch (e, stackTrace) {
      _logger.severe('Error listing package versions', e, stackTrace);

      // If it's a 404, return empty list
      if (e.toString().contains('404')) {
        _logger.info('Repository or package not found: $packageName');
        return [];
      }

      if (e is ArtifactRegistryException) rethrow;
      throw ArtifactRegistryException(
        'Failed to list package versions: $e',
        details: e,
      );
    }
  }

  /// Check if a specific version of a package exists using Packages/Versions API
  Future<bool> packageVersionExists({
    required String packageName,
    required String version,
  }) async {
    try {
      final versionPath = '$_parent/packages/$packageName/versions/$version';

      final versionsResource = _artifactRegistryApi
          .projects
          .locations
          .repositories
          .packages
          .versions;

      // Try to get the version
      await versionsResource.get(versionPath);

      return true;
    } catch (e) {
      _logger.warning('Error checking package existence: $e');
      return false;
    }
  }

  /// Get artifact details using Packages/Versions API
  Future<Map<String, dynamic>?> getArtifactDetails({
    required String packageName,
    required String version,
  }) async {
    try {
      final versionPath = '$_parent/packages/$packageName/versions/$version';

      final versionsResource = _artifactRegistryApi
          .projects
          .locations
          .repositories
          .packages
          .versions;

      // Get the version details
      final versionObj = await versionsResource.get(versionPath);

      return {
        'name': versionObj.name,
        'createTime': versionObj.createTime,
        'updateTime': versionObj.updateTime,
        'description': versionObj.description,
        'metadata': versionObj.metadata,
      };
    } catch (e) {
      _logger.warning('Error getting artifact details: $e');
      return null;
    }
  }
}
