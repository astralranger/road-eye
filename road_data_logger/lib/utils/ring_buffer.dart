import 'dart:math';

/// A high-performance, memory-bounded O(1) circular ring buffer designed
/// for high-frequency sensor streams (e.g. accelerometer 50-100Hz).
/// Eliminates O(N) array shifting (removeAt(0)) and prevents memory allocations.
class RingBuffer {
  final int capacity;
  late final List<double> _buffer;
  int _head = 0;
  int _count = 0;
  double _runningSum = 0.0;
  double _runningSumSquares = 0.0;

  RingBuffer({this.capacity = 200}) {
    _buffer = List<double>.filled(capacity, 0.0);
  }

  /// Adds a sample into the circular buffer in O(1) time and updates running moments.
  void add(double value) {
    if (_count == capacity) {
      final double oldValue = _buffer[_head];
      _runningSum -= oldValue;
      _runningSumSquares -= oldValue * oldValue;
    } else {
      _count++;
    }

    _buffer[_head] = value;
    _runningSum += value;
    _runningSumSquares += value * value;
    _head = (_head + 1) % capacity;
  }

  /// Current number of valid samples in buffer.
  int get length => _count;

  bool get isEmpty => _count == 0;
  bool get isNotEmpty => _count > 0;

  /// Calculates the standard deviation of current samples in O(1) time without looping.
  double calculateRoughness() {
    if (_count < 2) return 0.0;

    final double mean = _runningSum / _count;
    final double variance = (_runningSumSquares / _count) - (mean * mean);
    if (variance <= 0.0 || variance.isNaN) return 0.0;
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
    _runningSum = 0.0;
    _runningSumSquares = 0.0;
  }
}
