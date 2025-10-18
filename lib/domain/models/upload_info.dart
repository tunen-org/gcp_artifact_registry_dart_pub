/// Upload information for package publishing
class UploadInfo {
  final String url;
  final Map<String, String> fields;

  UploadInfo({required this.url, required this.fields});

  Map<String, dynamic> toJson() {
    return {'url': url, 'fields': fields};
  }
}
