import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../config/app_config.dart';
import '../services/livekit_service.dart';
import '../services/meeting_service.dart';
import '../models/meeting_model.dart';
import '../providers/locale_provider.dart';
import '../l10n/app_translations.dart';
import '../theme/colors.dart';

class _Reaction {
  final String emoji;
  final String id;
  double bottomOffset;
  double opacity;

  _Reaction({required this.emoji})
      : id = DateTime.now().microsecondsSinceEpoch.toString(),
        bottomOffset = 100,
        opacity = 1.0;
}

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

  // ── UI State ────────────────────────────────
  bool _micOn = true;
  bool _camOn = true;
  bool _speakerOn = true;
  bool _screenShareOn = false;
  bool _loading = true;
  String? _error;
  int _gridPage = 0;

  // ── Panels State ────────────────────────────
  bool _showParticipants = false;
  bool _showChat = false;
  bool _showPolls = false;
  bool _showWhiteboard = false;
  bool _showEmojiBar = false;
  bool _showFilters = false;
  bool _handRaised = false;
  bool _isWaiting = false;
  bool _waitingRoomOn = false;
  int _unreadMessages = 0;

  // ── Subtitles State ─────────────────────────
  bool _sttListening = false;
  String _sttText = '';
  final _stt = stt.SpeechToText();

  // ── LiveKit State ───────────────────────────
  List<RemoteParticipant> _remoteParticipants = [];
  RemoteParticipant? _activeScreenSharer;
  String _activeScreenSharerName = '';

  // ── Data State ──────────────────────────────
  bool _isCoHost = false;
  bool _isLocked = false;
  int _lastMuteAllCount = 0;
  List<Map<String, dynamic>> _presenceList = [];
  List<Map<String, dynamic>> _activePolls = [];
  List<Map<String, dynamic>> _waitingList = [];
  List<List<Offset>> _strokes = [];
  List<Offset> _currentStroke = [];
  final List<_Reaction> _reactions = [];
  ColorFilter _activeFilter = const ColorFilter.mode(Colors.transparent, BlendMode.multiply);
  String _filterName = 'Normal';

  // ── Subscriptions ───────────────────────────
  StreamSubscription? _meetingDocSub;
  StreamSubscription? _kickSub;
  StreamSubscription? _chatSub;
  StreamSubscription? _presenceSub;
  StreamSubscription? _pollsSub;
  StreamSubscription? _whiteboardSub;
  StreamSubscription? _waitingSub;
  StreamSubscription? _reactionSub;

  final _db = FirebaseFirestore.instance;
  final _meetingService = MeetingService();
  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  final _pollQuestionController = TextEditingController();
  final List<TextEditingController> _pollOptionControllers = [TextEditingController(), TextEditingController()];

  @override
  void initState() {
    super.initState();
    _init();
    _listenStopShareFromNotification();
    _listenMeetingDoc();
    _listenKicked();
    _listenChat();
    _listenPresence();
    _listenPolls();
    _listenWhiteboard();
    _listenWaitingRoom();
    _listenReactions();
  }

  @override
  void dispose() {
    _setInCall(false);
    _meetingDocSub?.cancel();
    _kickSub?.cancel();
    _chatSub?.cancel();
    _presenceSub?.cancel();
    _pollsSub?.cancel();
    _whiteboardSub?.cancel();
    _waitingSub?.cancel();
    _reactionSub?.cancel();
    _chatController.dispose();
    _chatScrollController.dispose();
    _pollQuestionController.dispose();
    for (var c in _pollOptionControllers) { c.dispose(); }
    _roomListener?.dispose();
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
  }

  // ── INITIALIZATION ──────────────────────────

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
      if (mounted) setState(() => _error = 'Impossible d\'obtenir un token LiveKit.');
      return;
    }

    try {
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultVideoPublishOptions: VideoPublishOptions(simulcast: true),
          defaultAudioPublishOptions: AudioPublishOptions(dtx: true),
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
          if (mounted && event.reason != DisconnectReason.clientInitiated) {
            setState(() => _error = 'Déconnecté: ${event.reason?.name}');
          }
        });

      await room.connect(AppConfig.livekitUrl, token);
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
      if (mounted) setState(() => _error = 'Connexion LiveKit échouée: $e');
    }
  }

  // ── LISTENERS ───────────────────────────────

  void _listenMeetingDoc() {
    _meetingDocSub = _db.collection('meetings').doc(widget.meetingId).snapshots().listen((snap) {
      if (!snap.exists) {
        if (mounted && !widget.isHost) _leave();
        return;
      }
      final data = snap.data()!;
      final coHosts = List<String>.from(data['coHosts'] ?? []);
      final locked = data['isLocked'] as bool? ?? false;
      final muteCount = data['muteAllCount'] as int? ?? 0;
      final waitOn = data['waitingRoomEnabled'] as bool? ?? false;

      if (mounted) {
        setState(() {
          _isCoHost = coHosts.contains(widget.userId);
          _isLocked = locked;
          _waitingRoomOn = waitOn;
        });

        if (waitOn && !widget.isHost && !_isCoHost && _room == null && !_isWaiting) {
           _enterWaitingRoom();
        }

        if (muteCount > _lastMuteAllCount) {
          _lastMuteAllCount = muteCount;
          if (!widget.isHost && !_isCoHost) {
            _room?.localParticipant?.setMicrophoneEnabled(false);
            setState(() => _micOn = false);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('L\'hôte a coupé tous les micros')));
          }
        }
      }
    });
  }

  void _listenKicked() {
    _kickSub = _db.collection('meetings').doc(widget.meetingId)
        .collection('kicked').doc(widget.userId).snapshots().listen((snap) {
      if (snap.exists && mounted) {
        _leave();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vous avez été retiré.')));
      }
    });
  }

  void _listenChat() {
    _chatSub = _db.collection('meetings').doc(widget.meetingId)
        .collection('chat').orderBy('timestamp', descending: true).limit(1).snapshots().listen((snap) {
      if (snap.docs.isNotEmpty && !_showChat && mounted) {
        setState(() => _unreadMessages++);
      }
    });
  }

  void _listenPresence() {
    _presenceSub = _meetingService.streamPresence(widget.meetingId).listen((list) {
      if (mounted) setState(() => _presenceList = list);
    });
  }

  void _listenPolls() {
    _pollsSub = _db.collection('meetings').doc(widget.meetingId)
        .collection('polls').orderBy('createdAt', descending: true).snapshots().listen((snap) {
      if (mounted) setState(() => _activePolls = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList());
    });
  }

  void _listenWhiteboard() {
    _whiteboardSub = _db.collection('meetings').doc(widget.meetingId)
        .collection('whiteboard').doc('main').snapshots().listen((snap) {
      if (snap.exists && mounted) {
        final data = snap.data()!;
        final rawStrokes = List<dynamic>.from(data['strokes'] ?? []);
        setState(() {
          _strokes = rawStrokes.map((s) => (s as List<dynamic>).map((p) => Offset((p['x'] as num).toDouble(), (p['y'] as num).toDouble())).toList()).toList();
        });
      }
    });
  }

  void _listenWaitingRoom() {
    if (widget.isHost) {
      _waitingSub = _db.collection('meetings').doc(widget.meetingId)
          .collection('waiting_room').snapshots().listen((snap) {
        if (mounted) setState(() => _waitingList = snap.docs.map((d) => {'id': d.id, ...d.data()}).toList());
      });
    } else {
      _waitingSub = _db.collection('meetings').doc(widget.meetingId)
          .collection('waiting_room').doc(widget.userId).snapshots().listen((snap) {
        if (!snap.exists && _isWaiting && mounted) {
          setState(() { _isWaiting = false; _loading = true; });
          _init();
        }
      });
    }
  }

  void _listenReactions() {
    _reactionSub = _db.collection('meetings').doc(widget.meetingId)
        .collection('reactions').orderBy('ts', descending: true).limit(5).snapshots().listen((snap) {
      for (final ch in snap.docChanges) {
        if (ch.type == DocumentChangeType.added && mounted) {
          final emoji = ch.doc.data()?['emoji'] as String?;
          if (emoji != null) _spawnReaction(emoji);
        }
      }
    });
  }

  // ── ACTIONS ─────────────────────────────────

  Future<void> _toggleSTT() async {
    if (_sttListening) {
      _stt.stop();
      setState(() { _sttListening = false; _sttText = ''; });
    } else {
      bool avail = await _stt.initialize();
      if (avail) {
        setState(() => _sttListening = true);
        _stt.listen(onResult: (res) {
          if (mounted) {
            setState(() { _sttText = res.recognizedWords; });
            if (res.finalResult) {
              Future.delayed(const Duration(seconds: 3), () {
                if (mounted && _sttText == res.recognizedWords) setState(() => _sttText = '');
              });
            }
          }
        });
      }
    }
  }

  Future<void> _toggleHand() async {
    _handRaised = !_handRaised;
    setState(() {});
    try {
      await _db.collection('meetings').doc(widget.meetingId)
          .collection('presence').doc(widget.userId).update({'handRaised': _handRaised});
      if (_handRaised) HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  void _spawnReaction(String emoji) {
    final r = _Reaction(emoji: emoji);
    setState(() => _reactions.add(r));
    Future.delayed(const Duration(milliseconds: 50), () { if (mounted) setState(() => r.bottomOffset = 400); });
    Future.delayed(const Duration(milliseconds: 1600), () { if (mounted) setState(() => r.opacity = 0.0); });
    Future.delayed(const Duration(milliseconds: 2300), () { if (mounted) setState(() => _reactions.remove(r)); });
  }

  void _sendReaction(String emoji) {
    HapticFeedback.lightImpact();
    _db.collection('meetings').doc(widget.meetingId).collection('reactions').add({
      'emoji': emoji, 'sender': widget.userName, 'ts': FieldValue.serverTimestamp(),
    });
  }

  Future<void> _enterWaitingRoom() async {
    setState(() => _isWaiting = true);
    await _db.collection('meetings').doc(widget.meetingId)
        .collection('waiting_room').doc(widget.userId).set({
      'name': widget.userName, 'identity': widget.userId, 'ts': FieldValue.serverTimestamp(),
    });
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
    setState(() { _activeScreenSharer = sharer; _activeScreenSharerName = name; });
  }

  VideoTrack? _screenShareTrack(Participant p) {
    for (final pub in p.videoTrackPublications) {
      if (pub.source == TrackSource.screenShareVideo && pub.track is VideoTrack) return pub.track as VideoTrack;
    }
    return null;
  }

  VideoTrack? _cameraTrack(Participant p) {
    for (final pub in p.videoTrackPublications) {
      if (pub.source == TrackSource.camera && pub.track is VideoTrack) return pub.track as VideoTrack;
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
    try { await Hardware.instance.setSpeakerphoneOn(_speakerOn); } catch (_) {}
    setState(() {});
  }

  Future<void> _toggleScreenShare({bool forceOff = false}) async {
    if (forceOff && !_screenShareOn) return;
    try {
      final next = forceOff ? false : !_screenShareOn;
      await _room?.localParticipant?.setScreenShareEnabled(next, captureScreenAudio: false);
      _screenShareOn = next;
      if (!kIsWeb && Platform.isAndroid) {
        await _screenChannel.invokeMethod(_screenShareOn ? 'screenShareStarted' : 'screenShareStopped');
      }
      setState(() {});
      _updateScreenShareFocus();
    } catch (e) {
      setState(() => _screenShareOn = false);
    }
  }

  Future<void> _switchCamera() async {
    final track = _room?.localParticipant?.videoTrackPublications
        .where((pub) => pub.track is LocalVideoTrack)
        .map((pub) => pub.track as LocalVideoTrack).firstOrNull;
    if (track == null) return;
    try {
      final devices = await Hardware.instance.enumerateDevices(type: 'videoinput');
      if (devices.length < 2) return;
      final currentDeviceId = track.mediaStreamTrack.getSettings()['deviceId'];
      final nextDevice = devices.firstWhere((d) => d.deviceId != currentDeviceId, orElse: () => devices.first);
      await track.switchCamera(nextDevice.deviceId);
    } catch (_) {}
  }

  void _shareMeeting() {
    final lang = context.read<LocaleProvider>().locale.languageCode;
    final joinUrl = 'https://crux-8aa85.web.app/join/${widget.meetingId}';
    final text = 'Rejoins ma réunion CRUX !\nCode : ${widget.meetingId}\nLien : $joinUrl';
    Share.share(text);
  }

  Future<void> _leave() async {
    if (_screenShareOn) await _toggleScreenShare(forceOff: true);
    await _setInCall(false);
    await _room?.disconnect();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _setInCall(bool inCall) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try { await _pipChannel.invokeMethod('setInCall', {'inCall': inCall}); } catch (_) {}
  }

  void _listenStopShareFromNotification() {
    if (kIsWeb || !Platform.isAndroid) return;
    _screenChannel.setMethodCallHandler((call) async {
      if (call.method == 'stopScreenShareFromNotification' && mounted && _screenShareOn) {
        await _toggleScreenShare(forceOff: true);
      }
    });
  }

  // ── UI BUILDERS ──────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isWaiting) return _buildWaitingRoomParticipant();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _loading ? _buildLoading() : _error != null ? _buildErrorScreen() : _buildCall(),
      ),
    );
  }

  Widget _buildCall() {
    return Stack(
      children: [
        _buildVideoGrid(),
        ..._reactions.map((r) => AnimatedPositioned(
          key: ValueKey(r.id),
          duration: const Duration(milliseconds: 2000),
          bottom: r.bottomOffset,
          right: 30.0 + (math.Random().nextInt(40)),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 1000),
            opacity: r.opacity,
            child: Text(r.emoji, style: const TextStyle(fontSize: 32)),
          ),
        )),
        _buildHeader(),
        _buildBottomControls(),

        if (_sttText.isNotEmpty)
          Positioned(
            bottom: 120, left: 20, right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
              child: Text(_sttText, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
            ),
          ),

        if (_showParticipants) _buildParticipantsPanel(),
        if (_showChat) _buildChatPanel(),
        if (_showPolls) _buildPollsPanel(),
        if (_showWhiteboard) _buildWhiteboardPanel(),
        if (_showEmojiBar) _buildEmojiBar(),
        if (_showFilters) _buildFiltersPanel(),
      ],
    );
  }

  Widget _buildHeader() {
    final total = 1 + _remoteParticipants.length;
    return Positioned(
      top: 0, left: 0, right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black87, Colors.transparent])),
        child: Row(
          children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.meetingName, style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
              Text('${widget.meetingId} • $total/${AppConfig.livekitMaxParticipants}', style: GoogleFonts.poppins(color: Colors.white60, fontSize: 11)),
            ])),
            IconButton(icon: const Icon(Icons.copy_rounded, color: Colors.white54, size: 18), onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.meetingId));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ID copié'), duration: Duration(seconds: 2)));
            }),
            IconButton(icon: const Icon(Icons.share_rounded, color: Colors.white54, size: 18), onPressed: _shareMeeting),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: