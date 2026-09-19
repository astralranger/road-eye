import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class CameraService {
  CameraController? _controller;
  bool _isCapturing = false;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller != null && _controller!.value.isInitialized;
  bool get isCapturing => _isCapturing;

  /// Initializes the camera controller safely.
  Future<bool> initialize(CameraDescription? cameraDescription) async {
    CameraDescription? targetCamera = cameraDescription;

    if (targetCamera == null) {
      try {
        final cameras = await availableCameras();
        if (cameras.isNotEmpty) {
          targetCamera = cameras.first;
        }
      } catch (e) {
        debugPrint("Failed to query available cameras: $e");
      }
    }

    if (targetCamera == null) {
      debugPrint("No camera available on this device.");
      return false;
    }

    try {
      final newController = CameraController(
        targetCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.jpeg
            : ImageFormatGroup.bgra8888,
      );

      await newController.initialize();
      _controller = newController;
      return true;
    } catch (e) {
      debugPrint("Camera initialization error: $e");
      return false;
    }
  }

  /// Captures a frame and encodes it to Base64 with strict re-entrancy prevention
  /// and guaranteed immediate deletion of the temporary file from disk.
  Future<String?> captureAsBase64() async {
    if (!isInitialized || _isCapturing) {
      return null;
    }

    _isCapturing = true;
    try {
      final XFile imageFile = await _controller!.takePicture();
      final File fileOnDisk = File(imageFile.path);

      try {
        final List<int> bytes = await fileOnDisk.readAsBytes();
        return base64Encode(bytes);
      } finally {
        // Guaranteed disk cleanup to prevent storage exhaustion
        if (await fileOnDisk.exists()) {
          await fileOnDisk.delete().catchError((_) => fileOnDisk);
        }
      }
    } catch (e) {
      debugPrint("Camera capture error: $e");
      return null;
    } finally {
      _isCapturing = false;
    }
  }

  Future<void> dispose() async {
    try {
      await _controller?.dispose();
    } catch (e) {
      debugPrint("Error disposing camera controller: $e");
    } finally {
      _controller = null;
    }
  }
}
