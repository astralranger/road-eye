import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/services/resilient_http_client.dart';

void main() {
  test('ResilientHttpClient resolves via DoH and fetches health endpoint', () async {
    final client = ResilientHttpClient.createClient();
    try {
      final resp = await client.get(Uri.parse('https://starship.tail454ce8.ts.net/health'));
      expect(resp.statusCode, 200);
      expect(resp.body, contains('"status":"ok"'));
    } finally {
      client.close();
    }
  });

  test('ResilientHttpClient handles standard IP address', () async {
    final client = ResilientHttpClient.createClient();
    try {
      final resp = await client.get(Uri.parse('http://127.0.0.1:8000/health'));
      expect(resp.statusCode, 200);
      expect(resp.body, contains('"status":"ok"'));
    } finally {
      client.close();
    }
  });
}
