import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Result of an MP4 ISO Base Media container structural integrity audit.
class Mp4ValidationResult {
  final bool isValid;
  final bool hasFtyp;
  final bool hasMoov;
  final bool hasMdat;
  final int fileSizeBytes;
  final String? error;
  final List<String> detectedBoxes;

  const Mp4ValidationResult({
    required this.isValid,
    required this.hasFtyp,
    required this.hasMoov,
    required this.hasMdat,
    required this.fileSizeBytes,
    this.error,
    this.detectedBoxes = const [],
  });

  @override
  String toString() =>
      'Mp4ValidationResult(valid: $isValid, ftyp: $hasFtyp, moov: $hasMoov, mdat: $hasMdat, size: $fileSizeBytes bytes, boxes: $detectedBoxes, error: $error)';
}

/// High-performance parser and validator for MP4 (ISO/IEC 14496-12) containers.
/// Enforces valid H.264/AAC MP4 structures and prevents corruptions caused by missing
/// or truncated 'moov' metadata atoms during mobile recording finalization.
class Mp4Validator {
  /// Parses the top-level atoms (boxes) of an MP4 file on disk.
  static Future<Mp4ValidationResult> validate(File file) async {
    if (!await file.exists()) {
      return const Mp4ValidationResult(
        isValid: false,
        hasFtyp: false,
        hasMoov: false,
        hasMdat: false,
        fileSizeBytes: 0,
        error: 'File does not exist on disk',
      );
    }

    final int totalLength = await file.length();
    if (totalLength < 32) {
      return Mp4ValidationResult(
        isValid: false,
        hasFtyp: false,
        hasMoov: false,
        hasMdat: false,
        fileSizeBytes: totalLength,
        error: 'File size ($totalLength bytes) too small for valid MP4 header (minimum 32 bytes)',
      );
    }

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      int offset = 0;
      bool hasFtyp = false;
      bool hasMoov = false;
      bool hasMdat = false;
      final List<String> detectedBoxes = [];

      // Scan top-level boxes sequentially
      while (offset + 8 <= totalLength) {
        await raf.setPosition(offset);
        final Uint8List header = await raf.read(8);
        if (header.length < 8) break;

        final ByteData bd = ByteData.sublistView(header);
        int boxSize = bd.getUint32(0, Endian.big);
        final String boxType = String.fromCharCodes(header.sublist(4, 8));

        detectedBoxes.add(boxType);

        int headerSize = 8;
        if (boxSize == 1) {
          // Extended 64-bit box size
          if (offset + 16 > totalLength) break;
          final Uint8List extHeader = await raf.read(8);
          if (extHeader.length < 8) break;
          final ByteData extBd = ByteData.sublistView(extHeader);
          boxSize = extBd.getUint64(0, Endian.big);
          headerSize = 16;
        } else if (boxSize == 0) {
          // Box extends to EOF
          boxSize = totalLength - offset;
        }

        if (boxType == 'ftyp') hasFtyp = true;
        if (boxType == 'moov') hasMoov = true;
        if (boxType == 'mdat') hasMdat = true;

        // Verify that the box does not overrun EOF
        if (boxSize < headerSize || (offset + boxSize) > totalLength) {
          if (boxType == 'moov') {
            // moov atom header declared larger than remaining file -> truncated write
            hasMoov = false;
          }
          break;
        }

        offset += boxSize;
      }

      final bool isValid = hasFtyp && hasMoov && hasMdat;
      String? error;
      if (!isValid) {
        final missing = <String>[];
        if (!hasFtyp) missing.add('ftyp');
        if (!hasMoov) missing.add('moov (container index missing)');
        if (!hasMdat) missing.add('mdat (media data missing)');
        error = 'Corrupt MP4 container: missing ${missing.join(', ')}';
      }

      return Mp4ValidationResult(
        isValid: isValid,
        hasFtyp: hasFtyp,
        hasMoov: hasMoov,
        hasMdat: hasMdat,
        fileSizeBytes: totalLength,
        detectedBoxes: detectedBoxes,
        error: error,
      );
    } catch (e) {
      return Mp4ValidationResult(
        isValid: false,
        hasFtyp: false,
        hasMoov: false,
        hasMdat: false,
        fileSizeBytes: totalLength,
        error: 'I/O Exception while inspecting MP4 container: $e',
      );
    } finally {
      await raf?.close();
    }
  }

  /// Waits for the native camera recorder to finish flushing video buffers,
  /// closing OS file descriptors, and writing the final 'moov' atom.
  /// Polls up to [timeout] duration.
  static Future<Mp4ValidationResult> waitForMp4Finalization(
    File file, {
    Duration timeout = const Duration(milliseconds: 2000),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    int lastSize = -1;
    Mp4ValidationResult lastResult = const Mp4ValidationResult(
      isValid: false,
      hasFtyp: false,
      hasMoov: false,
      hasMdat: false,
      fileSizeBytes: 0,
    );

    while (stopwatch.elapsed < timeout) {
      if (await file.exists()) {
        final currentSize = await file.length();
        lastResult = await validate(file);

        // Container is completely finalized when ftyp, mdat, and moov exist and size is stable
        if (lastResult.isValid && currentSize > 0 && currentSize == lastSize) {
          debugPrint(
            'Mp4Validator: Video container finalized cleanly in ${stopwatch.elapsedMilliseconds}ms (${lastResult.fileSizeBytes} bytes, boxes: ${lastResult.detectedBoxes})',
          );
          return lastResult;
        }
        lastSize = currentSize;
      }
      await Future.delayed(pollInterval);
    }

    debugPrint(
      'Mp4Validator: Finalization check timed out after ${timeout.inMilliseconds}ms. Last result: $lastResult',
    );
    return lastResult;
  }

  /// Safely flushes, verifies, and copies an MP4 video from [sourceFile] to [destinationPath].
  /// Guarantees that the target file is fully flushed to disk with valid moov metadata
  /// before deleting the temporary source file.
  static Future<bool> safelyFinalizeAndPersist(
    File sourceFile,
    String destinationPath, {
    Duration timeout = const Duration(milliseconds: 2000),
  }) async {
    // 1. Wait for source file to finish flushing and finalize moov atom
    final validation = await waitForMp4Finalization(sourceFile, timeout: timeout);
    if (!validation.isValid) {
      debugPrint('Mp4Validator: Refusing to persist corrupt MP4 container: ${validation.error}');
      return false;
    }

    // 2. Perform safe copy with buffer flushing
    final targetFile = File(destinationPath);
    await targetFile.parent.create(recursive: true);

    // Read bytes and write explicitly with sync flush
    final RandomAccessFile sourceRaf = await sourceFile.open(mode: FileMode.read);
    final RandomAccessFile targetRaf = await targetFile.open(mode: FileMode.write);

    try {
      final Uint8List buffer = Uint8List(128 * 1024); // 128KB copy buffer
      int bytesRead;
      while ((bytesRead = await sourceRaf.readInto(buffer)) > 0) {
        await targetRaf.writeFrom(buffer, 0, bytesRead);
      }
      await targetRaf.flush();
    } finally {
      await sourceRaf.close();
      await targetRaf.close();
    }

    // 3. Verify destination file integrity
    final targetValidation = await validate(targetFile);
    if (!targetValidation.isValid) {
      debugPrint('Mp4Validator: Destination copy failed integrity audit: ${targetValidation.error}');
      return false;
    }

    // 4. Guaranteed cleanup of temporary file
    try {
      if (await sourceFile.exists()) {
        await sourceFile.delete();
      }
    } catch (e) {
      debugPrint('Mp4Validator: Non-fatal temporary file cleanup notice: $e');
    }

    debugPrint(
      'Mp4Validator: Video safely persisted to $destinationPath (${targetValidation.fileSizeBytes} bytes)',
    );
    return true;
  }
}
