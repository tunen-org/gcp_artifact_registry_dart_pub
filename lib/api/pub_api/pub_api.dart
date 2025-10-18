import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../data/repositories/package_manager_repository/package_manager_repository.dart';
import '../../domain/models/error_response.dart';

class PubApi {
  PubApi(this._packageManagerRepository);

  final PackageManagerRepository _packageManagerRepository;

  Router buildRouter() {
    final router = Router();
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
}
