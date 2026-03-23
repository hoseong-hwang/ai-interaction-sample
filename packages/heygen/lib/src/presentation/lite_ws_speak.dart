import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:web_socket_channel/web_socket_channel.dart';

/// LiveAvatar LITE: [PCM 16-bit 24kHz](https://docs.liveavatar.com/docs/custom-mode-events) Base64 → `agent.speak`.
///
/// 공식 문서: `agent.speak` 오디오는 **PCM 16-bit 24kHz** Base64, 권장 청크 ~1초(문자열 >1MB 시 연결 종료 가능).
/// 서버는 `session.state_updated` 로 `state` 를 보내며, **이벤트 전송 전** `state == "connected"` 일 것을 요구함.
const int _kTargetRate = 24000;

/// 텍스트를 TTS로 WAV 생성 → PCM으로 파싱·리샘플 → WebSocket `agent.speak` / `agent.speak_end`.
///
/// **LITE에서 “텍스트로 말하기”는 이 경로가 맞습니다.** 서버에 텍스트만 보내는 API가 없고,
/// [문서](https://docs.liveavatar.com/docs/custom-mode-events)대로 **PCM 16-bit 24kHz** 를
/// `agent.speak` 로 보냅니다. (FULL 의 `avatar.speak_text` 와는 다름)
Future<void> sendLiteSpeakTextViaWebSocket({
  required WebSocketChannel channel,
  required String text,
  Duration waitForConnected = const Duration(seconds: 25),
  int chunkSizeBytes = 48000, // 24kHz * 16bit * 1ch * 1s
  Duration interChunkDelay = const Duration(milliseconds: 10),
}) async {
  // 일부 런타임에서 WebSocket stream 이 이미 단일 구독 상태라 listen 자체가 실패할 수 있다.
  // 여기서는 상태 이벤트 구독을 생략하고 바로 전송한다. (세션/전송 실패는 서버 응답 이벤트로 확인)
  if (waitForConnected > Duration.zero) {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  final pcm24k = await _textToPcm24kBytes(text);
  final eventId = 'flutter-${DateTime.now().millisecondsSinceEpoch}';

  final safeChunk = chunkSizeBytes <= 0 ? 48000 : chunkSizeBytes;
  var sent = 0;
  for (var i = 0; i < pcm24k.length; i += safeChunk) {
    final end = (i + safeChunk < pcm24k.length) ? i + safeChunk : pcm24k.length;
    final chunk = pcm24k.sublist(i, end);
    channel.sink.add(
      jsonEncode(<String, dynamic>{
        'type': 'agent.speak',
        'audio': base64Encode(chunk),
        'event_id': eventId,
      }),
    );
    sent++;
    if (interChunkDelay > Duration.zero && end < pcm24k.length) {
      await Future<void>.delayed(interChunkDelay);
    }
  }
  channel.sink.add(
    jsonEncode(<String, dynamic>{
      'type': 'agent.speak_end',
      'event_id': eventId,
    }),
  );
  debugPrint('LiveAvatar LITE: agent.speak($sent chunks) + speak_end 전송 완료');
}

/// [sendLiteSpeakTextViaWebSocket] 과 동일. LITE 텍스트 발화용 진입점 이름.
Future<void> liveAvatarLiteSpeakFromText({
  required WebSocketChannel channel,
  required String text,
  Duration waitForConnected = const Duration(seconds: 25),
}) => sendLiteSpeakTextViaWebSocket(
  channel: channel,
  text: text,
  waitForConnected: waitForConnected,
);

/// iOS: `flutter_tts` 는 **세 번째 인자 `isFullPath: true`** 가 없으면 파일명만 Documents 에 씀.
/// 또한 **`awaitSynthCompletion(true)`** 없으면 파일 쓰기 전에 Future 가 끝날 수 있음.
Future<Uint8List> _textToPcm24kBytes(String text) async {
  final tts = FlutterTts();
  await tts.setLanguage('ko-KR');
  await tts.setSpeechRate(0.45);
  await tts.awaitSynthCompletion(true);

  // `path_provider`(iOS objective_c FFI) 로딩 실패를 피하기 위해 Dart systemTemp 사용.
  final dir = Directory.systemTemp;
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  // iOS AVAudioFile 은 확장자에 따라 RIFF WAV 대신 **CAF** 로 쓰는 경우가 많음.
  final ext = Platform.isIOS ? 'caf' : 'wav';
  final path =
      '${dir.path}/liveavatar_lite_${DateTime.now().millisecondsSinceEpoch}.$ext';

  final result = await tts.synthesizeToFile(text, path, true);
  if (result != 1 && result != true && result != 'success') {
    debugPrint('LiveAvatar LITE TTS: synthesizeToFile result=$result');
  }

  final file = File(path);
  await _waitForTtsFile(file);

  File? readFrom = file;
  if (!await file.exists()) {
    // 일부 iOS 구현은 basename만 사용해 현재 작업 디렉터리/임시폴더에 떨어뜨릴 수 있음.
    final byBasename = File(p.basename(path));
    if (await byBasename.exists()) {
      readFrom = byBasename;
    }
  }

  if (!await readFrom.exists()) {
    throw StateError(
      'TTS 출력 파일이 없습니다. (isFullPath=true, awaitSynthCompletion 확인)\n'
      '$path',
    );
  }

  final wavBytes = await readFrom.readAsBytes();
  try {
    if (await file.exists()) await file.delete();
    if (readFrom.path != file.path && await readFrom.exists()) {
      await readFrom.delete();
    }
  } catch (_) {}

  final parsed = _parseTtsAudioFile(wavBytes);
  if (parsed == null) {
    final head = wavBytes.length > 32 ? wavBytes.sublist(0, 32) : wavBytes;
    debugPrint('LiveAvatar LITE TTS: 오디오 파싱 실패, 헤더(hex)=${_hexDump(head)}');
    throw StateError('TTS 오디오 파싱 실패 (WAV/CAF 확인)');
  }

  final pcm24k = _resampleTo24kMonoPcm16(
    parsed.pcmInterleaved,
    parsed.sampleRate,
    parsed.channels,
  );
  return pcm24k;
}

/// `synthesizeToFile` 직후 비동기로 파일이 닫힐 때까지 대기.
Future<void> _waitForTtsFile(File file) async {
  for (var i = 0; i < 100; i++) {
    if (await file.exists() && await file.length() > 0) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class _ParsedWav {
  _ParsedWav({
    required this.pcmInterleaved,
    required this.sampleRate,
    required this.channels,
  });

  final Uint8List pcmInterleaved;
  final int sampleRate;
  final int channels;
}

String _hexDump(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');

_ParsedWav? _parseTtsAudioFile(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final sig = String.fromCharCodes(bytes.sublist(0, 4));
  if (sig == 'RIFF') {
    return _parseWavPcm(bytes);
  }
  if (sig == 'caff') {
    return _parseCafPcm(bytes);
  }
  return null;
}

/// iOS AVAudioFile 은 **IEEE float 32 WAV** 를 쓸 수 있음 (PCM 16 아님).
_ParsedWav? _parseWavPcm(Uint8List bytes) {
  if (bytes.length < 44) return null;
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF') return null;

  int i = 12;
  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  int? audioFormat;
  Uint8List? pcm;

  while (i + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(i, i + 4));
    final size = ByteData.sublistView(
      bytes,
      i + 4,
      i + 8,
    ).getUint32(0, Endian.little);
    final dataOffset = i + 8;
    if (id == 'fmt ') {
      if (dataOffset + 16 > bytes.length) return null;
      audioFormat = ByteData.sublistView(
        bytes,
        dataOffset,
        dataOffset + 2,
      ).getUint16(0, Endian.little);
      channels = ByteData.sublistView(
        bytes,
        dataOffset + 2,
        dataOffset + 4,
      ).getUint16(0, Endian.little);
      sampleRate = ByteData.sublistView(
        bytes,
        dataOffset + 4,
        dataOffset + 8,
      ).getUint32(0, Endian.little);
      bitsPerSample = ByteData.sublistView(
        bytes,
        dataOffset + 14,
        dataOffset + 16,
      ).getUint16(0, Endian.little);
    } else if (id == 'data') {
      if (dataOffset + size > bytes.length) return null;
      pcm = bytes.sublist(dataOffset, dataOffset + size);
    }
    final pad = size.isOdd ? 1 : 0;
    i = dataOffset + size + pad;
  }

  if (pcm == null || sampleRate == null || channels == null) {
    return null;
  }

  // 1 = PCM, 3 = IEEE float (iOS TTS 파일)
  final isFloat =
      audioFormat == 3 ||
      (bitsPerSample != null && bitsPerSample == 32 && audioFormat != 1);

  if (bitsPerSample == 16 && audioFormat == 1) {
    return _ParsedWav(
      pcmInterleaved: pcm,
      sampleRate: sampleRate,
      channels: channels,
    );
  }

  if (isFloat && pcm.length >= 4) {
    final pcm16 = _float32InterleavedToPcm16Mono(pcm, channels);
    return _ParsedWav(
      pcmInterleaved: pcm16,
      sampleRate: sampleRate,
      channels: 1,
    );
  }

  return null;
}

/// Core Audio **CAF** (`caff` … `desc` + `data`).
/// [desc](https://developer.apple.com/documentation/coreaudio/audiostreambasicdescription) 에서 샘플레이트·채널·float 여부.
///
/// iOS `flutter_tts` 는 **32바이트 desc**(mBitsPerChannel 없음) + `data` 가 흔함.
_ParsedWav? _parseCafPcm(Uint8List bytes) {
  if (bytes.length < 32) return null;
  if (String.fromCharCodes(bytes.sublist(0, 4)) != 'caff') return null;

  double sampleRate = 0;
  var channels = 1;
  var bitsPerChannel = 16;
  var isFloat = false;
  Uint8List? pcmData;

  // flutter_tts(iOS)의 일반적인 레이아웃: caff(8) + desc(12+32) + data...
  // desc는 가능하면 읽고, data는 헤더 시그니처를 스캔해서 안전하게 찾는다.
  if (bytes.length >= 52 &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'desc') {
    final descSize = _readUint64BE(bytes, 12);
    if (descSize >= 32 && 20 + 32 <= bytes.length) {
      final descLen = descSize < 36 ? descSize : 36;
      final bd = ByteData.sublistView(bytes, 20, 20 + descLen);
      sampleRate = _readAsbdSampleRate(bd);
      final ffLe = bd.getUint32(12, Endian.little);
      final ffBe = bd.getUint32(12, Endian.big);
      isFloat = (ffLe & 1) != 0 || (ffBe & 1) != 0;
      // CAF desc(32) 오프셋:
      // sampleRate@0, formatID@8, formatFlags@12, bytesPerPacket@16,
      // framesPerPacket@20, channelsPerFrame@24, bitsPerChannel@28
      channels = _pickAsbdUint32(bd, 24, minV: 1, maxV: 32);
      bitsPerChannel = _pickAsbdUint32(bd, 28, minV: 8, maxV: 64);

      // bits 필드가 비정상이면 bytesPerPacket/framesPerPacket로 보정
      if (bitsPerChannel < 8 || bitsPerChannel > 64) {
        final bpp = _pickAsbdUint32(bd, 16, minV: 1, maxV: 1024);
        final fpp = _pickAsbdUint32(bd, 20, minV: 1, maxV: 32);
        final bytesPerFrame = (bpp / fpp).round();
        if (channels > 0 &&
            bytesPerFrame > 0 &&
            bytesPerFrame % channels == 0) {
          final b = (bytesPerFrame * 8) ~/ channels;
          if (b >= 8 && b <= 64) {
            bitsPerChannel = b;
          }
        }
      }
    }
  }

  // `data` 청크를 선형 스캔.
  // 사이즈가 비정상이면(손상/플러그인 변형) EOF까지를 PCM으로 간주해 최대한 복구한다.
  for (var off = 8; off + 12 <= bytes.length; off++) {
    if (bytes[off] != 0x64 || // d
        bytes[off + 1] != 0x61 || // a
        bytes[off + 2] != 0x74 || // t
        bytes[off + 3] != 0x61) {
      continue;
    }
    final dataStart = off + 12;
    if (dataStart >= bytes.length) {
      continue;
    }
    final size = _readUint64BE(bytes, off + 4);
    final maxReadable = bytes.length - dataStart;
    final useSize = size > 0 && size <= maxReadable ? size : maxReadable;
    if (useSize <= 0) {
      continue;
    }
    // CAF data chunk payload: [edit_count:4][audio_data...]
    if (useSize <= 4) {
      continue;
    }
    final pcmStart = dataStart + 4;
    final pcmEnd = dataStart + useSize;
    if (pcmStart >= pcmEnd || pcmEnd > bytes.length) {
      continue;
    }
    pcmData = bytes.sublist(pcmStart, pcmEnd);
    break;
  }

  if (pcmData == null || pcmData.isEmpty || sampleRate <= 0) {
    return null;
  }

  final sr = sampleRate.round().clamp(8000, 192000);

  if (isFloat && pcmData.length >= 4) {
    if (channels <= 0 || channels > 32) {
      channels = 1;
    }
    if (pcmData.length % (4 * channels) != 0) {
      // 길이가 깔끔히 안 나눠져도 가능한 프레임만 사용 (iOS TTS 변형 복구)
      final frameBytes = 4 * channels;
      final usable = pcmData.length - (pcmData.length % frameBytes);
      if (usable >= frameBytes) {
        pcmData = pcmData.sublist(0, usable);
      }
    }
  }

  if (isFloat && pcmData.length >= 4 && pcmData.length % (4 * channels) == 0) {
    final pcm16 = _float32InterleavedToPcm16Mono(pcmData, channels);
    return _ParsedWav(pcmInterleaved: pcm16, sampleRate: sr, channels: 1);
  }
  if (!isFloat && bitsPerChannel == 16) {
    final mono = channels <= 1
        ? pcmData
        : _int16InterleavedToMono(pcmData, channels);
    return _ParsedWav(pcmInterleaved: mono, sampleRate: sr, channels: 1);
  }

  return null;
}

/// CAF 청크 크기(8바이트 big-endian **unsigned 64**).
///
/// `int` 시프트/`hi * 2^32` 는 VM에서 오버플로·부호 이슈가 나므로 [BigInt]로만 조합한다.
int _readUint64BE(Uint8List bytes, int offset) {
  if (offset + 8 > bytes.length) {
    return 0;
  }
  var r = BigInt.zero;
  for (var i = 0; i < 8; i++) {
    r = (r << 8) + BigInt.from(bytes[offset + i]);
  }
  // 실제 CAF 청크 크기는 파일 길이 이하; int 연산용으로 clamp (toInt는 2^63-1 초과 시 예외)
  const maxInt64 = 9223372036854775807; // 0x7FFFFFFFFFFFFFFF
  if (r > BigInt.from(maxInt64)) {
    return maxInt64;
  }
  return r.toInt();
}

double _readAsbdSampleRate(ByteData bd) {
  var r = bd.getFloat64(0, Endian.little);
  if (!r.isNaN && r >= 8000 && r <= 192000) {
    return r;
  }
  r = bd.getFloat64(0, Endian.big);
  if (!r.isNaN && r >= 8000 && r <= 192000) {
    return r;
  }
  return 0;
}

int _pickAsbdUint32(
  ByteData bd,
  int offset, {
  required int minV,
  required int maxV,
}) {
  final a = bd.getUint32(offset, Endian.little);
  final b = bd.getUint32(offset, Endian.big);
  if (a >= minV && a <= maxV) {
    return a;
  }
  if (b >= minV && b <= maxV) {
    return b;
  }
  return a != 0 ? a : b;
}

Uint8List _int16InterleavedToMono(Uint8List interleaved, int channels) {
  final frames = interleaved.length ~/ 2 ~/ channels;
  final bd = ByteData.sublistView(interleaved);
  final out = ByteData(frames * 2);
  for (var f = 0; f < frames; f++) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += bd.getInt16((f * channels + c) * 2, Endian.little);
    }
    out.setInt16(
      f * 2,
      (sum / channels).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return out.buffer.asUint8List();
}

Uint8List _float32InterleavedToPcm16Mono(Uint8List raw, int channels) {
  final bd = ByteData.sublistView(raw);
  final frames = raw.length ~/ 4 ~/ channels;
  final out = ByteData(frames * 2);
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      sum += bd.getFloat32((f * channels + c) * 4, Endian.little);
    }
    final v = (sum / channels) * 32767.0;
    out.setInt16(f * 2, v.round().clamp(-32768, 32767), Endian.little);
  }
  return out.buffer.asUint8List();
}

Uint8List _resampleTo24kMonoPcm16(
  Uint8List interleaved,
  int fromRate,
  int channels,
) {
  final frameCount = interleaved.length ~/ 2 ~/ channels;
  final bd = ByteData.sublistView(interleaved);
  final mono = List<int>.generate(frameCount, (f) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += bd.getInt16((f * channels + c) * 2, Endian.little);
    }
    return (sum / channels).round().clamp(-32768, 32767);
  });

  if (fromRate == _kTargetRate) {
    return _int16ListToBytes(mono);
  }

  final ratio = fromRate / _kTargetRate;
  final outLen = (mono.length / ratio).floor().clamp(1, 1 << 30);
  final out = List<int>.filled(outLen, 0);
  for (var i = 0; i < outLen; i++) {
    final srcPos = i * ratio;
    final idx = srcPos.floor();
    final frac = srcPos - idx;
    final s0 = mono[idx];
    final s1 = idx + 1 < mono.length ? mono[idx + 1] : s0;
    out[i] = (s0 + (s1 - s0) * frac).round().clamp(-32768, 32767);
  }
  return _int16ListToBytes(out);
}

Uint8List _int16ListToBytes(List<int> samples) {
  final bd = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(i * 2, samples[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}
