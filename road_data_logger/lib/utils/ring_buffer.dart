import 'dart:math';

/// A high-performance, memory-bounded O(1) circular ring buffer designed
/// for high-frequency sensor streams (e.g. accelerometer 50-100Hz).
/// Eliminates O(N) array shifting (removeAt(0)) and prevents memory allocations.
class RingBuffer {
  final int capacity;
  late final List<double> _buffer;
  int _head = 0;
  int _count = 0;

  RingBuffer({this.capacity = 200}) {
    _buffer = List<double>.filled(capacity, 0.0);
  }

  /// Adds a sample into the circular buffer in O(1) time.
  void add(double value) {
    _buffer[_head] = value;
    _head = (_head + 1) % capacity;
    if (_count < capacity) {
      _count++;
    }
  }

  /// Current number of valid samples in buffer.
  int get length => _count;

  bool get isEmpty => _count == 0;
  bool get isNotEmpty => _count > 0;

  /// Calculates the standard deviation of current samples without clearing.
  double calculateRoughness() {
    if (_count == 0) return 0.0;

    double sum = 0.0;
    for (int i = 0; i < _count; i++) {
      sum += _buffer[i];
    }
    final double mean = sum / _count;

    double varianceSum = 0.0;
    for (int i = 0; i < _count; i++) {
      final double diff = _buffer[i] - mean;
      varianceSum += diff * diff;
    }

    final double variance = varianceSum / _count;
    return sqrt(variance);
  }

  /// Calculates standard deviation and resets sample count in O(1) time.
  double calculateRoughnessAndClear() {
    final double result = calculateRoughness();
    clear();
    return result;
  }

  /// Clears the ring buffer in O(1) time without reallocating memory.
  void clear() {
    _head = 0;
    _count = 0;
  }
}
