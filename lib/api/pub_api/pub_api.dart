import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../data/repositories/package_manager_repository/package_manager_repository.dart';
import '../../domain/models/error_response.dart';
import '../../domain/models/package_archive.dart';
import '../../domain/models/upload_info.dart';
import '../../domain/models/upload_sucess.dart';

final _logger = Logger('PubApi');

class PubApi {
  PubApi({
    required PackageManagerRepository packageManagerRepository,
    required String baseUrl,
  }) : _packageManagerRepository = packageManagerRepository,
       _baseUrl = baseUrl;

  final PackageManagerRepository _packageManagerRepository;
  final String _baseUrl;

  // Storage for multi-part upload sessions
  final Map<String, PackageArchive> _uploadSessions = {};

  Router buildRouter() {
    final router = Router();

    // List all versions of a package
    router.get('/api/packages/<package>', _listPackageVersions);

    // Deprecated: Get specific package version (for backward compatibility)
    router.get(
      '/api/packages/<package>/versions/<version>',
      _getPackageVersion,
    );

    // Initiate package publishing
    router.get('/api/packages/versions/new', _initiatePublish);

    // Upload package archive
    router.post('/api/packages/versions/newUpload', _uploadPackage);

    // Finalize package upload
    router.get('/api/packages/versions/newUploadFinish', _finalizeUpload);

    // Download package archive (deprecated but supported)
    router.get(
      '/packages/<package>/versions/<version>.tar.gz',
      _downloadPackage,
    );

    return router;
  }

  /// Middleware to ensure correct Accept headers
  Middleware apiVersionMiddleware() {
    return (Handler handler) {
      return (Request request) async {
        // Check for proper Accept header
        final accept = request.headers['accept'] ?? '';

        if (!accept.contains('application/vnd.pub.v2+json') &&
            !accept.contains('application/octet-stream') &&
            !accept.isEmpty) {
          return Response(
            406,
            body: jsonEncode(
              ErrorResponse(
                code: 'invalid_accept',
                message: 'This server only supports API version 2',
              ).toJson(),
            ),
            headers: {'Content-Type': 'application/vnd.pub.v2+json'},
          );
        }

        final response = await handler(request);

        // Add API version header to responses
        return response.change(
          headers: {
            'Content-Type':
                response.headers['Content-Type'] ??
                'application/vnd.pub.v2+json',
          },
        );
      };
    };
  }

  /// GET /api/packages/<package>
  /// List all versions of a package
  Future<Response> _listPackageVersions(Request request, String package) async {
    try {
      _logger.info('Listing versions for package: $package');

      final packageData = await _packageManagerRepository.getPackage(package);

      if (packageData == null) {
        return _errorResponse(404, 'not_found', 'Package "$package" not found');
      }

      return Response.ok(
        jsonEncode(packageData.toJson()),
        headers: {'Content-Type': 'application/vnd.pub.v2+json'},
      );
    } catch (e, stackTrace) {
      _logger.severe('Error listing package versions', e, stackTrace);
      return _errorResponse(
        500,
        'internal_error',
        'Failed to retrieve package information: $e',
      );
    }
  }

  /// GET /api/packages/<package>/versions/<version>
  /// Get specific package version (deprecated but supported)
  Future<Response> _getPackageVersion(
    Request request,
    String package,
    String version,
  ) async {
    try {
      _logger.info('Getting package version: $package@$version');

      final packageVersion = await _packageManagerRepository.getPackageVersion(
        package,
        version,
      );

      if (packageVersion == null) {
        return _errorResponse(
          404,
          'not_found',
          'Package "$package" version "$version" not found',
        );
      }

      return Response.ok(
        jsonEncode(packageVersion.toJson()),
        headers: {'Content-Type': 'application/vnd.pub.v2+json'},
      );
    } catch (e, stackTrace) {
      _logger.severe('Error getting package version', e, stackTrace);
      return _errorResponse(
        500,
        'internal_error',
        'Failed to retrieve package version: $e',
      );
    }
  }

  /// GET /api/packages/versions/new
  /// Initiate package publishing
  Future<Response> _initiatePublish(Request request) async {
    try {
      _logger.info('Initiating package publish');

      // Check for authorization (in GCP environment, this would be validated)
      final auth = request.headers['authorization'];
      if (auth == null || !auth.startsWith('Bearer ')) {
        return Response(
          401,
          headers: {
            'WWW-Authenticate':
                'Bearer realm="pub", message="Authentication required. '
                'In GCP environments, use gcloud credentials."',
          },
        );
      }

      // Generate upload URL
      final uploadInfo = UploadInfo(
        url: '$_baseUrl/api/packages/versions/newUpload',
        fields: {'session': _generateSessionId()},
      );

      return Response.ok(
        jsonEncode(uploadInfo.toJson()),
        headers: {'Content-Type': 'application/vnd.pub.v2+json'},
      );
    } catch (e, stackTrace) {
      _logger.severe('Error initiating publish', e, stackTrace);
      return _errorResponse(
        500,
        'internal_error',
        'Failed to initiate package publishing: $e',
      );
    }
  }

