import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/utils/ring_buffer.dart';

double naiveStdDev(List<double> values) {
  if (values.length < 2) return 0.0;
  final double mean = values.reduce((a, b) => a + b) / values.length;
  final double variance = values.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / values.length;
  return sqrt(variance);
}

void main() {
  group('RingBuffer O(1) Performance & Accuracy Tests', () {
    test('Empty and single element returns 0.0', () {
      final rb = RingBuffer(capacity: 10);
      expect(rb.calculateRoughness(), 0.0);
      rb.add(5.0);
      expect(rb.calculateRoughness(), 0.0);
    });

    test('Accurately matches statistical standard deviation under capacity', () {
      final rb = RingBuffer(capacity: 10);
      final samples = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];
      for (final s in samples) {
        rb.add(s);
      }

      final double expected = naiveStdDev(samples);
      final double actual = rb.calculateRoughness();
      expect((actual - expected).abs(), lessThan(1e-6));
    });

    test('Accurately maintains running moments after circular wrapping (capacity exceeded)', () {
      final rb = RingBuffer(capacity: 5);
      // Add 10 samples so first 5 are overwritten
      final allSamples = [1.0, 2.0, 3.0, 4.0, 5.0, 10.0, 20.0, 15.0, 12.0, 18.0];
      for (final s in allSamples) {
        rb.add(s);
      }

      final activeWindow = allSamples.sublist(5); // last 5 samples
      final double expected = naiveStdDev(activeWindow);
      final double actual = rb.calculateRoughness();
      expect((actual - expected).abs(), lessThan(1e-6));
    });

    test('calculateRoughnessAndClear clears in O(1) and resets moments', () {
      final rb = RingBuffer(capacity: 5);
      rb.add(10.0);
      rb.add(20.0);
      expect(rb.calculateRoughness(), greaterThan(0));

      final clearedVal = rb.calculateRoughnessAndClear();
      expect(clearedVal, greaterThan(0));
      expect(rb.length, 0);
      expect(rb.calculateRoughness(), 0.0);
    });
  });
}
