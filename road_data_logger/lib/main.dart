import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/app_config.dart';
import 'screens/auth_screen.dart';
import 'screens/data_collector_view.dart';
import 'services/spatial_queue_service.dart';
import 'theme/uber_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await AppConfig.initialize();
  await SpatialQueueService().initialize();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  final CameraDescription? camera;
  const MyApp({super.key, this.camera});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Road Sense Pro',
      debugShowCheckedModeBanner: false,
      theme: UberTheme.darkTheme,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (!AppConfig.isSupabaseInitialized) {
      // If Supabase is offline or unconfigured, allow direct access to collector view
      return DataCollectorView(camera: camera);
    }

    return StreamBuilder<AuthState>(
      stream: AppConfig.supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            AppConfig.currentSession == null) {
          return const Scaffold(
            backgroundColor: Color(0xFF0F172A),
            body: Center(child: CircularProgressIndicator(color: Colors.blueAccent)),
          );
        }

        final session = snapshot.data?.session ?? AppConfig.currentSession;
        if (session != null) {
          return DataCollectorView(camera: camera);
        } else {
          return const AuthScreen();
        }
      },
    );
  }
}