  /// POST /api/packages/versions/newUpload
  /// Upload package archive
  Future<Response> _uploadPackage(Request request) async {
    try {
      _logger.info('Uploading package');

      final contentType = request.headers['content-type'] ?? '';
      if (!contentType.contains('multipart/form-data')) {
        return _errorResponse(
          400,
          'invalid_content_type',
          'Content-Type must be multipart/form-data',
        );
      }

      // Read the entire body
      final bytes = await request.read().expand((chunk) => chunk).toList();

      // Extract the boundary from content-type
      final boundary = _extractBoundary(contentType);
      if (boundary == null) {
        return _errorResponse(
          400,
          'invalid_content_type',
          'Missing boundary in Content-Type',
        );
      }

      // Parse multipart data
      final parts = _parseMultipartData(bytes, boundary);

      // Get session ID
      final sessionId = parts['session'] ?? _generateSessionId();

      // Get file data
      final fileData = parts['file'];
      if (fileData == null) {
        return _errorResponse(
          400,
          'missing_file',
          'Package archive file is required',
        );
      }

      // Parse the package archive
      final archive = await _packageManagerRepository.parsePackageArchive(
        fileData is String ? utf8.encode(fileData) : fileData as List<int>,
      );

      // Store the package archive in session
      _uploadSessions[sessionId] = archive;

      // Return 204 with finalize URL
      final finalizeUrl =
          '$_baseUrl/api/packages/versions/newUploadFinish?session=$sessionId';

      return Response(204, headers: {'Location': finalizeUrl});
    } catch (e, stackTrace) {
      _logger.severe('Error uploading package', e, stackTrace);
      return _errorResponse(
        400,
        'upload_error',
        'Failed to upload package: $e',
      );
    }
  }

  /// GET /api/packages/versions/newUploadFinish
  /// Finalize package upload
  Future<Response> _finalizeUpload(Request request) async {
    try {
      _logger.info('Finalizing package upload');

      // Get session ID
      final sessionId = request.url.queryParameters['session'];
      if (sessionId == null) {
        return _errorResponse(400, 'missing_session', 'Session ID is required');
      }

      // Get package archive from session
      final archive = _uploadSessions[sessionId];
      if (archive == null) {
        return _errorResponse(
          404,
          'session_not_found',
          'Upload session not found',
        );
      }

      // Publish the package
      await _packageManagerRepository.publishPackage(archive);

      // Clean up session
      _uploadSessions.remove(sessionId);

      // Return success
      final success = UploadSuccess(
        message:
            'Successfully published ${archive.packageName} version ${archive.version}',
      );

      return Response.ok(
        jsonEncode(success.toJson()),
        headers: {'Content-Type': 'application/vnd.pub.v2+json'},
      );
    } catch (e, stackTrace) {
      _logger.severe('Error finalizing upload', e, stackTrace);
      return _errorResponse(
        400,
        'publish_error',
        'Failed to publish package: $e',
      );
    }
  }

  /// GET /packages/<package>/versions/<version>.tar.gz
  /// Download package archive (deprecated but supported)
  Future<Response> _downloadPackage(
    Request request,
    String package,
    String version,
  ) async {
    try {
      _logger.info('Downloading package: $package@$version');

      final archiveData = await _packageManagerRepository
          .downloadPackageArchive(package, version);

      return Response.ok(
        archiveData,
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Disposition':
              'attachment; filename="$package-$version.tar.gz"',
        },
      );
    } catch (e, stackTrace) {
      _logger.severe('Error downloading package', e, stackTrace);
      return _errorResponse(404, 'not_found', 'Package not found: $e');
    }
  }

  /// Create an error response
  Response _errorResponse(int statusCode, String code, String message) {
    final error = ErrorResponse(code: code, message: message);
    return Response(
      statusCode,
      body: jsonEncode(error.toJson()),
      headers: {'Content-Type': 'application/vnd.pub.v2+json'},
    );
  }

  /// Generate a unique session ID
  String _generateSessionId() {
    return DateTime.now().millisecondsSinceEpoch.toString() +
        '_' +
        (DateTime.now().microsecond % 1000).toString();
  }

  /// Extract boundary from Content-Type header
  String? _extractBoundary(String contentType) {
    final match = RegExp(r'boundary=([^;]+)').firstMatch(contentType);
    return match?.group(1);
  }

  /// Parse multipart form data
  Map<String, dynamic> _parseMultipartData(List<int> data, String boundary) {
    final parts = <String, dynamic>{};
    final boundaryBytes = utf8.encode('--$boundary');
    final dataString = utf8.decode(data, allowMalformed: true);

    // Split by boundary
    final sections = dataString.split('--$boundary');

    for (final section in sections) {
      if (section.trim().isEmpty || section.trim() == '--') continue;

      // Parse headers and content
      final lines = section.split('\r\n');
      String? name;
      var contentStart = 0;

      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.toLowerCase().contains('content-disposition')) {
          final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(line);
          name = nameMatch?.group(1);
        }
        if (line.isEmpty) {
          contentStart = i + 1;
          break;
        }
      }

      if (name != null) {
        // Get content (everything after headers)
        final content = lines.skip(contentStart).join('\r\n').trim();

        if (name == 'file') {
          // For file, we need the raw bytes
          parts[name] = data;
        } else {
          parts[name] = content;
        }
      }
    }

    return parts;
  }
}
