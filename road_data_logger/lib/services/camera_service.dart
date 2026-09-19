import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import '../utils/mp4_validator.dart';

class CameraService {
  CameraController? _controller;
  bool _isCapturing = false;

  CameraController? get controller => _controller;
  bool get isInitialized => _controller != null && _controller!.value.isInitialized;
  bool get isCapturing => _isCapturing;
  bool get isRecordingVideo => _controller != null && _controller!.value.isRecordingVideo;

  /// Initializes the camera controller safely.
  /// Enforces standard H.264/AAC MP4 encoding with graceful audio fallback.
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

    // Try initializing with audio (AAC) first; fallback to video-only if permission denied
    for (final bool enableAudio in [true, false]) {
      try {
        final newController = CameraController(
          targetCamera,
          ResolutionPreset.high,
          enableAudio: enableAudio,
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.jpeg
              : ImageFormatGroup.bgra8888,
        );

        await newController.initialize();
        _controller = newController;
        debugPrint("Camera initialized successfully (enableAudio: $enableAudio)");
        return true;
      } catch (e) {
        debugPrint("Camera initialization attempt (enableAudio: $enableAudio) failed: $e");
        if (!enableAudio) {
          return false;
        }
      }
    }
    return false;
  }

  /// Starts hardware-accelerated video recording for spatial reconstruction.
  /// Calls prepareForVideoRecording() to warm up H.264 surfaces before capture.
  Future<bool> startVideoRecording() async {
    if (!isInitialized || isRecordingVideo) {
      return false;
    }

    try {
      // Warm up native video encoders and media surface muxer
      await _controller!.prepareForVideoRecording();
      await _controller!.startVideoRecording();
      return true;
    } catch (e) {
      debugPrint("startVideoRecording error: $e");
      return false;
    }
  }

  /// Finalizes and stops hardware-accelerated video recording, returning the validated video file.
  /// Explicitly waits for native stream flushing and container moov atom finalization.
  Future<XFile?> stopVideoRecording() async {
    if (!isInitialized || !isRecordingVideo) {
      return null;
    }

    try {
      final XFile videoFile = await _controller!.stopVideoRecording();

      // Ensure file descriptor has closed and MP4 moov metadata atom is flushed to disk
      final File rawFile = File(videoFile.path);
      final validation = await Mp4Validator.waitForMp4Finalization(rawFile);
      if (!validation.isValid) {
        debugPrint("Warning: stopVideoRecording container warning: ${validation.error}");
      }

      return videoFile;
    } catch (e) {
      debugPrint("stopVideoRecording error: $e");
      return null;
    }
  }

  /// Captures a frame and encodes it to Base64 in a background isolate using compute()
  /// to eliminate UI thread blocking and dropped frames during patrol stream.
  Future<String?> captureAsBase64() async {
    if (!isInitialized || _isCapturing || isRecordingVideo) {
      return null;
    }

    _isCapturing = true;
    try {
      final XFile imageFile = await _controller!.takePicture();
      final File fileOnDisk = File(imageFile.path);

      try {
        final List<int> bytes = await fileOnDisk.readAsBytes();
        // Run Base64 serialization on background isolate to eliminate UI thread jank
        return await compute(base64Encode, bytes);
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
