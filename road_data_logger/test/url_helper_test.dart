import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/utils/url_helper.dart';

void main() {
  group('UrlHelper Tests', () {
    test('Sanitizes plain IP:port with http prefix', () {
      expect(UrlHelper.sanitize('192.168.1.50:5000'), equals('http://192.168.1.50:5000'));
      expect(UrlHelper.sanitize('10.0.2.2:5000/'), equals('http://10.0.2.2:5000'));
    });

    test('Preserves existing http and https protocols', () {
      expect(UrlHelper.sanitize('http://localhost:5000'), equals('http://localhost:5000'));
      expect(UrlHelper.sanitize('https://api.roadsense.org'), equals('https://api.roadsense.org'));
    });

    test('Automatically assigns https to Cloudflare tunnels', () {
      expect(
        UrlHelper.sanitize('pothole-demo.trycloudflare.com'),
        equals('https://pothole-demo.trycloudflare.com'),
      );
    });

    test('Handles Not Set and empty strings safely', () {
      expect(UrlHelper.sanitize('Not Set'), equals('Not Set'));
      expect(UrlHelper.sanitize(''), equals('Not Set'));
      expect(UrlHelper.isValidUrl('Not Set'), isFalse);
    });

    test('toDisplayString strips protocols cleanly', () {
      expect(UrlHelper.toDisplayString('http://192.168.1.20:5000'), equals('192.168.1.20:5000'));
      expect(UrlHelper.toDisplayString('https://myserver.com'), equals('myserver.com'));
      expect(UrlHelper.toDisplayString('Not Set'), equals(''));
    });

    test('getDetectUri appends /detect correctly', () {
      final uri = UrlHelper.getDetectUri('192.168.1.10:5000');
      expect(uri, isNotNull);
      expect(uri.toString(), equals('http://192.168.1.10:5000/detect'));
    });
  });
}
