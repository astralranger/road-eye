import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/telemetry_payload.dart';
import '../utils/url_helper.dart';
import 'resilient_http_client.dart';

class DetectionApiResponse {
  final bool success;
  final String status;
  final String? detectionUrl;
  final String? errorMessage;

  const DetectionApiResponse({
    required this.success,
    required this.status,
    this.detectionUrl,
    this.errorMessage,
  });
}

class ApiService {
  final http.Client _client;

  ApiService({http.Client? client}) : _client = client ?? ResilientHttpClient.createClient();

  Future<DetectionApiResponse> sendDetectionPayload({
    required String targetUrl,
    required TelemetryPayload payload,
  }) async {
    final uri = UrlHelper.getDetectUri(targetUrl);
    if (uri == null) {
      return const DetectionApiResponse(
        success: false,
        status: "Invalid URL",
        errorMessage: "Target server URL is not configured or invalid.",
      );
    }

    try {
      final response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: payload.toEncodedJson(),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);
        final String rawStatus = (data['status'] ?? 'ok').toString();
        final String? url = data['url'] as String?;

        return DetectionApiResponse(
          success: true,
          status: rawStatus.toUpperCase(),
          detectionUrl: url,
        );
      } else {
        return DetectionApiResponse(
          success: false,
          status: "HTTP ${response.statusCode}",
          errorMessage: "Server responded with status code ${response.statusCode}",
        );
      }
    } on TimeoutException {
      return const DetectionApiResponse(
        success: false,
        status: "TIMEOUT",
        errorMessage: "Request to AI node timed out after 5 seconds.",
      );
    } on SocketException catch (e) {
      return DetectionApiResponse(
        success: false,
        status: "CONNECTION FAILED",
        errorMessage: e.message,
      );
    } catch (e) {
      debugPrint("API Transmission Error: $e");
      return DetectionApiResponse(
        success: false,
        status: "ERROR",
        errorMessage: e.toString(),
      );
    }
  }

  void dispose() {
    _client.close();
  }
}
