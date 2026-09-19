import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AppConfig {
  static bool _isSupabaseInitialized = false;

  static bool get isSupabaseInitialized => _isSupabaseInitialized;

  /// Loads environment variables and initializes Supabase client defensively.
  static Future<void> initialize() async {
    try {
      await dotenv.load(fileName: "assets/.env");
    } catch (_) {
      try {
        await dotenv.load(fileName: ".env");
      } catch (e) {
        debugPrint("Warning: Could not load .env file ($e). Using fallback or system environment.");
      }
    }

    final url = dotenv.env['SUPABASE_URL'] ??
        const String.fromEnvironment('SUPABASE_URL', defaultValue: '');

    final key = dotenv.env['SUPABASE_KEY'] ??
        dotenv.env['SUPABASE_ANON_KEY'] ??
        dotenv.env['SUPABASE_SECRET_KEY'] ??
        const String.fromEnvironment('SUPABASE_KEY', defaultValue: '');

    if (url.isNotEmpty && key.isNotEmpty) {
      try {
        await Supabase.initialize(
          url: url,
          anonKey: key,
        );
        _isSupabaseInitialized = true;
        debugPrint("Supabase initialized successfully.");
      } catch (e) {
        debugPrint("Error initializing Supabase: $e");
      }
    } else {
      debugPrint("Warning: Supabase credentials missing from configuration.");
    }
  }

  static SupabaseClient get supabase => Supabase.instance.client;

  static User? get currentUser =>
      _isSupabaseInitialized ? Supabase.instance.client.auth.currentUser : null;

  static Session? get currentSession =>
      _isSupabaseInitialized ? Supabase.instance.client.auth.currentSession : null;
}
