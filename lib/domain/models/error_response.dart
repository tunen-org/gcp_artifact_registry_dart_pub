/// Error response
class ErrorResponse {
  final String code;
  final String message;

  ErrorResponse({required this.code, required this.message});

  Map<String, dynamic> toJson() {
    return {
      'error': {'code': code, 'message': message},
    };
  }
}
