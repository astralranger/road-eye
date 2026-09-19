import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/utils/ring_buffer.dart';

void main() {
  group('RingBuffer Tests', () {
    test('Empty ring buffer returns 0.0 roughness', () {
      final buffer = RingBuffer(capacity: 5);
      expect(buffer.isEmpty, isTrue);
      expect(buffer.length, equals(0));
      expect(buffer.calculateRoughness(), equals(0.0));
      expect(buffer.calculateRoughnessAndClear(), equals(0.0));
    });

    test('Ring buffer computes accurate standard deviation', () {
      final buffer = RingBuffer(capacity: 10);
      // Sample values: 2, 4, 4, 4, 5, 5, 7, 9
      // Mean = 5, Variance = 4, StdDev = 2.0
      final values = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];
      for (final v in values) {
        buffer.add(v);
      }

      expect(buffer.length, equals(8));
      expect(buffer.calculateRoughness(), closeTo(2.0, 0.0001));
    });

    test('Circular wrapping does not exceed capacity', () {
      final buffer = RingBuffer(capacity: 3);
      buffer.add(10.0);
      buffer.add(20.0);
      buffer.add(30.0);
      expect(buffer.length, equals(3));

      // Overwrite first two
      buffer.add(40.0);
      buffer.add(50.0);
      expect(buffer.length, equals(3));

      // Buffer contents should now represent 30.0, 40.0, 50.0
      // Mean = 40.0, Variance = (100 + 0 + 100) / 3 = 66.6667, StdDev = sqrt(66.6667) ≈ 8.1649
      expect(buffer.calculateRoughness(), closeTo(sqrt(200.0 / 3.0), 0.001));
    });

    test('calculateRoughnessAndClear resets count without deallocating', () {
      final buffer = RingBuffer(capacity: 5);
      buffer.add(5.0);
      buffer.add(15.0);
      expect(buffer.length, equals(2));

      final roughness = buffer.calculateRoughnessAndClear();
      expect(roughness, closeTo(5.0, 0.001));
      expect(buffer.length, equals(0));
      expect(buffer.isEmpty, isTrue);
    });
  });
}
