import 'package:googleapis_auth/auth_io.dart';
import 'package:logging/logging.dart';

final _logger = Logger('GoogleAuthService');

class GoogleAuthService {
  GoogleAuthService({required AutoRefreshingAuthClient authClient})
    : _authClient = authClient;

  final AutoRefreshingAuthClient _authClient;

  /// Get the current access token as a string
  ///
  /// Returns null if authentication fails
  String? getAuthToken() {
    try {
      return _authClient.credentials.accessToken.data;
    } catch (e, stackTrace) {
      _logger.severe('Failed to get auth token', e, stackTrace);
      return null;
    }
  }
}
