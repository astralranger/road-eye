import 'dart:convert';

class GpsData {
  final double lat;
  final double lon;
  final double speed;
  final double heading;

  const GpsData({
    required this.lat,
    required this.lon,
    required this.speed,
    required this.heading,
  });

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        'speed': speed,
        'heading': heading,
      };

  factory GpsData.fromJson(Map<String, dynamic> json) => GpsData(
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
        speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
        heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
      );
}

class TelemetryPayload {
  final String imageBase64;
  final GpsData gps;
  final String instanceIp;
  final double roughness;
  final String userId;
  final String userEmail;

  const TelemetryPayload({
    required this.imageBase64,
    required this.gps,
    required this.instanceIp,
    required this.roughness,
    required this.userId,
    required this.userEmail,
  });

  Map<String, dynamic> toJson() => {
        'image': imageBase64,
        'gps': gps.toJson(),
        'instance_ip': instanceIp,
        'roughness': roughness,
        'user_id': userId,
        'user_email': userEmail,
      };

  String toEncodedJson() => jsonEncode(toJson());
}
