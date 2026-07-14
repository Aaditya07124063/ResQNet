import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:translator/translator.dart';
import '../models/emergency_message.dart';

class AiService extends ChangeNotifier {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  final GoogleTranslator _translator = GoogleTranslator();

  bool _isListening = false;
  bool get isListening => _isListening;

  static const Map<String, String> supportedLanguages = {
    'English': 'en',
    'Hindi': 'hi',
    'Nepali': 'ne',
    'Bengali': 'bn',
    'Tamil': 'ta',
    'Telugu': 'te',
    'Marathi': 'mr',
    'Gujarati': 'gu',
    'Punjabi': 'pa',
    'Arabic': 'ar',
  };

  static const Map<String, String> _speechLocales = {
    'English': 'en_US',
    'Hindi': 'hi_IN',
    'Nepali': 'ne_NP',
    'Bengali': 'bn_IN',
    'Tamil': 'ta_IN',
    'Telugu': 'te_IN',
    'Marathi': 'mr_IN',
    'Gujarati': 'gu_IN',
    'Punjabi': 'pa_IN',
    'Arabic': 'ar_SA',
  };

  String _getLocaleId(String language) {
    return _speechLocales[language] ?? 'en_US';
  }

  static const Map<EmergencyType, List<String>> _keywords = {
    EmergencyType.medical: [
      'heart', 'blood', 'injury', 'hospital', 'pain',
      'unconscious', 'breathing', 'medical', 'doctor', 'ambulance', 'wounded',
    ],
    EmergencyType.fire: [
      'fire', 'burning', 'smoke', 'flame', 'blaze', 'explosion',
    ],
    EmergencyType.flood: [
      'flood', 'water', 'drowning', 'submerged', 'rain', 'river', 'overflow',
    ],
    EmergencyType.earthquake: [
      'earthquake', 'tremor', 'quake', 'collapse', 'rubble', 'building fell',
    ],
    EmergencyType.trapped: [
      'trapped', 'stuck', 'buried', 'cannot move', 'pinned',
    ],
    EmergencyType.rescue: [
      'rescue', 'help', 'missing', 'lost', 'save me',
    ],
  };

  static const Map<PriorityLevel, List<String>> _priorityKeywords = {
    PriorityLevel.critical: [
      'dying', 'critical', 'urgent', 'immediate', 'life threatening',
      'unconscious', 'not breathing',
    ],
    PriorityLevel.high: [
      'serious', 'severe', 'major', 'bad', 'dangerous', 'emergency',
    ],
    PriorityLevel.medium: [
      'injured', 'hurt', 'trapped', 'need help', 'assistance',
    ],
    PriorityLevel.low: [
      'minor', 'small', 'okay', 'stable',
    ],
  };

  Future<void> startListening({
    required Function(String) onResult,
    String language = 'English',
  }) async {
    try {
      final available = await _speech.initialize(
        onError: (error) => debugPrint('Speech error: $error'),
      );
      if (available) {
        _isListening = true;
        notifyListeners();
        _speech.listen(
          onResult: (result) {
            if (result.finalResult) {
              onResult(result.recognizedWords);
              _isListening = false;
              notifyListeners();
            }
          },
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 5),
          localeId: _getLocaleId(language),
        );
      }
    } catch (e) {
      debugPrint('startListening error: $e');
      _isListening = false;
      notifyListeners();
    }
  }

  Future<void> stopListening() async {
    await _speech.stop();
    _isListening = false;
    notifyListeners();
  }

  Future<String> translateMessage(String text, String targetLanguage) async {
    try {
      final translation = await _translator.translate(text, to: targetLanguage);
      return translation.text;
    } catch (e) {
      debugPrint('Translation error: $e');
      return text;
    }
  }

  Future<void> speak(String text) async {
    try {
      await _tts.setSpeechRate(0.5);
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TTS error: $e');
    }
  }

  EmergencyType classifyEmergency(String message) {
    final lower = message.toLowerCase();
    for (final entry in _keywords.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) return entry.key;
      }
    }
    return EmergencyType.general;
  }

  PriorityLevel assessPriority(String message, EmergencyType type) {
    final lower = message.toLowerCase();
    for (final entry in _priorityKeywords.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) return entry.key;
      }
    }
    if (type == EmergencyType.medical || type == EmergencyType.fire) {
      return PriorityLevel.high;
    }
    return PriorityLevel.medium;
  }

  String generateSuggestion(EmergencyType type) {
    switch (type) {
      case EmergencyType.medical:
        return 'Keep patient calm. Do not move if spinal injury suspected. Apply pressure to wounds.';
      case EmergencyType.fire:
        return 'Stay low, crawl to exit. Do not use elevators. Meet at assembly point.';
      case EmergencyType.flood:
        return 'Move to higher ground immediately. Avoid walking in moving water.';
      case EmergencyType.earthquake:
        return 'Drop, Cover, Hold On. Stay away from windows and exterior walls.';
      case EmergencyType.trapped:
        return 'Stay calm. Make noise to signal rescuers. Conserve energy and air.';
      case EmergencyType.rescue:
        return 'Stay visible. Use whistle or bright cloth to signal rescuers. Conserve energy.';
      case EmergencyType.general:
        return 'Stay calm. Follow official instructions. Help others if safe to do so.';
    }
  }
}