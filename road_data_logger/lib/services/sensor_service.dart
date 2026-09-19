import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../utils/ring_buffer.dart';

class SensorService {
  final RingBuffer _ringBuffer = RingBuffer(capacity: 200);

  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription<Position>? _gpsSub;

  final ValueNotifier<Position?> positionNotifier = ValueNotifier<Position?>(null);
  final ValueNotifier<double> speedKmhNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<double> roughnessNotifier = ValueNotifier<double>(0.0);

  Position? get currentPosition => positionNotifier.value;
  double get currentSpeedKmh => speedKmhNotifier.value;
  double get currentRoughness => roughnessNotifier.value;

  /// Starts listening to accelerometer and GPS streams.
  void start() {
    stop();

    // 1. Accelerometer Stream for Vibration Analysis
    _accelSub = userAccelerometerEventStream().listen((event) {
      _ringBuffer.add(event.z);
      final roughness = _ringBuffer.calculateRoughness();
      roughnessNotifier.value = roughness;
    });

    // 2. High-Accuracy GPS Stream
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );

    _gpsSub = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) {
      // Discard inaccurate GPS readings to prevent drift
      if (position.accuracy > 20.0) return;

      positionNotifier.value = position;
      speedKmhNotifier.value = position.speed > 0 ? (position.speed * 3.6) : 0.0;
    });
  }

  /// Calculates sample standard deviation and clears window for the next transmission cycle.
  double getRoughnessAndReset() {
    final val = _ringBuffer.calculateRoughnessAndClear();
    roughnessNotifier.value = 0.0;
    return val;
  }

  /// Stops all active hardware streams.
  void stop() {
    _accelSub?.cancel();
    _accelSub = null;
    _gpsSub?.cancel();
    _gpsSub = null;
    _ringBuffer.clear();
  }

  void dispose() {
    stop();
    positionNotifier.dispose();
    speedKmhNotifier.dispose();
    roughnessNotifier.dispose();
  }
}
