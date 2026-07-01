import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:livekit_client/livekit_client.dart';
import '../config/app_config.dart';
import '../services/livekit_service.dart';
import '../theme/colors.dart';

import 'package:share_plus/share_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/meeting_model.dart';
import '../services/meeting_service.dart';
import '../providers/locale_provider.dart';
import '../l10n/app_translations.dart';
import 'package:provider/provider.dart';

/// Large conference via LiveKit SFU — supports 1000+ participants (Zoom/Meet parity).
class LargeConferenceScreen extends StatefulWidget {
  final String meetingId;
  final String meetingName;
  final String userId;
  final String userName;
  final String? userEmail;
  final bool isHost;

  const LargeConferenceScreen({
    super.key,
    required this.meetingId,
    required this.meetingName,
    required this.userId,
    required this.userName,
    this.userEmail,
    this.isHost = false,
  });

  @override
  State<LargeConferenceScreen> createState() => _LargeConferenceScreenState();
}

class _LargeConferenceScreenState extends State<LargeConferenceScreen> {
  static const _pipChannel = MethodChannel('com.example.crux/pip');
  static const _screenChannel = MethodChannel('com.example.crux/screen_share');

  Room? _room;
  EventsListener<RoomEvent>? _roomListener;

  bool _micOn = true;
  bool _camOn = true;
  bool _speakerOn = true;
  bool _screenShareOn = false;
  bool _loading = true;
  String? _error;

  List<RemoteParticipant> _remoteParticipants = [];
  RemoteParticipant? _activeScreenSharer;
  String _activeScreenSharerName = '';
  int _gridPage = 0;

  // ── Host Controls ───────────────────────────
  bool _isCoHost = false;
  bool _isLocked = false;
  int _lastMuteAllCount = 0;
  bool _showParticipants = false;
  bool _showChat = false;
  int _unreadMessages = 0;
  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  StreamSubscription? _meetingDocSub;
  StreamSubscription? _kickSub;
  StreamSubscription? _chatSub;
  final _db = FirebaseFirestore.instance;
  final _meetingService = MeetingService();

  @override
  void initState() {
    super.initState();
    _init();
    _listenStopShareFromNotification();
    _listenMeetingDoc();
    _listenKicked();
    _listenChat();
  }

  @override
  void dispose() {
    _setInCall(false);
    _meetingDocSub?.cancel();
    _kickSub?.cancel();
    _chatSub?.cancel();
    _chatController.dispose();
    _chatScrollController.dispose();
    _roomListener?.dispose();
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
  }

  void _listenChat() {
    _chatSub = _db.collection('meetings').doc(widget.meetingId)
        .collection('chat').orderBy('timestamp', descending: true).limit(1).snapshots().listen((snap) {
      if (snap.docs.isNotEmpty && !_showChat) {
        setState(() => _unreadMessages++);
      }
    });
  }

