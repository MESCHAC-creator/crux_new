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

  @override
  void initState() {
    super.initState();
    _init();
    _listenStopShareFromNotification();
  }

  @override
  void dispose() {
    _setInCall(false);
    _roomListener?.dispose();
    _room?.disconnect();
    _room?.dispose();
    super.dispose();
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
    await track?.switchCamera();
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ControlBtn(
                  icon: _micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                  label: _micOn ? 'Micro' : 'Muet',
                  active: _micOn,
                  onTap: _toggleMic,
                ),
                _ControlBtn(
                  icon: _camOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  label: _camOn ? 'Caméra' : 'Off',
                  active: _camOn,
                  onTap: _toggleCam,
                ),
                _ControlBtn(
                  icon: _screenShareOn
                      ? Icons.stop_screen_share_rounded
                      : Icons.screen_share_rounded,
                  label: _screenShareOn ? 'Stop' : 'Écran',
                  active: !_screenShareOn,
                  onTap: () => _toggleScreenShare(),
                ),
                _ControlBtn(
                  icon: Icons.flip_camera_android_rounded,
                  label: 'Retourner',
                  active: true,
                  onTap: _switchCamera,
                ),
                _ControlBtn(
                  icon: _speakerOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                  label: _speakerOn ? 'HP' : 'HP off',
                  active: _speakerOn,
                  onTap: _toggleSpeaker,
                ),
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
      ],
    );
  }
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
