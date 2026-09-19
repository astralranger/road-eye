import 'package:flutter/material.dart';

class DetectionRecord {
  final dynamic id;
  final double latitude;
  final double longitude;
  final String imageUrl;
  final String createdAt;
  final String severity;
  final String userId;

  const DetectionRecord({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.imageUrl,
    required this.createdAt,
    required this.severity,
    required this.userId,
  });

  factory DetectionRecord.fromMap(Map<String, dynamic> map) {
    return DetectionRecord(
      id: map['id'],
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      imageUrl: (map['image_url'] as String?) ?? '',
      createdAt: (map['created_at'] as String?) ?? '',
      severity: (map['severity'] as String?) ?? 'Moderate',
      userId: (map['user_id'] as String?) ?? '',
    );
  }

  Color get markerColor {
    switch (severity.toLowerCase()) {
      case 'severe':
        return Colors.red;
      case 'minor':
        return Colors.green;
      default:
        return Colors.orange;
    }
  }

  String get formattedDate {
    if (createdAt.length >= 10) {
      return createdAt.substring(0, 10);
    }
    return createdAt;
  }
}
