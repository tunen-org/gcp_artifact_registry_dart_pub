/// Exception thrown when GCP Artifact Registry operations fail
class ArtifactRegistryException implements Exception {
  final String message;
  final int? statusCode;
  final dynamic details;

  ArtifactRegistryException(this.message, {this.statusCode, this.details});

  @override
  String toString() =>
      'ArtifactRegistryException: $message'
      '${statusCode != null ? ' (Status: $statusCode)' : ''}'
      '${details != null ? ' - $details' : ''}';
}
