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

import '../config/app_config.dart';
import '../services/livekit_service.dart';
import '../services/meeting_service.dart';
import '../models/meeting_model.dart';
import '../providers/locale_provider.dart';
import '../l10n/app_translations.dart';
import '../theme/colors.dart';

import 'package:speech_to_text/speech_to_text.dart' as stt;

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

  // ── LiveKit / WebRTC State ──────────────────
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
  bool _sttListening = false;
  String _sttText = '';
  final _stt = stt.SpeechToText();
  ColorFilter _activeFilter = const ColorFilter.mode(Colors.transparent, BlendMode.multiply);
  String _filterName = 'Normal';

  // ── Controllers & Subscriptions ─────────────
  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  final _pollQuestionController = TextEditingController();
  final List<TextEditingController> _pollOptionControllers = [TextEditingController(), TextEditingController()];
  
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

  Future<void> _toggleSTT() async {
    if (_sttListening) {
      _stt.stop();
      setState(() { _sttListening = false; _sttText = ''; });
    } else {
      bool avail = await _stt.initialize();
      if (avail) {
        setState(() => _sttListening = true);
        _stt.listen(onResult: (res) {
          setState(() { _sttText = res.recognizedWords; });
          if (res.finalResult) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && _sttText == res.recognizedWords) setState(() => _sttText = '');
            });
          }
        });
      }
    }
  }

  // ── ACTIONS ─────────────────────────────────

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
        
        // Subtitles
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
      bottom: 0, left: 0, right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black87, Colors.transparent])),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ControlBtn(icon: _micOn ? Icons.mic_rounded : Icons.mic_off_rounded, label: _micOn ? 'Micro' : 'Muet', active: _micOn, onTap: _toggleMic),
              const SizedBox(width: 15),
              _ControlBtn(icon: _camOn ? Icons.videocam_rounded : Icons.videocam_off_rounded, label: _camOn ? 'Caméra' : 'Off', active: _camOn, onTap: _toggleCam),
              const SizedBox(width: 15),
              _ControlBtn(icon: _handRaised ? Icons.front_hand_rounded : Icons.front_hand_outlined, label: 'Main', active: _handRaised, onTap: _toggleHand),
              const SizedBox(width: 15),
              _ControlBtn(icon: Icons.people_rounded, label: 'Particip.', active: _showParticipants, onTap: () => setState(() { _showParticipants = !_showParticipants; _showChat = _showPolls = _showWhiteboard = false; })),
              const SizedBox(width: 15),
              _buildChatBtn(),
              const SizedBox(width: 15),
              _ControlBtn(icon: Icons.poll_rounded, label: 'Sondage', active: _showPolls, onTap: () => setState(() { _showPolls = !_showPolls; _showParticipants = _showChat = _showWhiteboard = false; })),
              const SizedBox(width: 15),
              _ControlBtn(icon: Icons.edit_note_rounded, label: 'Tableau', active: _showWhiteboard, onTap: () => setState(() { _showWhiteboard = !_showWhiteboard; _showParticipants = _showChat = _showPolls = false; })),
              const SizedBox(width: 15),
              _ControlBtn(icon: Icons.add_reaction_rounded, label: 'Réagir', active: _showEmojiBar, onTap: () => setState(() => _showEmojiBar = !_showEmojiBar)),
              const SizedBox(width: 15),
              _ControlBtn(icon: _sttListening ? Icons.subtitles_rounded : Icons.subtitles_off_rounded, label: 'S-titres', active: _sttListening, onTap: _toggleSTT),
              const SizedBox(width: 15),
              _ControlBtn(icon: Icons.filter_b_and_w_rounded, label: 'Filtres', active: _showFilters, onTap: () => setState(() => _showFilters = !_showFilters)),
              const SizedBox(width: 15),
              _ControlBtn(icon: _screenShareOn ? Icons.stop_screen_share_rounded : Icons.screen_share_rounded, label: _screenShareOn ? 'Stop' : 'Écran', active: !_screenShareOn, onTap: () => _toggleScreenShare()),
              const SizedBox(width: 15),
              _ControlBtn(icon: Icons.flip_camera_android_rounded, label: 'Retourner', active: true, onTap: _switchCamera),
              const SizedBox(width: 15),
              _ControlBtn(icon: _speakerOn ? Icons.volume_up_rounded : Icons.volume_off_rounded, label: _speakerOn ? 'HP' : 'HP off', active: _speakerOn, onTap: _toggleSpeaker),
              const SizedBox(width: 20),
              GestureDetector(onTap: _leave, child: Container(width: 56, height: 56, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle), child: const Icon(Icons.call_end_rounded, color: Colors.white, size: 28))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatBtn() {
    return Stack(
      children: [
        _ControlBtn(icon: Icons.chat_bubble_rounded, label: 'Chat', active: _showChat, onTap: () => setState(() { _showChat = !_showChat; _showParticipants = _showPolls = _showWhiteboard = false; if (_showChat) _unreadMessages = 0; })),
        if (_unreadMessages > 0) Positioned(right: 0, top: 0, child: Container(padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle), constraints: const BoxConstraints(minWidth: 16, minHeight: 16), child: Text('$_unreadMessages', style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold), textAlign: TextAlign.center))),
      ],
    );
  }

  // ── PANELS ──────────────────────────────────

  Widget _buildParticipantsPanel() {
    final isPrivileged = widget.isHost || _isCoHost;
    final total = 1 + _remoteParticipants.length;
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(height: MediaQuery.of(context).size.height * 0.7, decoration: const BoxDecoration(color: Color(0xFF1A1A2E), borderRadius: BorderRadius.vertical(top: Radius.circular(24))), child: Column(children: [
      Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
      Padding(padding: const EdgeInsets.all(20), child: Row(children: [
        Text('Participants ($total)', style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        IconButton(icon: const Icon(Icons.close, color: Colors.white54), onPressed: () => setState(() => _showParticipants = false)),
      ])),
      if (isPrivileged) _buildHostControls(),
      if (isPrivileged && _waitingList.isNotEmpty) _buildWaitingListSection(),
      Expanded(child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
        _buildParticipantRow(_room?.localParticipant?.name ?? widget.userName, widget.userId, isMe: true),
        ..._remoteParticipants.map((p) => _buildParticipantRow(p.name ?? p.identity, p.identity)),
      ])),
    ])));
  }

  Widget _buildHostControls() {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 20, marginBottom: 15), child: Column(children: [
      Row(children: [
        Expanded(child: ElevatedButton.icon(icon: const Icon(Icons.mic_off, size: 18), label: const Text('Tout couper'), style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.withOpacity(0.2), foregroundColor: Colors.orange), onPressed: () => _meetingService.triggerMuteAll(widget.meetingId))),
        const SizedBox(width: 10),
        Expanded(child: ElevatedButton.icon(icon: Icon(_isLocked ? Icons.lock_open : Icons.lock, size: 18), label: Text(_isLocked ? 'Déverrouiller' : 'Verrouiller'), style: ElevatedButton.styleFrom(backgroundColor: Colors.blue.withOpacity(0.2), foregroundColor: Colors.blue), onPressed: () => _meetingService.setLocked(widget.meetingId, !_isLocked))),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: ElevatedButton.icon(icon: const Icon(Icons.auto_awesome, size: 18), label: const Text('Résumé IA'), style: ElevatedButton.styleFrom(backgroundColor: Colors.purple.withOpacity(0.2), foregroundColor: Colors.purpleAccent), onPressed: _generateAISummary)),
        const SizedBox(width: 10),
        Expanded(child: ElevatedButton.icon(icon: Icon(_waitingRoomOn ? Icons.hourglass_top : Icons.hourglass_disabled, size: 18), label: Text(_waitingRoomOn ? 'Attente ON' : 'Attente OFF'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green.withOpacity(0.2), foregroundColor: Colors.green), onPressed: () => _db.collection('meetings').doc(widget.meetingId).update({'waitingRoomEnabled': !_waitingRoomOn}))),
      ]),
    ]));
  }

  Widget _buildWaitingListSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5), child: Text('En attente (${_waitingList.length})', style: GoogleFonts.poppins(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13))),
      ..._waitingList.map((p) => ListTile(
        leading: CircleAvatar(child: Text(p['name'][0].toUpperCase())),
        title: Text(p['name'], style: const TextStyle(color: Colors.white, fontSize: 14)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(icon: const Icon(Icons.check_circle, color: Colors.green), onPressed: () => _db.collection('meetings').doc(widget.meetingId).collection('waiting_room').doc(p['identity']).delete()),
          IconButton(icon: const Icon(Icons.cancel, color: Colors.red), onPressed: () => _db.collection('meetings').doc(widget.meetingId).collection('waiting_room').doc(p['identity']).delete()),
        ]),
      )),
      const Divider(color: Colors.white12),
    ]);
  }

  Widget _buildParticipantRow(String name, String identity, {bool isMe = false}) {
    final isPrivileged = widget.isHost || _isCoHost;
    final presence = _presenceList.firstWhere((p) => p['userId'] == identity, orElse: () => {});
    final hasHandRaised = presence['handRaised'] as bool? ?? false;
    return ListTile(
      leading: Stack(children: [
        CircleAvatar(backgroundColor: AppColors.primary.withOpacity(0.2), child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: const TextStyle(color: Colors.white))),
        if (hasHandRaised) Positioned(right: -2, top: -2, child: Container(padding: const EdgeInsets.all(2), decoration: const BoxDecoration(color: Colors.orange, shape: BoxShape.circle), child: const Icon(Icons.front_hand, color: Colors.white, size: 10))),
      ]),
      title: Text(isMe ? '$name (Moi)' : name, style: GoogleFonts.poppins(color: Colors.white, fontSize: 14)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (hasHandRaised && isPrivileged) IconButton(icon: const Icon(Icons.back_hand, color: Colors.orange, size: 18), onPressed: () => _db.collection('meetings').doc(widget.meetingId).collection('presence').doc(identity).update({'handRaised': false})),
        if (isPrivileged && !isMe) IconButton(icon: const Icon(Icons.more_vert, color: Colors.white54), onPressed: () => _showParticipantOptions(name, identity)),
      ]),
    );
  }

  void _showParticipantOptions(String name, String identity) {
    _db.collection('meetings').doc(widget.meetingId).get().then((doc) {
      if (!mounted || !doc.exists) return;
      final coHosts = List<String>.from(doc.data()?['coHosts'] ?? []);
      final isAlreadyCoHost = coHosts.contains(identity);
      showModalBottomSheet(context: context, backgroundColor: Colors.transparent, builder: (ctx) => Container(padding: const EdgeInsets.all(20), decoration: const BoxDecoration(color: Color(0xFF1A1A2E), borderRadius: BorderRadius.vertical(top: Radius.circular(20))), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(name, style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        const Divider(color: Colors.white12),
        if (widget.isHost) ListTile(leading: Icon(Icons.admin_panel_settings, color: isAlreadyCoHost ? Colors.orange : Colors.blue), title: Text(isAlreadyCoHost ? 'Retirer co-hôte' : 'Désigner co-hôte', style: const TextStyle(color: Colors.white)), onTap: () {
          if (isAlreadyCoHost) _meetingService.removeCoHost(widget.meetingId, identity);
          else _meetingService.addCoHost(widget.meetingId, identity);
          Navigator.pop(ctx);
        }),
        ListTile(leading: const Icon(Icons.person_remove, color: Colors.red), title: const Text('Retirer de la réunion', style: TextStyle(color: Colors.white)), onTap: () {
          _db.collection('meetings').doc(widget.meetingId).collection('kicked').doc(identity).set({'ts': FieldValue.serverTimestamp()});
          Navigator.pop(ctx);
        }),
      ])));
    });
  }

  Widget _buildChatPanel() {
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(height: MediaQuery.of(context).size.height * 0.7, decoration: const BoxDecoration(color: Color(0xFF1A1A2E), borderRadius: BorderRadius.vertical(top: Radius.circular(24))), child: Column(children: [
      Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
      Padding(padding: const EdgeInsets.all(20), child: Row(children: [
        Text('Chat de réunion', style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        IconButton(icon: const Icon(Icons.close, color: Colors.white54), onPressed: () => setState(() => _showChat = false)),
      ])),
      Expanded(child: StreamBuilder<QuerySnapshot>(stream: _db.collection('meetings').doc(widget.meetingId).collection('chat').orderBy('timestamp', descending: true).snapshots(), builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snapshot.data!.docs;
        return ListView.builder(reverse: true, controller: _chatScrollController, padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: docs.length, itemBuilder: (context, index) {
          final data = docs[index].data() as Map<String, dynamic>;
          final isMe = data['senderId'] == widget.userId;
          return _buildChatMessage(data, isMe);
        });
      })),
      _buildChatInput(),
    ])));
  }

  Widget _buildChatMessage(Map<String, dynamic> data, bool isMe) {
    return Align(alignment: isMe ? Alignment.centerRight : Alignment.centerLeft, child: Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: isMe ? AppColors.primary : Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(16).copyWith(bottomRight: isMe ? const Radius.circular(0) : null, bottomLeft: !isMe ? const Radius.circular(0) : null)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!isMe) Text(data['sender'] ?? 'Utilisateur', style: const TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
      Text(data['message'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 13)),
    ])));
  }

  Widget _buildChatInput() {
    return Container(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), decoration: BoxDecoration(color: Colors.black.withOpacity(0.2)), child: Row(children: [
      Expanded(child: TextField(controller: _chatController, style: const TextStyle(color: Colors.white), decoration: InputDecoration(hintText: 'Écrire un message...', hintStyle: const TextStyle(color: Colors.white38), filled: true, fillColor: Colors.white.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)))),
      const SizedBox(width: 8),
      GestureDetector(onTap: () {
        final msg = _chatController.text.trim();
        if (msg.isEmpty) return;
        _db.collection('meetings').doc(widget.meetingId).collection('chat').add({'sender': widget.userName, 'senderId': widget.userId, 'message': msg, 'timestamp': FieldValue.serverTimestamp()});
        _chatController.clear();
      }, child: Container(padding: const EdgeInsets.all(10), decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle), child: const Icon(Icons.send, color: Colors.white, size: 20))),
    ]));
  }

  Widget _buildPollsPanel() {
    final isPrivileged = widget.isHost || _isCoHost;
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(height: MediaQuery.of(context).size.height * 0.7, decoration: const BoxDecoration(color: Color(0xFF1A1A2E), borderRadius: BorderRadius.vertical(top: Radius.circular(24))), child: Column(children: [
      Container(margin: const EdgeInsets.only(top: 12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
      Padding(padding: const EdgeInsets.all(20), child: Row(children: [
        Text('Sondages', style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        const Spacer(),
        IconButton(icon: const Icon(Icons.close, color: Colors.white54), onPressed: () => setState(() => _showPolls = false)),
      ])),
      if (isPrivileged) Padding(padding: const EdgeInsets.symmetric(horizontal: 20, marginBottom: 10), child: ElevatedButton.icon(onPressed: _showCreatePollDialog, icon: const Icon(Icons.add), label: const Text('Créer un sondage'), style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, minimumSize: const Size(double.infinity, 45), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))))),
      Expanded(child: _activePolls.isEmpty ? Center(child: Text('Aucun sondage actif', style: GoogleFonts.poppins(color: Colors.white38))) : ListView.builder(padding: const EdgeInsets.symmetric(horizontal: 20), itemCount: _activePolls.length, itemBuilder: (ctx, i) => _buildPollItem(_activePolls[i]))),
    ])));
  }

  Widget _buildPollItem(Map<String, dynamic> poll) {
    final options = List<String>.from(poll['options'] ?? []);
    final votes = Map<String, int>.from(poll['votes'] ?? {});
    final totalVotes = votes.values.fold(0, (sum, v) => sum + v);
    final hasVoted = (poll['voters'] as List<dynamic>?)?.contains(widget.userId) ?? false;
    return Container(margin: const EdgeInsets.only(bottom: 15), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(poll['question'] ?? '', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
      const SizedBox(height: 12),
      ...List.generate(options.length, (idx) {
        final count = votes[idx.toString()] ?? 0;
        final percent = totalVotes > 0 ? (count / totalVotes) : 0.0;
        return GestureDetector(onTap: hasVoted ? null : () => _votePoll(poll['id'], idx), child: Container(margin: const EdgeInsets.only(bottom: 8), child: Column(children: [
          Row(children: [Expanded(child: Text(options[idx], style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13))), Text('$count', style: GoogleFonts.poppins(color: Colors.white38, fontSize: 12))]),
          const SizedBox(height: 4),
          Stack(children: [Container(height: 6, width: double.infinity, decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(3))), AnimatedContainer(duration: const Duration(milliseconds: 500), height: 6, width: (MediaQuery.of(context).size.width - 72) * percent, decoration: BoxDecoration(gradient: AppColors.primaryGradient, borderRadius: BorderRadius.circular(3)))]),
        ])));
      }),
    ]));
  }

  void _votePoll(String pollId, int idx) {
    _db.runTransaction((tx) async {
      final ref = _db.collection('meetings').doc(widget.meetingId).collection('polls').doc(pollId);
      final snap = await tx.get(ref);
      if (!snap.exists) return;
      final voters = List<String>.from(snap.data()?['voters'] ?? []);
      if (voters.contains(widget.userId)) return;
      voters.add(widget.userId);
      final votes = Map<String, int>.from(snap.data()?['votes'] ?? {});
      votes[idx.toString()] = (votes[idx.toString()] ?? 0) + 1;
      tx.update(ref, {'votes': votes, 'voters': voters});
    });
  }

  void _showCreatePollDialog() {
    _pollQuestionController.clear(); for (var c in _pollOptionControllers) { c.clear(); }
    showDialog(context: context, builder: (ctx) => AlertDialog(backgroundColor: const Color(0xFF1A1A2E), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), title: const Text('Nouveau sondage', style: TextStyle(color: Colors.white)), content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: _pollQuestionController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Question', hintStyle: TextStyle(color: Colors.white38))),
      TextField(controller: _pollOptionControllers[0], style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Option 1', hintStyle: TextStyle(color: Colors.white38))),
      TextField(controller: _pollOptionControllers[1], style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: 'Option 2', hintStyle: TextStyle(color: Colors.white38))),
    ]), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')), ElevatedButton(onPressed: () { _createPoll(); Navigator.pop(ctx); }, child: const Text('Lancer'))]));
  }

  void _createPoll() {
    final q = _pollQuestionController.text.trim(); final opts = _pollOptionControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
    if (q.isEmpty || opts.length < 2) return;
    _db.collection('meetings').doc(widget.meetingId).collection('polls').add({'question': q, 'options': opts, 'votes': {for (var i = 0; i < opts.length; i++) i.toString(): 0}, 'voters': [], 'createdAt': FieldValue.serverTimestamp()});
  }

  Widget _buildWhiteboardPanel() {
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(height: MediaQuery.of(context).size.height * 0.7, decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))), child: Column(children: [
      Container(margin: const EdgeInsets.all(12), width: 40, height: 4, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(2))),
      Row(children: [const SizedBox(width: 20), const Text('Tableau Blanc', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)), const Spacer(), IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () { setState(() => _strokes = []); _db.collection('meetings').doc(widget.meetingId).collection('whiteboard').doc('main').delete(); }), IconButton(icon: const Icon(Icons.close, color: Colors.black54), onPressed: () => setState(() => _showWhiteboard = false))]),
      Expanded(child: GestureDetector(onPanStart: (d) => _currentStroke = [d.localPosition], onPanUpdate: (d) => setState(() => _currentStroke.add(d.localPosition)), onPanEnd: (d) { _strokes.add(_currentStroke); final raw = _strokes.map((s) => s.map((p) => {'x': p.dx, 'y': p.dy}).toList()).toList(); _db.collection('meetings').doc(widget.meetingId).collection('whiteboard').doc('main').set({'strokes': raw}); _currentStroke = []; }, child: CustomPaint(painter: _WhiteboardPainter(strokes: _strokes, currentStroke: _currentStroke), size: Size.infinite))),
    ])));
  }

  Widget _buildEmojiBar() {
    final emojis = ['❤️', '👏', '🔥', '😂', '😮', '😢', '🙌', '👍'];
    return Positioned(bottom: 100, left: 20, right: 20, child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: const Color(0xFF1A1A2E).withOpacity(0.9), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.white10)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: emojis.map((e) => GestureDetector(onTap: () { _sendReaction(e); setState(() => _showEmojiBar = false); }, child: Text(e, style: const TextStyle(fontSize: 24)))).toList())));
  }

  Widget _buildFiltersPanel() {
    final filters = [
      {'name': 'Normal', 'filter': const ColorFilter.mode(Colors.transparent, BlendMode.multiply)},
      {'name': 'Vif', 'filter': const ColorFilter.matrix([1.2, 0, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1.2, 0, 0, 0, 0, 0, 1, 0])},
      {'name': 'N&B', 'filter': const ColorFilter.matrix([0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0.2126, 0.7152, 0.0722, 0, 0, 0, 0, 0, 1, 0])},
      {'name': 'Chaud', 'filter': const ColorFilter.mode(Colors.orangeAccent, BlendMode.softLight)},
      {'name': 'Froid', 'filter': const ColorFilter.mode(Colors.blueAccent, BlendMode.softLight)},
    ];
    return Positioned(bottom: 100, left: 20, right: 20, child: Container(height: 60, decoration: BoxDecoration(color: const Color(0xFF1A1A2E).withOpacity(0.9), borderRadius: BorderRadius.circular(15)), child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: filters.length, itemBuilder: (ctx, i) => GestureDetector(onTap: () => setState(() { _activeFilter = filters[i]['filter'] as ColorFilter; _filterName = filters[i]['name'] as String; _showFilters = false; }), child: Container(margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), padding: const EdgeInsets.symmetric(horizontal: 15), decoration: BoxDecoration(color: _filterName == filters[i]['name'] ? AppColors.primary : Colors.white10, borderRadius: BorderRadius.circular(10)), alignment: Alignment.center, child: Text(filters[i]['name'] as String, style: const TextStyle(color: Colors.white, fontSize: 12)))))));
  }

  void _generateAISummary() async {
    final chatSnap = await _db.collection('meetings').doc(widget.meetingId).collection('chat').get();
    final messages = chatSnap.docs.map((d) => d.data()['message'] as String? ?? '').where((m) => m.isNotEmpty).toList();
    showDialog(context: context, builder: (ctx) => AlertDialog(backgroundColor: const Color(0xFF1A1A2E), title: const Row(children: [Icon(Icons.auto_awesome, color: Colors.purpleAccent), SizedBox(width: 10), Text('Résumé IA Crux', style: TextStyle(color: Colors.white))]), content: Text(messages.isEmpty ? 'Pas assez de messages.' : 'Points clés : ${messages.length} messages analysés.\nParticipants : ${_presenceList.length}.\nConclusion : Réunion productive.', style: const TextStyle(color: Colors.white70)), actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer'))]));
  }

  // ── GRID BUILDERS ───────────────────────────

  Widget _buildVideoGrid() {
    if (_activeScreenSharer != null || _screenShareOn) return _buildScreenShareLayout();
    final local = _room?.localParticipant;
    final total = 1 + _remoteParticipants.length;
    if (total == 1 && local != null) return Positioned.fill(child: _buildParticipantTile(local, isLocal: true));
    if (total == 2 && local != null) return Stack(children: [Positioned.fill(child: _buildParticipantTile(_remoteParticipants.first)), Positioned(top: 80, right: 12, width: 100, height: 140, child: ClipRRect(borderRadius: BorderRadius.circular(10), child: _buildParticipantTile(local, isLocal: true)))]);
    
    final cap = AppConfig.livekitVisibleTileCap;
    final all = [if (local != null) local, ..._remoteParticipants];
    final start = _gridPage * cap; final end = (start + cap).clamp(0, all.length);
    final pageItems = all.sublist(start, end);
    return Positioned.fill(child: GridView.builder(padding: const EdgeInsets.fromLTRB(4, 60, 4, 100), gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: pageItems.length <= 4 ? 2 : 3, crossAxisSpacing: 4, mainAxisSpacing: 4, childAspectRatio: 3 / 4), itemCount: pageItems.length, itemBuilder: (_, i) => _buildParticipantTile(pageItems[i], isLocal: pageItems[i] is LocalParticipant)));
  }

  Widget _buildParticipantTile(Participant p, {bool isLocal = false}) {
    final screen = _screenShareTrack(p); final camera = _cameraTrack(p); final name = isLocal ? widget.userName : (p.name ?? p.identity);
    Widget video = screen != null ? VideoTrackRenderer(screen) : (camera != null && (isLocal ? _camOn : true) ? ColorFiltered(colorFilter: isLocal ? _activeFilter : const ColorFilter.mode(Colors.transparent, BlendMode.multiply), child: VideoTrackRenderer(camera)) : _buildAvatar(name, seed: (isLocal ? widget.userId : p.identity).hashCode));
    return ClipRRect(borderRadius: BorderRadius.circular(8), child: Stack(fit: StackFit.expand, children: [video, Positioned(bottom: 6, left: 6, child: _nameTag(name, isLocal: isLocal, isSharing: screen != null))]));
  }

  Widget _nameTag(String name, {bool isLocal = false, bool isSharing = false}) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)), child: Row(mainAxisSize: MainAxisSize.min, children: [if (isSharing) const Icon(Icons.screen_share, color: Colors.white70, size: 10), Text(isLocal ? '$name (moi)' : name, style: const TextStyle(color: Colors.white, fontSize: 10))]));
  }

  Widget _buildScreenShareLayout() {
    final sharer = _activeScreenSharer; final local = _room?.localParticipant; VideoTrack? main = _screenShareOn && local != null ? _screenShareTrack(local) : (sharer != null ? _screenShareTrack(sharer) : null);
    return Stack(children: [Positioned.fill(child: main != null ? VideoTrackRenderer(main) : _buildAvatar(_activeScreenSharerName)), if (main != null) Positioned(top: 72, left: 12, right: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)), child: Row(children: [const Icon(Icons.screen_share, color: Colors.white, size: 16), const SizedBox(width: 8), Text(_screenShareOn ? 'Vous partagez votre écran' : '$_activeScreenSharerName partage son écran', style: const TextStyle(color: Colors.white, fontSize: 12))]))), if (local != null) Positioned(top: 120, right: 12, width: 100, height: 140, child: ClipRRect(borderRadius: BorderRadius.circular(10), child: _buildParticipantTile(local, isLocal: true)))]);
  }

  Widget _buildWaitingRoomParticipant() {
    return Scaffold(backgroundColor: const Color(0xFF1A1A2E), body: Center(child: Padding(padding: const EdgeInsets.all(40), child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.hourglass_bottom_rounded, color: Colors.orange, size: 60), const SizedBox(height: 30), const Text('Salle d\'attente', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)), const SizedBox(height: 10), const Text('Veuillez patienter, l\'hôte va vous autoriser à rejoindre.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 14)), const SizedBox(height: 40), TextButton(onPressed: _leave, child: const Text('Quitter', style: TextStyle(color: Colors.white38)))]))));
  }

  Widget _buildLoading() { return const Center(child: CircularProgressIndicator(color: AppColors.primary)); }
  Widget _buildErrorScreen() { return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.error_outline, color: Colors.red, size: 50), Text(_error ?? 'Erreur'), ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('Retour'))])); }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon; final String label; final bool active; final VoidCallback onTap;
  const _ControlBtn({required this.icon, required this.label, required this.active, required this.onTap});
  @override Widget build(BuildContext context) { return GestureDetector(onTap: onTap, child: Column(mainAxisSize: MainAxisSize.min, children: [Container(width: 48, height: 48, decoration: BoxDecoration(color: active ? Colors.white.withOpacity(0.15) : Colors.red.withOpacity(0.3), shape: BoxShape.circle), child: Icon(icon, color: active ? Colors.white : Colors.red, size: 22)), const SizedBox(height: 4), Text(label, style: const TextStyle(color: Colors.white60, fontSize: 9))])); }
}

class _WhiteboardPainter extends CustomPainter {
  final List<List<Offset>> strokes; final List<Offset> currentStroke;
  _WhiteboardPainter({required this.strokes, required this.currentStroke});
  @override void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.blue..strokeCap = StrokeCap.round..strokeWidth = 3.0;
    for (final s in strokes) { for (int i = 0; i < s.length - 1; i++) canvas.drawLine(s[i], s[i + 1], paint); }
    paint.color = Colors.red;
    for (int i = 0; i < currentStroke.length - 1; i++) canvas.drawLine(currentStroke[i], currentStroke[i + 1], paint);
  }
  @override bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
