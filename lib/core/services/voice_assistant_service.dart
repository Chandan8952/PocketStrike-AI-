import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Riverpod provider for VoiceAssistantService
final voiceAssistantServiceProvider = Provider<VoiceAssistantService>((ref) {
  final service = VoiceAssistantService();
  ref.onDispose(service.dispose);
  return service;
});

enum VoiceState { idle, listening, speaking }

/// Unified Voice Assistant Service handling both Speech-to-Text (STT)
/// and Text-to-Speech (TTS) for hands-free AI interaction.
class VoiceAssistantService {
  VoiceAssistantService() {
    _initTts();
  }

  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isSpeechInitialized = false;
  VoiceState _state = VoiceState.idle;
  VoiceState get state => _state;

  final _stateController = StreamController<VoiceState>.broadcast();
  Stream<VoiceState> get stateStream => _stateController.stream;

  void _setState(VoiceState s) {
    _state = s;
    _stateController.add(s);
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('hi-IN');
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.9);

      _tts.setCompletionHandler(() {
        _setState(VoiceState.idle);
      });
      _tts.setErrorHandler((msg) {
        _setState(VoiceState.idle);
      });
    } catch (e) {
      debugPrint('TTS init error: $e');
    }
  }

  /// Initialize Speech-to-Text engine.
  Future<bool> initSpeech() async {
    if (_isSpeechInitialized) return true;
    try {
      _isSpeechInitialized = await _speech.initialize(
        onError: (err) {
          debugPrint('Speech error: $err');
          _setState(VoiceState.idle);
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            if (_state == VoiceState.listening) {
              _setState(VoiceState.idle);
            }
          }
        },
      );
      return _isSpeechInitialized;
    } catch (e) {
      debugPrint('Failed to initialize speech: $e');
      return false;
    }
  }

  /// Starts listening to microphone and streams recognized text.
  Future<void> startListening({
    required Function(String recognizedWords, bool isFinal) onResult,
    String localeId = 'hi_IN',
  }) async {
    // If speaking, stop speaking first
    if (_state == VoiceState.speaking) {
      await stopSpeaking();
    }

    final hasInit = await initSpeech();
    if (!hasInit) return;

    _setState(VoiceState.listening);
    await _speech.listen(
      localeId: localeId,
      onResult: (result) {
        onResult(result.recognizedWords, result.finalResult);
        if (result.finalResult) {
          _setState(VoiceState.idle);
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 3),
      listenOptions: SpeechListenOptions(
        cancelOnError: true,
        partialResults: true,
      ),
    );
  }

  /// Stop active microphone listening.
  Future<void> stopListening() async {
    if (_state == VoiceState.listening) {
      await _speech.stop();
      _setState(VoiceState.idle);
    }
  }

  /// Speaks text response out loud using TTS.
  Future<void> speak(
    String text, {
    String language = 'hi-IN',
    double pitch = 1.0,
    double rate = 0.9,
  }) async {
    if (text.trim().isEmpty) return;

    if (_state == VoiceState.listening) {
      await stopListening();
    }

    try {
      _setState(VoiceState.speaking);
      await _tts.setLanguage(language);
      await _tts.setPitch(pitch);
      await _tts.setSpeechRate(rate);

      // Clean markdown symbols from spoken text (e.g. asterisks, hashes, backticks)
      final cleanText = text
          .replaceAll(RegExp(r'\*|_|`|#'), '')
          .replaceAll(RegExp(r'\[.*?\]\(.*?\)'), '')
          .trim();

      await _tts.speak(cleanText);
    } catch (e) {
      debugPrint('Error speaking text: $e');
      _setState(VoiceState.idle);
    }
  }

  /// Stop active TTS speech.
  Future<void> stopSpeaking() async {
    if (_state == VoiceState.speaking) {
      await _tts.stop();
      _setState(VoiceState.idle);
    }
  }

  void dispose() {
    _speech.cancel();
    _tts.stop();
    _stateController.close();
  }
}
