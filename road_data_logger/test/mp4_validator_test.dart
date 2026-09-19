import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:road_data_logger/utils/mp4_validator.dart';

Uint8List createMockMp4({
  bool includeFtyp = true,
  bool includeMdat = true,
  bool includeMoov = true,
  bool truncateMoov = false,
}) {
  final BytesBuilder bb = BytesBuilder();

  // 1. ftyp box
  if (includeFtyp) {
    final Uint8List ftypPayload = Uint8List.fromList([
      ...[0, 0, 0, 24], // length 24
      ...[102, 116, 121, 112], // 'ftyp'
      ...[105, 115, 111, 109], // 'isom'
      ...[0, 0, 0, 1], // minor version 1
      ...[105, 115, 111, 109], // 'isom'
      ...[109, 112, 52, 50], // 'mp42'
    ]);
    bb.add(ftypPayload);
  }

  // 2. mdat box
  if (includeMdat) {
    final Uint8List mdatPayload = Uint8List.fromList([
      ...[0, 0, 0, 20], // length 20
      ...[109, 100, 97, 116], // 'mdat'
      ...List.filled(12, 42), // 12 bytes video data
    ]);
    bb.add(mdatPayload);
  }

  // 3. moov box
  if (includeMoov) {
    if (truncateMoov) {
      // Box header declares 64 bytes, but only 12 bytes exist
      final Uint8List moovPayload = Uint8List.fromList([
        ...[0, 0, 0, 64], // declared length 64
        ...[109, 111, 111, 118], // 'moov'
        ...List.filled(4, 0), // only 4 bytes payload
      ]);
      bb.add(moovPayload);
    } else {
      final Uint8List moovPayload = Uint8List.fromList([
        ...[0, 0, 0, 24], // length 24
        ...[109, 111, 111, 118], // 'moov'
        ...List.filled(16, 0), // 16 bytes mvhd/trak data
      ]);
      bb.add(moovPayload);
    }
  }

  return bb.toBytes();
}

void main() {
  group('Mp4Validator Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('mp4_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Valid MP4 container with ftyp, mdat, and moov passes validation', () async {
      final file = File('${tempDir.path}/valid.mp4');
      await file.writeAsBytes(createMockMp4());

      final result = await Mp4Validator.validate(file);
      expect(result.isValid, isTrue);
      expect(result.hasFtyp, isTrue);
      expect(result.hasMdat, isTrue);
      expect(result.hasMoov, isTrue);
      expect(result.error, isNull);
    });

    test('MP4 missing moov atom fails validation', () async {
      final file = File('${tempDir.path}/no_moov.mp4');
      await file.writeAsBytes(createMockMp4(includeMoov: false));

      final result = await Mp4Validator.validate(file);
      expect(result.isValid, isFalse);
      expect(result.hasFtyp, isTrue);
      expect(result.hasMdat, isTrue);
      expect(result.hasMoov, isFalse);
      expect(result.error, contains('moov'));
    });

    test('MP4 with truncated moov atom fails validation', () async {
      final file = File('${tempDir.path}/truncated_moov.mp4');
      await file.writeAsBytes(createMockMp4(truncateMoov: true));

      final result = await Mp4Validator.validate(file);
      expect(result.isValid, isFalse);
      expect(result.hasMoov, isFalse);
    });

    test('safelyFinalizeAndPersist flushes and copies valid MP4', () async {
      final source = File('${tempDir.path}/source.mp4');
      final target = '${tempDir.path}/dest/target.mp4';
      await source.writeAsBytes(createMockMp4());

      final success = await Mp4Validator.safelyFinalizeAndPersist(source, target);
      expect(success, isTrue);

      final targetFile = File(target);
      expect(await targetFile.exists(), isTrue);
      final audit = await Mp4Validator.validate(targetFile);
      expect(audit.isValid, isTrue);

      // Source temporary file should be removed
      expect(await source.exists(), isFalse);
    });
  });
}
