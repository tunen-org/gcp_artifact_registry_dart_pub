/// Response after successful package upload
class UploadSuccess {
  final String message;

  UploadSuccess({required this.message});

  Map<String, dynamic> toJson() {
    return {
      'success': {'message': message},
    };
  }
}
