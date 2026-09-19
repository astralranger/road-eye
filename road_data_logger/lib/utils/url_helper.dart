class UrlHelper {
  /// Normalizes and cleans a user-provided server URL.
  /// Handles IP addresses, custom ports, Cloudflare tunnels, and trailing slashes.
  static String sanitize(String input) {
    String url = input.trim();
    if (url.isEmpty || url == "Not Set") return "Not Set";

    // Remove any trailing slashes
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    // If no scheme is provided, prepend http:// or https:// appropriately
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      if (url.contains('.trycloudflare.com') || url.contains('.workers.dev') || url.contains('.ts.net')) {
        url = 'https://$url';
      } else {
        url = 'http://$url';
      }
    }

    return url;
  }

  /// Strips protocol schemes for user-friendly display in text fields.
  static String toDisplayString(String url) {
    if (url == "Not Set" || url.isEmpty) return "";
    return url.replaceFirst(RegExp(r'^https?:\/\/'), '');
  }

  /// Validates whether a sanitized URL string is well-formed.
  static bool isValidUrl(String url) {
    if (url == "Not Set" || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.hasScheme && uri.hasAuthority;
  }

  /// Constructs the /detect endpoint URI safely.
  static Uri? getDetectUri(String baseUrl) {
    final sanitized = sanitize(baseUrl);
    if (!isValidUrl(sanitized)) return null;
    return Uri.tryParse('$sanitized/detect');
  }

  /// Constructs the /health endpoint URI safely.
  static Uri? getHealthUri(String baseUrl) {
    final sanitized = sanitize(baseUrl);
    if (!isValidUrl(sanitized)) return null;
    return Uri.tryParse('$sanitized/health');
  }

  /// Constructs the /api/v1/spatial/upload endpoint URI safely.
  static Uri? getUploadUri(String baseUrl) {
    final sanitized = sanitize(baseUrl);
    if (!isValidUrl(sanitized)) return null;
    return Uri.tryParse('$sanitized/api/v1/spatial/upload');
  }
}
