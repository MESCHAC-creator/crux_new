import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:app_links/app_links.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';
import '../theme/colors.dart';
import 'splash_screen.dart';
import 'home_screen.dart';
import 'consent_screen.dart';
import 'guest_join_screen.dart';
import 'meeting_screen.dart';

/// Routes authenticated users to HomeScreen or ConsentScreen based on terms acceptance.
/// Also handles incoming deep links for joining meetings.
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool? _termsAccepted;
  late final Stream<User?> _authStream;
  String? _pendingMeetingId; // set when app is opened via a deep link
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _authStream = FirebaseAuth.instance.authStateChanges();
    _loadTerms();
    _initDeepLinks();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();

    // App already open — stream of incoming links
    _sub = appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });

    // App started cold via a link
    final initialUri = await appLinks.getInitialLink();
    if (initialUri != null) {
      _handleDeepLink(initialUri);
    }
  }

  void _handleDeepLink(Uri uri) {
    // crux://join/MEETING_ID  OR  https://*.*/join/MEETING_ID
    String? meetingId;
    if (uri.scheme == 'crux' && uri.host == 'join') {
      meetingId = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments[uri.pathSegments.length - 2] == 'join') {
      meetingId = uri.pathSegments.last;
    } else if (uri.queryParameters.containsKey('id')) {
      // Fallback: ?id=MEETING_ID
      meetingId = uri.queryParameters['id'];
    }

    if (meetingId == null || meetingId.isEmpty) return;
    final mid = meetingId.trim().toUpperCase();

    if (!mounted) {
      // Widget not mounted yet — store pending meeting ID for processing in build()
      _pendingMeetingId = mid;
      return;
    }

    // If already authenticated (non-anonymous), route to home-screen join flow
    final current = FirebaseAuth.instance.currentUser;
    if (current != null && !current.isAnonymous) {
      _joinMeetingAsAuthenticatedUser(mid);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => GuestJoinScreen(meetingId: mid)),
      );
    }
  }

  Future<void> _joinMeetingAsAuthenticatedUser(String meetingId) async {
    // Fetch meeting, then push MeetingScreen
    try {
      final doc = await FirebaseFirestore.instance
          .collection('meetings')
          .doc(meetingId)
          .get();
      if (!mounted) return;
      if (!doc.exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Réunion introuvable')),
        );
        return;
      }
      final data = doc.data()!;
      final current = FirebaseAuth.instance.currentUser!;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MeetingScreen(
            meetingId: meetingId,
            meetingName: data['title'] as String? ?? 'Réunion',
            userId: current.uid,
            userName: current.displayName ?? current.email ?? 'Invité',
            userEmail: current.email,
            isHost: false,
          ),
        ),
      );
    } catch (_) {
      // Fallback to guest join screen on error
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => GuestJoinScreen(meetingId: meetingId)),
        );
      }
    }
  }

  Future<void> _loadTerms() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _termsAccepted = prefs.getBool('crux_terms_accepted') ?? false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0A0A0F) : AppColors.whiteBg;

    // While SharedPreferences hasn't loaded yet, show spinner
    if (_termsAccepted == null) {
      return Scaffold(
        backgroundColor: bg,
        body: const Center(
          child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 3),
        ),
      );
    }

    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            backgroundColor: bg,
            body: const Center(
              child: CircularProgressIndicator(color: AppColors.primary, strokeWidth: 3),
            ),
          );
        }

        // Deep link pending — route based on auth state
        if (_pendingMeetingId != null) {
          final mid = _pendingMeetingId!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _pendingMeetingId = null);
              final current = FirebaseAuth.instance.currentUser;
              if (current != null && !current.isAnonymous) {
                _joinMeetingAsAuthenticatedUser(mid);
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => GuestJoinScreen(meetingId: mid)),
                );
              }
            }
          });
        }

        final user = snapshot.data;
        if (user == null) return const SplashScreen();

        final userModel = UserModel(
          uid: user.uid,
          name: user.displayName ?? user.email?.split('@')[0] ?? 'Utilisateur',
          email: user.email ?? '',
        );

        if (_termsAccepted == true) return HomeScreen(user: userModel);
        return ConsentScreen(user: userModel);
      },
    );
  }
}
