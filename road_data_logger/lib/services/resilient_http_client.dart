import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// An HTTP client with built-in DNS-over-HTTPS (DoH) fallback.
///
/// Many consumer ISPs (e.g. Jio, some cellular carriers) block or fail to resolve
/// *.ts.net (Tailscale Funnel) domains via their default DNS resolvers, causing:
/// "SocketException: Failed host lookup: '...ts.net'".
///
/// This client tries standard DNS resolution first. If that fails (or for known
/// tunnel domains), it queries public DNS-over-HTTPS (Google 8.8.8.8 or Cloudflare 1.1.1.1),
/// caches the IP, and connects directly with proper TLS Server Name Indication (SNI).
class ResilientHttpClient {
  static final Map<String, _DnsCacheEntry> _cache = {};

  /// Creates a configured [http.Client] that handles DNS resolution fallbacks transparently.
  static http.Client createClient({Duration timeout = const Duration(seconds: 15)}) {
    final rawClient = HttpClient();
    rawClient.connectionTimeout = timeout;
    rawClient.connectionFactory = _connectionFactory;
    return IOClient(rawClient);
  }

  /// Custom connection factory that resolves hostnames via DoH if system DNS fails.
  static Future<ConnectionTask<Socket>> _connectionFactory(
    Uri uri,
    String? host,
    int? port,
  ) async {
    final targetHost = host ?? uri.host;
    final targetPort = (port != null && port > 0)
        ? port
        : (uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80));

    // 1. If targetHost is already an IP address, connect directly
    if (InternetAddress.tryParse(targetHost) != null) {
      return _connectSocket(targetHost, targetPort, uri.scheme == 'https', targetHost);
    }

    // 2. Try standard system DNS first (fast path)
    String? resolvedIp;
    try {
      final addresses = await InternetAddress.lookup(targetHost).timeout(const Duration(seconds: 2));
      if (addresses.isNotEmpty) {
        resolvedIp = addresses.first.address;
      }
    } catch (_) {
      // System DNS failed, fallback to DoH
    }

    // 3. Fallback to DNS-over-HTTPS
    resolvedIp ??= await resolveHostViaDoH(targetHost);

    if (resolvedIp == null) {
      throw SocketException('Failed host lookup for $targetHost (System DNS and DoH failed)');
    }

    return _connectSocket(resolvedIp, targetPort, uri.scheme == 'https', targetHost);
  }

  static Future<ConnectionTask<Socket>> _connectSocket(
    String ip,
    int port,
    bool isHttps,
    String sniHostname,
  ) async {
    final rawSocket = await Socket.connect(ip, port);
    if (isHttps) {
      final secureSocket = await SecureSocket.secure(rawSocket, host: sniHostname);
      return ConnectionTask.fromSocket(Future.value(secureSocket), () => secureSocket.destroy());
    }
    return ConnectionTask.fromSocket(Future.value(rawSocket), () => rawSocket.destroy());
  }

  /// Resolve hostname to IPv4 address using DNS-over-HTTPS (Google & Cloudflare).
  static Future<String?> resolveHostViaDoH(String host) async {
    final cached = _cache[host];
    if (cached != null && DateTime.now().isBefore(cached.expires)) {
      return cached.ip;
    }

    final dohEndpoints = [
      'https://dns.google/resolve?name=$host&type=A',
      'https://cloudflare-dns.com/dns-query?name=$host&type=A',
    ];

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);

    try {
      for (final endpoint in dohEndpoints) {
        try {
          final req = await client.getUrl(Uri.parse(endpoint));
          req.headers.set('accept', 'application/dns-json');
          final resp = await req.close().timeout(const Duration(seconds: 4));
          if (resp.statusCode == 200) {
            final body = await resp.cast<List<int>>().transform(utf8.decoder).join();
            final json = jsonDecode(body) as Map<String, dynamic>;
            final answers = json['Answer'] as List<dynamic>?;
            if (answers != null && answers.isNotEmpty) {
              for (final ans in answers) {
                if (ans['type'] == 1 && ans['data'] != null) {
                  final ip = ans['data'] as String;
                  final ttl = (ans['TTL'] as num?)?.toInt() ?? 300;
                  _cache[host] = _DnsCacheEntry(
                    ip: ip,
                    expires: DateTime.now().add(Duration(seconds: ttl.clamp(60, 3600))),
                  );
                  debugPrint("ResilientHttpClient: Resolved '$host' -> '$ip' via DoH");
                  return ip;
                }
              }
            }
          }
        } catch (e) {
          debugPrint("ResilientHttpClient: DoH lookup on $endpoint failed: $e");
        }
      }
    } finally {
      client.close();
    }
    return null;
  }
}

class _DnsCacheEntry {
  final String ip;
  final DateTime expires;
  _DnsCacheEntry({required this.ip, required this.expires});
}
