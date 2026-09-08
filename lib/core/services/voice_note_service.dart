import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Records short voice notes and encodes them so they can travel inside an
/// [EmergencyMessage] — over the mesh (offline) exactly like Firestore
/// (online) — for anyone who can't type. Also plays them back.
///
/// Kept low-bitrate mono AAC and capped to [maxDuration] so a clip stays
/// small enough to relay over Bluetooth/Wi-Fi Direct, not just Wi-Fi.
class VoiceNoteService extends ChangeNotifier {
  static const Duration maxDuration = Duration(seconds: 20);

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  bool _isRecording = false;
  Duration _recordedDuration = Duration.zero;
  DateTime? _recordingStartedAt;
  String? _playingMessageId;

  bool get isRecording => _isRecording;
  Duration get recordedDuration => _recordedDuration;
  String? get playingMessageId => _playingMessageId;

  Future<bool> startRecording() async {
    if (_isRecording) return false;
    final granted = await _recorder.hasPermission();
    if (!granted) return false;

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    _isRecording = true;
    _recordingStartedAt = DateTime.now();
    _recordedDuration = Duration.zero;
    notifyListeners();

    // Auto-stop at maxDuration so a held-down finger can't record forever
    // and blow past what the mesh can relay in one hop.
    Future.delayed(maxDuration, () {
      if (_isRecording &&
          _recordingStartedAt != null &&
          DateTime.now().difference(_recordingStartedAt!) >= maxDuration) {
        stopRecording();
      }
    });

    return true;
  }

  /// Stops recording and returns the base64-encoded audio plus its
  /// duration in seconds, or null if the clip was too short to be useful
  /// (an accidental tap) or recording never started.
  Future<({String base64, int durationSeconds})?> stopRecording() async {
    if (!_isRecording) return null;
    final startedAt = _recordingStartedAt;
    final path = await _recorder.stop();
    _isRecording = false;
    final duration = startedAt == null
        ? Duration.zero
        : DateTime.now().difference(startedAt);
    _recordedDuration = Duration.zero;
    _recordingStartedAt = null;
    notifyListeners();

    if (path == null || duration.inMilliseconds < 800) {
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      return null;
    }

    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      return (
        base64: base64Encode(bytes),
        durationSeconds: duration.inSeconds.clamp(1, 999),
      );
    } catch (e) {
      debugPrint('Voice note encode error: $e');
      return null;
    }
  }

  Future<void> cancelRecording() async {
    if (!_isRecording) return;
    await _recorder.cancel();
    _isRecording = false;
    _recordingStartedAt = null;
    _recordedDuration = Duration.zero;
    notifyListeners();
  }

  Future<void> play(String messageId, String audioBase64) async {
    try {
      if (_playingMessageId == messageId) {
        await _player.stop();
        _playingMessageId = null;
        notifyListeners();
        return;
      }
      final bytes = Uint8List.fromList(base64Decode(audioBase64));
      _playingMessageId = messageId;
      notifyListeners();
      await _player.play(BytesSource(bytes));
      _player.onPlayerComplete.listen((_) {
        if (_playingMessageId == messageId) {
          _playingMessageId = null;
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint('Voice note playback error: $e');
      _playingMessageId = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _recorder.dispose();
    _player.dispose();
    super.dispose();
  }
}
