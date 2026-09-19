import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../theme/uber_theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  bool _isLogin = true;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (!AppConfig.isSupabaseInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Supabase is not configured. Check your .env file."),
          backgroundColor: UberColors.red,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    final email = _emailCtrl.text.trim();
    final password = _passCtrl.text.trim();

    try {
      if (_isLogin) {
        await AppConfig.supabase.auth.signInWithPassword(
          email: email,
          password: password,
        );
      } else {
        await AppConfig.supabase.auth.signUp(
          email: email,
          password: password,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Account created! Please check your email to confirm or sign in."),
              backgroundColor: UberColors.green,
            ),
          );
          setState(() => _isLogin = true);
        }
      }
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: UberColors.red),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: UberColors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: UberColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Minimalist Uber Header
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: UberColors.white,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.navigation, color: UberColors.black, size: 20),
                      ),
                      const SizedBox(width: 12),
                      const Text("ROAD SENSE", style: UberTypography.title),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // Headline
                  Text(
                    _isLogin ? "Welcome back" : "Create your account",
                    style: UberTypography.headline.copyWith(fontSize: 28),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _isLogin
                        ? "Enter your credentials to access patrol telemetry"
                        : "Join the autonomous road monitoring network",
                    style: UberTypography.body.copyWith(color: UberColors.textSecondary),
                  ),
                  const SizedBox(height: 28),

                  // Segmented Mode Toggle (Uber Style)
                  Container(
                    height: 46,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: UberColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: UberColors.border),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              if (!_isLogin) {
                                setState(() => _isLogin = true);
                                _formKey.currentState?.reset();
                              }
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _isLogin ? UberColors.white : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                "SIGN IN",
                                style: TextStyle(
                                  color: _isLogin ? UberColors.black : UberColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () {
                              if (_isLogin) {
                                setState(() => _isLogin = false);
                                _formKey.currentState?.reset();
                              }
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: !_isLogin ? UberColors.white : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                "REGISTER",
                                style: TextStyle(
                                  color: !_isLogin ? UberColors.black : UberColors.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Email Input
                  Text("EMAIL", style: UberTypography.caption.copyWith(color: UberColors.textTertiary)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(color: UberColors.textPrimary, fontSize: 15),
                    decoration: const InputDecoration(
                      hintText: "name@example.com",
                      prefixIcon: Icon(Icons.mail_outline, color: UberColors.textSecondary, size: 20),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return "Please enter your email";
                      }
                      if (!value.contains('@') || !value.contains('.')) {
                        return "Enter a valid email address";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),

                  // Password Input
                  Text("PASSWORD", style: UberTypography.caption.copyWith(color: UberColors.textTertiary)),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _passCtrl,
                    obscureText: _obscurePassword,
                    style: const TextStyle(color: UberColors.textPrimary, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: "••••••••",
                      prefixIcon: const Icon(Icons.lock_outline, color: UberColors.textSecondary, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          color: UberColors.textSecondary,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return "Please enter your password";
                      }
                      if (value.length < 6) {
                        return "Password must be at least 6 characters";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 32),

                  // High-Contrast Primary CTA Button
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: UberColors.white,
                        foregroundColor: UberColors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(color: UberColors.black, strokeWidth: 2),
                            )
                          : Text(
                              _isLogin ? "CONTINUE" : "CREATE ACCOUNT",
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Security Footnote
                  Center(
                    child: Text(
                      "Protected with 256-bit encryption • Cloudflare Edge",
                      style: UberTypography.caption.copyWith(color: UberColors.textTertiary, fontSize: 10),
                    ),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
