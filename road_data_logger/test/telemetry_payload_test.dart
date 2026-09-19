import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/models/telemetry_payload.dart';

void main() {
  group('TelemetryPayload Contract Tests', () {
    test('Serializes JSON structure strictly matching intelligent_server.py', () {
      const payload = TelemetryPayload(
        imageBase64: "AQIDBA==",
        gps: GpsData(
          lat: 18.5204,
          lon: 73.8567,
          speed: 12.5,
          heading: 90.0,
        ),
        instanceIp: "http://192.168.1.15:5000",
        roughness: 0.85,
        userId: "user_test_uuid_123",
        userEmail: "test@example.com",
      );

      final jsonStr = payload.toEncodedJson();
      final Map<String, dynamic> decoded = jsonDecode(jsonStr);

      // Verify all contract keys expected by backend DetectionRequest Pydantic schema
      expect(decoded.containsKey('image'), isTrue);
      expect(decoded.containsKey('gps'), isTrue);
      expect(decoded.containsKey('instance_ip'), isTrue);
      expect(decoded.containsKey('roughness'), isTrue);
      expect(decoded.containsKey('user_id'), isTrue);
      expect(decoded.containsKey('user_email'), isTrue);

      expect(decoded['image'], equals("AQIDBA=="));
      expect(decoded['roughness'], equals(0.85));
      expect(decoded['instance_ip'], equals("http://192.168.1.15:5000"));
      expect(decoded['user_id'], equals("user_test_uuid_123"));
      expect(decoded['user_email'], equals("test@example.com"));

      final Map<String, dynamic> gps = decoded['gps'];
      expect(gps['lat'], equals(18.5204));
      expect(gps['lon'], equals(73.8567));
      expect(gps['speed'], equals(12.5));
      expect(gps['heading'], equals(90.0));
    });
  });
}
