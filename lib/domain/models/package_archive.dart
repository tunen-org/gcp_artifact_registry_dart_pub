/// Package archive metadata extracted from tar.gz
class PackageArchive {
  final String packageName;
  final String version;
  final Map<String, dynamic> pubspec;
  final List<int> data;

  PackageArchive({
    required this.packageName,
    required this.version,
    required this.pubspec,
    required this.data,
  });
}
