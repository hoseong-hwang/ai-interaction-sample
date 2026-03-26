import 'dart:async';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class SpeechToTextPage extends StatefulWidget {
  const SpeechToTextPage({super.key});

  @override
  State<SpeechToTextPage> createState() => _SpeechToTextPageState();
}

class _SpeechToTextPageState extends State<SpeechToTextPage> {
  static const Duration? _pauseFor = Duration(seconds: 3);
  static const Duration _listenFor = Duration(seconds: 30);
  static const ListenMode _listenMode = ListenMode.confirmation;
  static const bool _partialResults = true;

  final SpeechToText _stt = SpeechToText();

  bool _ready = false;
  bool _listening = false;
  String _status = 'init';
  String _words = '';
  SpeechRecognitionError? _lastError;

  void _log(String msg) {
    final line = '${DateTime.now().toIso8601String()} | $msg';
    debugPrint(line);
  }

  Future<void> _ensureReady() async {
    if (_ready) return;
    await _init();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      _log('STT initialize()...');
      _ready = await _stt.initialize(
        onStatus: (s) {
          _status = s;
          _log('status=$s');
          if (!mounted) return;
          setState(() {
            _listening = s == 'listening';
          });
        },
        onError: (e) {
          _lastError = e;
          _log('error=${e.errorMsg}, permanent=${e.permanent}');
          if (!mounted) return;
          setState(() {});
        },
      );
      _log('STT ready=$_ready');
    } catch (e, st) {
      _log('STT init 실패: $e\n$st');
      _ready = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleMic() async {
    await _ensureReady();
    if (!_ready) return;

    if (_stt.isListening) {
      _log('stop() (user)');
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }

    _words = '';
    _lastError = null;
    _log(
      'listen(pauseFor=$_pauseFor, listenFor=$_listenFor, '
      'mode=$_listenMode, partial=$_partialResults)',
    );

    try {
      await _stt.listen(
        localeId: 'ko_KR',
        listenFor: _listenFor,
        pauseFor: _pauseFor,
        listenMode: _listenMode,
        partialResults: _partialResults,
        onResult: (SpeechRecognitionResult r) {
          final w = r.recognizedWords.trim();
          _log(
            'result[${r.finalResult ? "final" : "partial"}]=${w.isEmpty ? "(empty)" : w}',
          );
          if (!mounted) return;
          setState(() {
            // "그대로 화면에 출력" 목적: 비어있지 않은 결과는 즉시 반영
            if (w.isNotEmpty) _words = w;
          });
        },
      );
      if (mounted) setState(() => _listening = true);
    } catch (e, st) {
      _log('listen 실패: $e\n$st');
    }
  }

  @override
  void dispose() {
    unawaited(_stt.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isListening = _stt.isListening || _listening;

    return Scaffold(
      appBar: AppBar(title: const Text('Speech To Text')),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleMic,
        icon: Icon(isListening ? Icons.mic_off_rounded : Icons.mic_rounded),
        label: Text(isListening ? '중지' : '마이크'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Text('ready=$_ready'), Text('status=$_status')],
              ),
            ),
            if (_lastError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'error: ${_lastError!.errorMsg} (permanent=${_lastError!.permanent})',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
                  child: Text(
                    _words.isEmpty ? '하단 마이크 버튼을 누르고 말해보세요' : _words,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
