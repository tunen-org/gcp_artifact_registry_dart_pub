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

    // Initiate package publishing
    router.get('/api/packages/versions/new', _initiatePublish);

    // Upload package archive
    router.post('/api/packages/versions/newUpload', _uploadPackage);

    // Finalize package upload
    router.get('/api/packages/versions/newUploadFinish', _finalizeUpload);

    // Deprecated: Download package archive directly
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

        // Skip Accept header validation for:
        // - POST requests (multipart uploads don't send Accept headers)
        // - Requests without Accept header (be lenient)
        // - Requests with valid Accept headers
        final skipValidation =
            request.method == 'POST' ||
            accept.isEmpty ||
            accept.contains('application/vnd.pub.v2+json') ||
            accept.contains('application/octet-stream') ||
            accept.contains('*/*');

        if (!skipValidation) {
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

        // Add API version header to JSON responses
        if (response.headers['Content-Type']?.contains('json') ?? false) {
          return response.change(
            headers: {'Content-Type': 'application/vnd.pub.v2+json'},
          );
        }

        return response;
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

  /// GET /api/packages/versions/new
  /// Initiate package publishing
  Future<Response> _initiatePublish(Request request) async {
    try {
      _logger.info('Initiating package publish');

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
      _logger.info('Content-Type: $contentType');

      if (!contentType.contains('multipart/form-data')) {
        return _errorResponse(
          400,
          'invalid_content_type',
          'Content-Type must be multipart/form-data',
        );
      }

      // Read the entire body
      final bytes = await request.read().expand((chunk) => chunk).toList();
      _logger.info('Received ${bytes.length} bytes');

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
      _logger.info('Session ID: $sessionId');

      // Get file data
      final fileData = parts['file'];
      if (fileData == null) {
        _logger.warning(
          'No file data found in multipart. Parts: ${parts.keys}',
        );
        return _errorResponse(
          400,
          'missing_file',
          'Package archive file is required',
        );
      }

      final fileBytes = fileData as List<int>;
      _logger.info('File data size: ${fileBytes.length} bytes');

      // Parse the package archive
      final archive = await _packageManagerRepository.parsePackageArchive(
        fileBytes,
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
  /// Download package archive (deprecated endpoint, but still used by pub client)
  Future<Response> _downloadPackage(
    Request request,
    String package,
    String version,
  ) async {
    try {
      _logger.info('Downloading package: $package@$version');

      // Download the package archive
      final archiveData = await _packageManagerRepository
          .downloadPackageArchive(packageName: package, version: version);

      if (archiveData == null) {
        return _errorResponse(
          404,
          'not_found',
          'Package "$package" version "$version" not found',
        );
      }

      // Return the archive data
      return Response.ok(
        archiveData,
        headers: {'Content-Type': 'application/octet-stream'},
      );
    } catch (e, stackTrace) {
      _logger.severe('Error downloading package', e, stackTrace);
      return _errorResponse(
        500,
        'internal_error',
        'Failed to download package: $e',
      );
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
    return '${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond % 1000}';
  }

  /// Extract boundary from Content-Type header
  String? _extractBoundary(String contentType) {
    final match = RegExp(r'boundary=([^;]+)').firstMatch(contentType);
    return match?.group(1);
  }

  /// Parse multipart form data
  Map<String, dynamic> _parseMultipartData(List<int> data, String boundary) {
    final parts = <String, dynamic>{};
    final boundaryMarker = utf8.encode('--$boundary');

    // Find all boundary positions
    var pos = 0;
    while (pos < data.length) {
      // Look for boundary
      final boundaryPos = _findBytes(data, boundaryMarker, pos);
      if (boundaryPos == -1) break;

      // Move past boundary and CRLF
      pos = boundaryPos + boundaryMarker.length;

      // Skip CRLF after boundary
      if (pos + 2 <= data.length && data[pos] == 13 && data[pos + 1] == 10) {
        pos += 2;
      }

      // Find the end of headers (double CRLF)
      final headersEnd = _findBytes(data, utf8.encode('\r\n\r\n'), pos);
      if (headersEnd == -1) continue;

      // Extract and parse headers
      final headerBytes = data.sublist(pos, headersEnd);
      final headerText = utf8.decode(headerBytes);
      final headers = headerText.split('\r\n');

      String? name;
      for (final header in headers) {
        if (header.toLowerCase().contains('content-disposition')) {
          final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(header);
          name = nameMatch?.group(1);
          break;
        }
      }

      if (name == null) continue;

      // Content starts after double CRLF
      final contentStart = headersEnd + 4;

      // Find next boundary
      final nextBoundaryPos = _findBytes(data, boundaryMarker, contentStart);
      if (nextBoundaryPos == -1) break;

      // Content ends before the CRLF before the next boundary
      var contentEnd = nextBoundaryPos;
      // Remove trailing CRLF before boundary
      if (contentEnd >= 2 &&
          data[contentEnd - 2] == 13 &&
          data[contentEnd - 1] == 10) {
        contentEnd -= 2;
      }

      // Extract content
      final contentBytes = data.sublist(contentStart, contentEnd);

      if (name == 'file') {
        // For file, store raw bytes
        parts[name] = contentBytes;
      } else {
        // For text fields, decode as UTF-8
        parts[name] = utf8.decode(contentBytes);
      }

      pos = nextBoundaryPos;
    }

    return parts;
  }

  /// Find a byte sequence in a list of bytes
  int _findBytes(List<int> data, List<int> pattern, int start) {
    if (pattern.isEmpty) return -1;

    for (var i = start; i <= data.length - pattern.length; i++) {
      var found = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }

    return -1;
  }
}
