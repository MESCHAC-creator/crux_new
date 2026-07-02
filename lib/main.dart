import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:logger/logger.dart';
import 'package:intl/date_symbol_data_local.dart';

// Services
import 'services/notification_service.dart';
import 'services/device_verification_service.dart';
import 'firebase_options.dart';

// Providers
import 'providers/auth_provider.dart';
import 'providers/meeting_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/locale_provider.dart';
import 'providers/color_provider.dart';

// Routes & Theme
import 'routes/app_routes.dart';
import 'theme/theme.dart';
import 'theme/colors.dart';

// Utils & Screens
import 'utils/localization_utils.dart';
import 'screens/auth_wrapper.dart';

final logger = Logger();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR', null);

  // 1. Firebase Initialization
  String? firebaseError;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    logger.i('✅ Firebase initialisé');
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: 40 * 1024 * 1024,
    );
  } catch (e) {
    logger.e('❌ Firebase init error: $e');
    firebaseError = e.toString();
  }

  if (firebaseError != null) {
    runApp(_FirebaseErrorApp(error: firebaseError));
    return;
  }

  // 2. Device Security Verification
  final (isSecure, blockReason) =
      await DeviceVerificationService.instance.verifyDeviceSecurity();

  // 3. Notifications Initialization
  try {
    await NotificationService().initialize();
  } catch (e) {
    logger.e('Notification init error: $e');
  }

  if (!isSecure) {
    runApp(_DeviceBlockedApp(reason: blockReason));
    return;
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CruxAuthProvider()),
        ChangeNotifierProvider(create: (_) => MeetingProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => ColorProvider()),
      ],
      child: Consumer2<ThemeProvider, LocaleProvider>(
        builder: (context, themeProvider, localeProvider, _) {
          return MaterialApp(
            navigatorKey: MyApp._navigatorKey,
            title: 'CRUX - Premium Video Conference',
            debugShowCheckedModeBanner: false,
            supportedLocales: LocaleProvider.languages.values.toList(),
            locale: localeProvider.locale,
            localizationsDelegates: appLocalizationsDelegates,
            localeResolutionCallback: (locale, supported) {
              if (locale == null) return const Locale('fr');
              for (final s in supported) {
                if (s.languageCode == locale.languageCode) return s;
              }
              return const Locale('fr');
            },
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: themeProvider.themeMode,
            onGenerateRoute: AppRoutes.generateRoute,
            home: const AuthWrapper(),
          );
        },
      ),
    );
  }
}

/// Shown when Firebase fails to initialize.
class _FirebaseErrorApp extends StatelessWidget {
  final String error;
  const _FirebaseErrorApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: const [Locale('fr'), Locale('en')],
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0C1A),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_off_rounded, color: Colors.orange, size: 72),
                const SizedBox(height: 24),
                const Text(
                  'Impossible de démarrer',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'La connexion au serveur a échoué.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.6),
                ),
                const SizedBox(height: 24),
                Text(error, style: const TextStyle(color: Colors.white30, fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when the device fails security checks.
class _DeviceBlockedApp extends StatelessWidget {
  final String reason;
  const _DeviceBlockedApp({required this.reason});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: LocaleProvider.languages.values.toList(),
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0C1A),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.security, color: Colors.red, size: 72),
                const SizedBox(height: 24),
                const Text(
                  'Appareil non compatible',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(reason, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.6)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
