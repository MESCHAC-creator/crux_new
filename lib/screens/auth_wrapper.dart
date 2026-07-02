import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:app_links/app_links.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import '../models/user_model.dart';
import '../providers/locale_provider.dart';
import '../theme/colors.dart';
import 'splash_screen.dart';
import 'home_screen.dart';
import 'consent_screen.dart';
import 'guest_join_screen.dart';
import 'meeting_screen.dart';

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool? _termsAccepted;
  late final Stream<User?> _authStream;
  String? _pendingMeetingId;
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
    _sub = appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });
    final initialUri = await appLinks.getInitialLink();
    if (initialUri != null) _handleDeepLink(initialUri);
  }

  void _handleDeepLink(Uri uri) {
    String? meetingId;
    if (uri.scheme == 'crux' && uri.host == 'join') {
      meetingId = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    } else if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'join') {
      meetingId = uri.pathSegments.last;
    }

    if (meetingId == null || meetingId.isEmpty) return;
    final mid = meetingId.trim().toUpperCase();

    if (!mounted) {
      _pendingMeetingId = mid;
      return;
    }

    final current = FirebaseAuth.instance.currentUser;
    if (current != null && !current.isAnonymous) {
      _joinMeetingAsAuthenticatedUser(mid);
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => GuestJoinScreen(meetingId: mid)));
    }
  }

  Future<void> _joinMeetingAsAuthenticatedUser(String meetingId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('meetings').doc(meetingId).get();
      if (!mounted || !doc.exists) return;
      final data = doc.data()!;
      final current = FirebaseAuth.instance.currentUser!;
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => MeetingScreen(
          meetingId: meetingId,
          meetingName: data['title'] as String? ?? 'Réunion',
          userId: current.uid,
          userName: current.displayName ?? 'Utilisateur',
          userEmail: current.email,
          isHost: false,
        ),
      ));
    } catch (_) {}
  }

  Future<void> _loadTerms() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _termsAccepted = prefs.getBool('crux_terms_accepted') ?? false);
  }

  @override
  Widget build(BuildContext context) {
    if (_termsAccepted == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Scaffold(body: Center(child: CircularProgressIndicator()));

        if (_pendingMeetingId != null) {
          final mid = _pendingMeetingId!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _pendingMeetingId = null);
              final current = FirebaseAuth.instance.currentUser;
              if (current != null && !current.isAnonymous) _joinMeetingAsAuthenticatedUser(mid);
              else Navigator.push(context, MaterialPageRoute(builder: (_) => GuestJoinScreen(meetingId: mid)));
            }
          });
        }

        final user = snapshot.data;
        if (user == null) return const SplashScreen();

        final userModel = UserModel(
          uid: user.uid,
          name: user.displayName ?? 'Utilisateur',
          email: user.email ?? '',
        );

        if (_termsAccepted == true) return HomeScreen(user: userModel);
        return ConsentScreen(user: userModel);
      },
    );
  }
}
