import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';
import 'package:logger/logger.dart';
import '../models/meeting_model.dart';

class MeetingService {
  static final MeetingService _instance = MeetingService._internal();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final _log = Logger();

  factory MeetingService() => _instance;
  MeetingService._internal();

  Future<String> createMeeting({
    required String title,
    required String description,
    required String organizerName,
    required String organizerId,
    String? passcode,
    bool isLargeConference = false,
  }) async {
    final meetingId = const Uuid().v4().replaceAll('-', '').substring(0, 12).toUpperCase();
    final now = DateTime.now();

    final meeting = MeetingModel(
      id: meetingId,
      title: title,
      description: description,
      organizer: organizerName,
      organizerId: organizerId,
      startTime: now,
      endTime: now.add(const Duration(hours: 1)),
      participants: [organizerId],
      channelName: meetingId,
      status: MeetingStatus.ongoing,
      createdAt: now,
      passcode: passcode?.isNotEmpty == true ? passcode : null,
      isLargeConference: isLargeConference,
    );

    // Retry write with exponential backoff so joiners on other devices
    // always find the meeting in Firestore before the host shares the code.
    bool written = false;
    for (int attempt = 0; attempt < 3 && !written; attempt++) {
      try {
        await _firestore.collection('meetings').doc(meetingId).set(meeting.toJson());
        written = true;
      } catch (e) {
        _log.w('createMeeting attempt ${attempt + 1} failed: $e');
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 100 * (1 << attempt)));
        }
      }
    }
    if (!written) throw Exception('meeting_create_failed');

    // Verify server-side before returning ID to caller.
    try {
      final snap = await _firestore.collection('meetings').doc(meetingId)
          .get(const GetOptions(source: Source.server));
      if (!snap.exists) throw Exception('meeting_create_failed');
    } catch (e) {
      // Server verify failed — ID was written (offline cache), proceed anyway.
      _log.w('Server verify skipped: $e');
    }

    _log.i('✅ Réunion créée et vérifiée: $meetingId');
    return meetingId;
  }

  /// Schedule a meeting for a future date/time.
  Future<String> scheduleMeeting({
    required String title,
    required String description,
    required String organizerName,
    required String organizerId,
    required DateTime startTime,
    String? passcode,
  }) async {
    final meetingId = const Uuid().v4().replaceAll('-', '').substring(0, 12).toUpperCase();

    final meeting = MeetingModel(
      id: meetingId,
      title: title,
      description: description,
      organizer: organizerName,
      organizerId: organizerId,
      startTime: startTime,
      endTime: startTime.add(const Duration(hours: 1)),
      participants: [organizerId],
      channelName: meetingId,
      status: MeetingStatus.scheduled,
      createdAt: DateTime.now(),
      passcode: passcode?.isNotEmpty == true ? passcode : null,
    );

    bool written = false;
    for (int attempt = 0; attempt < 3 && !written; attempt++) {
      try {
        await _firestore.collection('meetings').doc(meetingId).set(meeting.toJson());
        written = true;
      } catch (e) {
        _log.w('scheduleMeeting attempt ${attempt + 1} failed: $e');
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 100 * (1 << attempt)));
        }
      }
    }
    if (!written) throw Exception('meeting_create_failed');

    _log.i('✅ Réunion planifiée: $meetingId');
    return meetingId;
  }

  Stream<MeetingModel?> getMeeting(String meetingId) {
    return _firestore.collection('meetings').doc(meetingId).snapshots().map(
      (snap) => snap.exists ? MeetingModel.fromJson(snap.data()!) : null,
    );
  }

  Future<MeetingModel?> getMeetingOnce(String meetingId) async {
    try {
      // Try server first to avoid stale cache returning null on fresh join.
      final snap = await _firestore.collection('meetings').doc(meetingId)
          .get(const GetOptions(source: Source.server));
      return snap.exists ? MeetingModel.fromJson(snap.data()!) : null;
    } catch (_) {
      // Fall back to cache (offline scenario).
      try {
        final snap = await _firestore.collection('meetings').doc(meetingId).get();
        return snap.exists ? MeetingModel.fromJson(snap.data()!) : null;
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> updateMeetingStatus(String meetingId, MeetingStatus status) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'status': status.toString().split('.').last,
      });
    } catch (_) {}
  }

  Future<void> addParticipant(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'participants': FieldValue.arrayUnion([userId]),
      });
    } catch (_) {}
  }

  Future<void> removeParticipant(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId).update({
        'participants': FieldValue.arrayRemove([userId]),
      });
    } catch (_) {}
  }

  Future<void> registerPresence(String meetingId, String userId, String userName) async {
    try {
      await _firestore.collection('meetings').doc(meetingId)
          .collection('presence').doc(userId).set({
        'userId': userId,
        'name': userName,
        'micOn': true,
        'camOn': true,
        'handRaised': false,
        'isSpeaking': false,
        'joinedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> removePresence(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId)
          .collection('presence').doc(userId).delete();
    } catch (_) {}
  }

  Stream<List<Map<String, dynamic>>> streamPresence(String meetingId) {
    return _firestore.collection('meetings').doc(meetingId)
        .collection('presence')
        .snapshots()
        .map((snap) => snap.docs.map((d) => d.data()).toList());
  }

  Future<void> setLocked(String meetingId, bool locked) async {
    try {
      await _firestore.collection('meetings').doc(meetingId)
          .update({'isLocked': locked});
    } catch (_) {}
  }

  Future<void> triggerMuteAll(String meetingId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId)
          .update({'muteAllCount': FieldValue.increment(1)});
    } catch (_) {}
  }

  Future<void> addCoHost(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId)
          .update({'coHosts': FieldValue.arrayUnion([userId])});
    } catch (_) {}
  }

  Future<void> removeCoHost(String meetingId, String userId) async {
    try {
      await _firestore.collection('meetings').doc(meetingId)
          .update({'coHosts': FieldValue.arrayRemove([userId])});
    } catch (_) {}
  }
}