  void _listenKicked() {
    _kickSub = _db.collection('meetings').doc(widget.meetingId)
        .collection('kicked').doc(widget.userId).snapshots().listen((snap) {
      if (snap.exists && mounted) {
        _leave();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vous avez été retiré de la réunion par l\'hôte'))
        );
      }
    });
  }

  void _listenMeetingDoc() {
    _meetingDocSub = _db.collection('meetings').doc(widget.meetingId).snapshots().listen((snap) {
      if (!snap.exists) {
        if (mounted && !widget.isHost) {
          _leave();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('La réunion a été terminée par l\'hôte'))
          );
        }
        return;
      }

      final data = snap.data()!;
      final coHosts = List<String>.from(data['coHosts'] ?? []);
      final locked = data['isLocked'] as bool? ?? false;
      final muteCount = data['muteAllCount'] as int? ?? 0;

      if (mounted) {
        setState(() {
          _isCoHost = coHosts.contains(widget.userId);
          _isLocked = locked;
        });

        // Handle Mute All trigger
        if (muteCount > _lastMuteAllCount) {
          _lastMuteAllCount = muteCount;
          if (!widget.isHost && !_isCoHost) {
            _room?.localParticipant?.setMicrophoneEnabled(false);
            setState(() => _micOn = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('L\'hôte a coupé tous les micros'))
            );
          }
        }
      }
    });
  }

  Future<void> _setInCall(bool inCall) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _pipChannel.invokeMethod('setInCall', {'inCall': inCall});
    } catch (_) {}
  }

  void _listenStopShareFromNotification() {
    if (kIsWeb || !Platform.isAndroid) return;
    _screenChannel.setMethodCallHandler((call) async {
      if (call.method == 'stopScreenShareFromNotification' && mounted && _screenShareOn) {
        await _toggleScreenShare(forceOff: true);
      }
    });
  }

  Future<void> _init() async {
    await [
      Permission.camera,
      Permission.microphone,
      if (!kIsWeb && Platform.isAndroid) Permission.notification,
    ].request();

    final token = await LiveKitService.instance.fetchToken(
      room: widget.meetingId,
      identity: widget.userId,
      name: widget.userName,
      isHost: widget.isHost,
    );

    if (token == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible d\'obtenir un token LiveKit.\n\n'
              'Serveur: ${AppConfig.livekitTokenServerUrl}';
        });
      }
      return;
    }

    try {
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultVideoPublishOptions: VideoPublishOptions(simulcast: true),
          defaultAudioPublishOptions: AudioPublishOptions(dtx: true),
          defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
            useiOSBroadcastExtension: false,
          ),
        ),
      );

      _roomListener = room.createListener();
      _roomListener!
        ..on<RoomConnectedEvent>((_) => _refreshParticipants())
        ..on<ParticipantConnectedEvent>((_) => _refreshParticipants())
        ..on<ParticipantDisconnectedEvent>((_) => _refreshParticipants())
        ..on<TrackPublishedEvent>((_) => _refreshParticipants())
        ..on<TrackUnpublishedEvent>((_) => _refreshParticipants())
        ..on<TrackSubscribedEvent>((_) => _refreshParticipants())
        ..on<TrackUnsubscribedEvent>((_) => _refreshParticipants())
        ..on<RoomDisconnectedEvent>((event) {
          if (mounted) {
            final reason = event.reason;
            if (reason != DisconnectReason.clientInitiated) {
              setState(() => _error = 'Déconnecté: ${reason?.name ?? "inconnu"}');
            }
          }
        });

      await room.connect(
        AppConfig.livekitUrl,
        token,
        connectOptions: const ConnectOptions(autoSubscribe: true),
      );

      _room = room;
      await room.localParticipant?.setCameraEnabled(_camOn);
      await room.localParticipant?.setMicrophoneEnabled(_micOn);
      await _setInCall(true);

      if (mounted) {
        setState(() {
          _loading = false;
          _remoteParticipants = room.remoteParticipants.values.toList();
        });
        _updateScreenShareFocus();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Connexion LiveKit échouée:\n$e';
        });
      }
    }
  }

  void _refreshParticipants() {
    if (mounted && _room != null) {
      setState(() {
        _remoteParticipants = _room!.remoteParticipants.values.toList();
        _loading = false;
      });
      _updateScreenShareFocus();
    }
  }

  void _updateScreenShareFocus() {
    RemoteParticipant? sharer;
    String name = '';
    for (final p in _remoteParticipants) {
      if (_screenShareTrack(p) != null) {
        sharer = p;
        name = p.name ?? p.identity;
        break;
      }
    }
    if (!mounted) return;
    setState(() {
      _activeScreenSharer = sharer;
      _activeScreenSharerName = name;
    });
  }

  VideoTrack? _screenShareTrack(Participant p) {
    for (final pub in p.videoTrackPublications) {
      if (pub.source == TrackSource.screenShareVideo && pub.track is VideoTrack) {
        return pub.track as VideoTrack;
      }
    }
    return null;
  }

  VideoTrack? _cameraTrack(Participant p) {
    for (final pub in p.videoTrackPublications) {
      if (pub.source == TrackSource.camera && pub.track is VideoTrack) {
        return pub.track as VideoTrack;
      }
    }
    return null;
  }

  Future<void> _toggleMic() async {
    _micOn = !_micOn;
    await _room?.localParticipant?.setMicrophoneEnabled(_micOn);
    setState(() {});
  }

  Future<void> _toggleCam() async {
    _camOn = !_camOn;
    await _room?.localParticipant?.setCameraEnabled(_camOn);
    setState(() {});
  }

  Future<void> _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    try {
      await Hardware.instance.setSpeakerphoneOn(_speakerOn);
    } catch (_) {}
    setState(() {});
  }

  Future<bool> _requestAndroidCapturePermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final ok = await _screenChannel.invokeMethod<bool>('requestCapturePermission');
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _toggleScreenShare({bool forceOff = false}) async {
    if (forceOff && !_screenShareOn) return;

    if (!_screenShareOn && !forceOff) {
      if (!kIsWeb && Platform.isAndroid) {
        final granted = await _requestAndroidCapturePermission();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Permission de capture refusée',
                    style: GoogleFonts.poppins(fontSize: 13)),
                backgroundColor: Colors.orange.shade800,
              ),
            );
          }
          return;
        }
      }
    }

    try {
      final next = forceOff ? false : !_screenShareOn;
      await _room?.localParticipant?.setScreenShareEnabled(
        next,
        captureScreenAudio: false,
      );
      _screenShareOn = next;
      if (!kIsWeb && Platform.isAndroid) {
        try {
          await _screenChannel.invokeMethod(
            _screenShareOn ? 'screenShareStarted' : 'screenShareStopped',
          );
        } catch (_) {}
      }
      setState(() {});
      _updateScreenShareFocus();
    } catch (e) {
      _screenShareOn = false;
      if (!kIsWeb && Platform.isAndroid) {
        try {
          await _screenChannel.invokeMethod('screenShareStopped');
        } catch (_) {}
      }
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Partage d\'écran impossible: $e',
                style: GoogleFonts.poppins(fontSize: 13)),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  Future<void> _switchCamera() async {
    final track = _room?.localParticipant?.videoTrackPublications
        .where((pub) => pub.track is LocalVideoTrack)
        .map((pub) => pub.track as LocalVideoTrack)
        .firstOrNull;
    if (track == null) return;

    try {
      final devices = await Hardware.instance.enumerateDevices(type: 'videoinput');
      if (devices.length < 2) return;

      final currentDeviceId = track.mediaStreamTrack.getSettings()['deviceId'];
      final nextDevice = devices.firstWhere(
        (d) => d.deviceId != currentDeviceId,
        orElse: () => devices.first,
      );

      await track.switchCamera(nextDevice.deviceId);
    } catch (e) {
      debugPrint('Error switching camera: $e');
    }
  }

  void _shareMeeting() {
    final lang = context.read<LocaleProvider>().locale.languageCode;
    final joinUrl = 'https://crux-8aa85.web.app/join/${widget.meetingId}';
    final text = AppTranslations.t('share_meeting_msg', lang)
        .replaceAll('{name}', widget.meetingName)
        .replaceAll('{code}', widget.meetingId)
        + '\n\n🔗 Lien direct : $joinUrl';
    final subject = AppTranslations.t('share_meeting_subject', lang)
        .replaceAll('{name}', widget.meetingName);
    Share.share(text, subject: subject);
  }

  Future<void> _leave() async {
    if (_screenShareOn) await _toggleScreenShare(forceOff: true);
    await _setInCall(false);
    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  Widget _buildAvatar(String name, {int seed = 0}) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final palette = [
      [const Color(0xFF6A1B9A), const Color(0xFF1565C0)],
      [const Color(0xFFB71C1C), const Color(0xFF880E4F)],
      [const Color(0xFF1B5E20), const Color(0xFF1565C0)],
      [const Color(0xFFE65100), const Color(0xFFB71C1C)],
    ];
    final idx = seed.abs() % palette.length;
    return Container(
      color: const Color(0xFF1A1529),
      child: Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: palette[idx],
            ),
          ),
          child: Center(
            child: Text(initial,
                style: GoogleFonts.poppins(
                    color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }

  Widget _buildParticipantTile(Participant p, {bool isLocal = false}) {
    final screen = _screenShareTrack(p);
    final camera = _cameraTrack(p);
    final name = isLocal ? widget.userName : (p.name ?? p.identity);

    Widget video;
    if (screen != null) {
      video = VideoTrackRenderer(screen);
    } else if (camera != null && (isLocal ? _camOn : true)) {
      video = VideoTrackRenderer(camera);
    } else {
      video = _buildAvatar(name, seed: (isLocal ? widget.userId : p.identity).hashCode);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          video,
          Positioned(
            bottom: 6,
            left: 6,
            child: _nameTag(name, isLocal: isLocal, isSharing: screen != null),
          ),
        ],
      ),
    );
  }

  Widget _nameTag(String name, {bool isLocal = false, bool isSharing = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSharing)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.screen_share, color: Colors.white70, size: 10),
            ),
          Text(
            isLocal ? '$name (moi)' : name,
            style: GoogleFonts.poppins(color: Colors.white, fontSize: 10),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildScreenShareLayout() {
    final sharer = _activeScreenSharer;
    final local = _room?.localParticipant;
    VideoTrack? mainTrack;

    if (_screenShareOn && local != null) {
      mainTrack = _screenShareTrack(local);
    } else if (sharer != null) {
      mainTrack = _screenShareTrack(sharer);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: mainTrack != null
              ? VideoTrackRenderer(mainTrack)
              : _buildAvatar(_activeScreenSharerName),
        ),
        if (mainTrack != null)
          Positioned(
            top: 72,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.screen_share, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _screenShareOn
                          ? 'Vous partagez votre écran'
                          : '$_activeScreenSharerName partage son écran',
                      style: GoogleFonts.poppins(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (local != null)
          Positioned(
            top: 120,
            right: 12,
            width: 100,
            height: 140,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _buildParticipantTile(local, isLocal: true),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoGrid() {
    if (_activeScreenSharer != null || _screenShareOn) {
      return _buildScreenShareLayout();
    }

    final local = _room?.localParticipant;
    final total = 1 + _remoteParticipants.length;
    if (total == 1 && local != null) {
      return Positioned.fill(child: _buildParticipantTile(local, isLocal: true));
    }

    if (total == 2 && local != null) {
      return Stack(
        children: [
          Positioned.fill(child: _buildParticipantTile(_remoteParticipants.first)),
          Positioned(
            top: 80,
            right: 12,
            width: 100,
            height: 140,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: _buildParticipantTile(local, isLocal: true),
            ),
          ),
        ],
      );
    }

    final cap = AppConfig.livekitVisibleTileCap;
    final allParticipants = <Participant>[
      if (local != null) local,
      ..._remoteParticipants,
    ];
    final pageCount = (allParticipants.length / cap).ceil().clamp(1, 999);
    final start = _gridPage * cap;
    final end = (start + cap).clamp(0, allParticipants.length);
    final pageItems = allParticipants.sublist(start, end);
    final crossCount = pageItems.length <= 4 ? 2 : 4;

    return Positioned.fill(
      child: Column(
        children: [
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(4, 60, 4, 4),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossCount,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
                childAspectRatio: 3 / 4,
              ),
              itemCount: pageItems.length,
              itemBuilder: (_, i) {
                final p = pageItems[i];
                return _buildParticipantTile(p, isLocal: p is LocalParticipant);
              },
            ),
          ),
          if (pageCount > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 88),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _gridPage > 0 ? () => setState(() => _gridPage--) : null,
                    icon: const Icon(Icons.chevron_left, color: Colors.white70),
                  ),
                  Text(
                    'Page ${_gridPage + 1}/$pageCount • ${allParticipants.length} participants',
                    style: GoogleFonts.poppins(color: Colors.white60, fontSize: 11),
                  ),
                  IconButton(
                    onPressed: _gridPage < pageCount - 1
                        ? () => setState(() => _gridPage++)
                        : null,
                    icon: const Icon(Icons.chevron_right, color: Colors.white70),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _loading
            ? _buildLoading()
            : _error != null
                ? _buildErrorScreen()
                : _buildCall(),
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: AppColors.primary),
        const SizedBox(height: 16),
        Text('Connexion LiveKit (1000+ participants)...',
            style: GoogleFonts.poppins(color: Colors.white70)),
      ]),
    );
  }

  Widget _buildErrorScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline_rounded, color: Colors.red, size: 56),
          const SizedBox(height: 16),
          Text(_error!,
              style: GoogleFonts.poppins(
                  color: Colors.white, fontSize: 14, height: 1.6),
              textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text('Retour',
                style: GoogleFonts.poppins(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () {
              setState(() {
                _loading = true;
                _error = null;
              });
              _init();
            },
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text('Réessayer',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white12, foregroundColor: Colors.white),
          ),
        ]),
      ),
    );
  }

  Widget _buildCall() {
    final total = 1 + _remoteParticipants.length;
    return Stack(
      children: [
        _buildVideoGrid(),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.meetingName,
                          style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 15)),
                      Row(
                        children: [
                          Text(
                            '${widget.meetingId} • $total/${AppConfig.livekitMaxParticipants}',
                            style: GoogleFonts.poppins(
                                color: Colors.white60, fontSize: 11),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text('LiveKit SFU',
                                style: GoogleFonts.poppins(
                                    color: Colors.greenAccent,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.meetingId));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('ID copié'),
                        duration: Duration(seconds: 2)));
                  },
                  child: const Icon(Icons.copy_rounded,
                      color: Colors.white54, size: 18),
                ),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: _shareMeeting,
                  child: const Icon(Icons.share_rounded,
                      color: Colors.white54, size: 18),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ControlBtn(
                    icon: _micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                    label: _micOn ? 'Micro' : 'Muet',
                    active: _micOn,
                    onTap: _toggleMic,
                  ),
                  const SizedBox(width: 15),
                  _ControlBtn(
                    icon: _camOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                    label: _camOn ? 'Caméra' : 'Off',
                    active: _camOn,
                    onTap: _toggleCam,
                  ),
                  const SizedBox(width: 15),
                  _ControlBtn(
                    icon: Icons.people_rounded,
                    label: 'Particip.',
                    active: _showParticipants,
                    onTap: () => setState(() {
                      _showParticipants = !_showParticipants;
                      _showChat = false;
                    }),
                  ),
                  const SizedBox(width: 15),
                  Stack(
                    children: [
                      _ControlBtn(
                        icon: Icons.chat_bubble_rounded,
                        label: 'Chat',
                        active: _showChat,
                        onTap: () => setState(() {
                          _showChat = !_showChat;
                          _showParticipants = false;
                          if (_showChat) _unreadMessages = 0;
                        }),
                      ),
                      if (_unreadMessages > 0)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                            constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                            child: Text('$_unreadMessages', style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 15),
                  _ControlBtn(
                    icon: _screenShareOn
                        ? Icons.stop_screen_share_rounded
                        : Icons.screen_share_rounded,
                    label: _screenShareOn ? 'Stop' : 'Écran',
                    active: !_screenShareOn,
                    onTap: () => _toggleScreenShare(),
                  ),
                  const SizedBox(width: 15),
                  _ControlBtn(
                    icon: Icons.flip_camera_android_rounded,
                    label: 'Retourner',
                    active: true,
                    onTap: _switchCamera,
                  ),
                  const SizedBox(width: 15),
                  _ControlBtn(
                    icon: _speakerOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                    label: _speakerOn ? 'HP' : 'HP off',
                    active: _speakerOn,
                    onTap: _toggleSpeaker,
                  ),
                  const SizedBox(width: 20),
                  GestureDetector(
                    onTap: _leave,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(
                          color: Colors.red, shape: BoxShape.circle),
                      child: const Icon(Icons.call_end_rounded,
                          color: Colors.white, size: 28),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_showParticipants)
          _buildParticipantsPanel(),
        if (_showChat)
          _buildChatPanel(),
      ],
    );
  }

  Widget _buildChatPanel() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 20)],
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Text('Chat de réunion',
                      style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => setState(() => _showChat = false),
                  ),
                ],
              ),
            ),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: _db.collection('meetings').doc(widget.meetingId).collection('chat').orderBy('timestamp', descending: true).snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  final docs = snapshot.data!.docs;
                  return ListView.builder(
                    reverse: true,
                    controller: _chatScrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final data = docs[index].data() as Map<String, dynamic>;
                      final isMe = data['senderId'] == widget.userId;
                      return _buildChatMessage(data, isMe);
                    },
                  );
                },
              ),
            ),
            _buildChatInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildChatMessage(Map<String, dynamic> data, bool isMe) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe ? AppColors.primary : Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: isMe ? const Radius.circular(0) : null,
            bottomLeft: !isMe ? const Radius.circular(0) : null,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(data['sender'] ?? 'Utilisateur', style: const TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
            Text(data['message'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _buildChatInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.2)),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _chatController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Écrire un message...',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendChatMessage,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
              child: const Icon(Icons.send, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  void _sendChatMessage() {
    final msg = _chatController.text.trim();
    if (msg.isEmpty) return;
    _db.collection('meetings').doc(widget.meetingId).collection('chat').add({
      'sender': widget.userName,
      'senderId': widget.userId,
      'message': msg,
      'timestamp': FieldValue.serverTimestamp(),
    });
    _chatController.clear();
  }


  Widget _buildParticipantsPanel() {
    final isPrivileged = widget.isHost || _isCoHost;
    final total = 1 + _remoteParticipants.length;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 20)],
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Text('Participants ($total)',
                      style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => setState(() => _showParticipants = false),
                  ),
                ],
              ),
            ),
            if (isPrivileged)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, marginBottom: 15),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.mic_off, size: 18),
                        label: const Text('Tout couper'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.withOpacity(0.2),
                          foregroundColor: Colors.orange,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () => _meetingService.triggerMuteAll(widget.meetingId),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: Icon(_isLocked ? Icons.lock_open : Icons.lock, size: 18),
                        label: Text(_isLocked ? 'Déverrouiller' : 'Verrouiller'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.withOpacity(0.2),
                          foregroundColor: Colors.blue,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () => _meetingService.setLocked(widget.meetingId, !_isLocked),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  _buildParticipantRow(_room?.localParticipant?.name ?? widget.userName, widget.userId, isMe: true),
                  ..._remoteParticipants.map((p) => _buildParticipantRow(p.name, p.identity)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParticipantRow(String name, String identity, {bool isMe = false}) {
    final isPrivileged = widget.isHost || _isCoHost;
    final isMainHost = identity == widget.userId && widget.isHost; // This is only true for the organizer

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppColors.primary.withOpacity(0.2),
        child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white)),
      ),
      title: Text(isMe ? '$name (Moi)' : name, style: GoogleFonts.poppins(color: Colors.white, fontSize: 14)),
      subtitle: widget.isHost && identity == widget.userId 
        ? Text('Hôte', style: TextStyle(color: AppColors.primary, fontSize: 11))
        : null,
      trailing: isPrivileged && !isMe && identity != widget.userId ? IconButton(
        icon: const Icon(Icons.more_vert, color: Colors.white54),
        onPressed: () => _showParticipantOptions(name, identity),
      ) : null,
    );
  }

  void _showParticipantOptions(String name, String identity) {
    _db.collection('meetings').doc(widget.meetingId).get().then((doc) {
      if (!mounted || !doc.exists) return;
      final coHosts = List<String>.from(doc.data()?['coHosts'] ?? []);
      final isAlreadyCoHost = coHosts.contains(identity);

      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Container(
          padding: const EdgeInsets.all(20),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A2E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
              const Divider(color: Colors.white12),
              if (widget.isHost) // Only the main host can manage co-hosts
                ListTile(
                  leading: Icon(Icons.admin_panel_settings, color: isAlreadyCoHost ? Colors.orange : Colors.blue),
                  title: Text(isAlreadyCoHost ? 'Retirer co-hôte' : 'Désigner co-hôte', style: const TextStyle(color: Colors.white)),
                  onTap: () {
                    if (isAlreadyCoHost) {
                      _meetingService.removeCoHost(widget.meetingId, identity);
                    } else {
                      _meetingService.addCoHost(widget.meetingId, identity);
                    }
                    Navigator.pop(ctx);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.person_remove, color: Colors.red),
                title: const Text('Retirer de la réunion', style: TextStyle(color: Colors.white)),
                onTap: () {
                  _db.collection('meetings').doc(widget.meetingId).collection('kicked').doc(identity).set({'ts': FieldValue.serverTimestamp()});
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      );
    });
  }


class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ControlBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: active
                  ? Colors.white.withOpacity(0.15)
                  : Colors.red.withOpacity(0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: active ? Colors.white : Colors.red, size: 22),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: GoogleFonts.poppins(color: Colors.white60, fontSize: 9)),
        ],
      ),
    );
  }
}
