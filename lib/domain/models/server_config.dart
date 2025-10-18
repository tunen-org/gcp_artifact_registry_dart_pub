/// Configuration for the package repository server
class ServerConfig {
  final String projectId;
  final String location;
  final String repository;
  final String host;
  final int port;
  final String baseUrl;

  ServerConfig({
    required this.projectId,
    required this.location,
    required this.repository,
    required this.host,
    required this.port,
    required this.baseUrl,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final server = json['server'] as Map<String, dynamic>? ?? {};
    final host = server['host'] as String? ?? '0.0.0.0';
    final port = server['port'] as int? ?? 8080;
    final baseUrl = server['base_url'] as String? ?? 'http://$host:$port';

    return ServerConfig(
      projectId: json['project_id'] as String,
      location: json['location'] as String,
      repository: json['repository'] as String,
      host: host,
      port: port,
      baseUrl: baseUrl,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'project_id': projectId,
      'location': location,
      'repository': repository,
      'server': {'host': host, 'port': port, 'base_url': baseUrl},
    };
  }
}
