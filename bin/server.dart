import 'dart:io';

import 'package:gcp_artifact_repository_dart/api/pub_api/pub_api.dart';
import 'package:gcp_artifact_repository_dart/data/repositories/package_manager_repository/package_manager_repository.dart';
import 'package:gcp_artifact_repository_dart/data/services/gcp_artifact_registry_service/gcp_artifact_registry_service.dart';
import 'package:gcp_artifact_repository_dart/data/services/google_auth_service/google_auth_service.dart';
import 'package:gcp_artifact_repository_dart/domain/models/server_config.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

void main(List<String> args) async {
  // Setup logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    print(
      '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}',
    );
    if (record.error != null) {
      print('Error: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('Stack trace: ${record.stackTrace}');
    }
  });

  // Config (needs to be restarted on change)
  final projectId = Platform.environment['GCP_PROJECT'];
  final location = Platform.environment['GCP_LOCATION'];
  final repository = Platform.environment['GCP_REPOSITORY'];
  final host = Platform.environment['HOST'] ?? '0.0.0.0';
  final port = int.tryParse(Platform.environment['PORT'] ?? '8080') ?? 8080;
  final baseUrl = Platform.environment['BASE_URL'] ?? 'http://$host:$port';

  if (projectId == null || location == null || repository == null) {
    stderr.writeln(
      'Error: GCP_PROJECT, GCP_LOCATION, and GCP_REPOSITORY environment variables must be set.',
    );
    exit(1);
  }

  final config = ServerConfig(
    projectId: projectId,
    location: location,
    repository: repository,
    host: host,
    port: port,
    baseUrl: baseUrl,
  );

  // Dependencies
  // Try Application Default Credentials first (works on Cloud Run)
  final authClient = await clientViaApplicationDefaultCredentials(
    scopes: _scopes,
  );
  final httpClient = http.Client();
  final gcpArtifactRegistryService = GcpArtifactRegistryService(
    client: httpClient,
    projectId: config.projectId,
    location: config.location,
    repository: config.repository,
  );
  final googleAuthService = GoogleAuthService(authClient: authClient);
  final packageManagerRepository = PackageManagerRepository(
    gcpArtifactRegistryService: gcpArtifactRegistryService,
    googleAuthService: googleAuthService,
    baseUrl: config.baseUrl,
  );
  final api = PubApi(
    packageManagerRepository: packageManagerRepository,
    baseUrl: config.baseUrl,
  );

  // Configure a pipeline
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(api.apiVersionMiddleware())
      .addMiddleware(_corsMiddleware())
      .addHandler(api.buildRouter().call);

  // Start server
  final server = await serve(handler, config.host, config.port);

  // Handle graceful shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    print("Shutting down server");
    await server.close();
    httpClient.close();
    authClient.close();
    print("Server shut down");
    exit(0);
  });

  print('Server listening on port ${server.port}');
}

/// CORS middleware for browser access
Middleware _corsMiddleware() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }

      final response = await handler(request);
      return response.change(headers: _corsHeaders);
    };
  };
}

final _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Origin, Content-Type, Accept, Authorization',
};

const _scopes = ['https://www.googleapis.com/auth/cloud-platform'];
