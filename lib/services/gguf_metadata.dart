import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Architecture details read from a GGUF file's header, used to estimate how
/// much memory a model needs before loading it.
class GgufInfo {
  final String architecture;
  final String? name;
  final int layers;
  final int trainedContext;
  final int embeddingLength;
  final int headCount;
  final int headCountKv;
  final int? keyLength;
  final int? valueLength;
  final int fileBytes;

  /// Sliding-window attention: window size, per-layer pattern (true = SWA
  /// layer), SWA head sizes, and how many trailing layers reuse earlier
  /// layers' KV (Gemma 3n / 4). llama.cpp keeps SWA layers at their window
  /// (swa_full off) and allocates no KV for shared layers.
  final int? slidingWindow;
  final List<bool>? swaPattern;
  final int? keyLengthSwa;
  final int? valueLengthSwa;
  final int sharedKvLayers;

  const GgufInfo({
    required this.architecture,
    required this.name,
    required this.layers,
    required this.trainedContext,
    required this.embeddingLength,
    required this.headCount,
    required this.headCountKv,
    required this.keyLength,
    required this.valueLength,
    required this.fileBytes,
    this.slidingWindow,
    this.swaPattern,
    this.keyLengthSwa,
    this.valueLengthSwa,
    this.sharedKvLayers = 0,
  });

  int get _headDimK =>
      keyLength ?? (headCount > 0 ? embeddingLength ~/ headCount : 0);
  int get _headDimV =>
      valueLength ?? (headCount > 0 ? embeddingLength ~/ headCount : 0);

  /// Bytes of KV cache for [contextTokens] (f16 K and V, as llama.cpp uses
  /// by default). Sliding-window layers only hold their window (+ one
  /// micro-batch); layers that share earlier layers' KV hold nothing.
  int kvCacheBytes(int contextTokens) {
    const bytesPerElement = 2;
    final kvLayers = (layers - sharedKvLayers).clamp(0, layers);
    final window = slidingWindow;
    final pattern = swaPattern;
    var total = 0;
    for (var i = 0; i < kvLayers; i++) {
      final swa = window != null && pattern != null && i < pattern.length && pattern[i];
      if (swa) {
        final cells = contextTokens < window + 512 ? contextTokens : window + 512;
        total += cells * headCountKv *
            ((keyLengthSwa ?? _headDimK) + (valueLengthSwa ?? _headDimV)) * bytesPerElement;
      } else {
        total += contextTokens * headCountKv * (_headDimK + _headDimV) * bytesPerElement;
      }
    }
    return total;
  }

  /// Working memory beyond weights + KV cache: compute buffers, GPU driver
  /// allocations, the runtime itself and allocator slack. Calibrated on a
  /// Pixel 8 (Vulkan): Qwen2.5-1.5B Q4_K_M at 4096 ctx grew the app by
  /// ~1813 MB = 1066 MB weights + 112 MB KV + ~635 MB overhead. Errs high,
  /// since under-estimating is what leads to out-of-memory kills.
  int overheadBytes(int contextTokens) =>
      400 * _mb + (fileBytes * 0.2).round() + contextTokens * 4 * _kb;

  /// Estimated resident memory to load the model and use [contextTokens].
  int estimateBytes(int contextTokens) =>
      fileBytes + kvCacheBytes(contextTokens) + overheadBytes(contextTokens);

  /// Largest context (multiple of 512, at least 512) whose estimate fits in
  /// [availableBytes], or null if even 512 tokens doesn't fit.
  int? maxContextFitting(int availableBytes) {
    if (estimateBytes(512) > availableBytes) return null;
    var lo = 512;
    var hi = trainedContext > 512 ? trainedContext : 512;
    while (lo < hi) {
      final mid = ((lo + hi + 512) ~/ 1024) * 512;
      if (mid <= lo) break;
      if (estimateBytes(mid) <= availableBytes) {
        lo = mid;
      } else {
        hi = mid - 512;
      }
    }
    return lo;
  }

  static const _kb = 1024;
  static const _mb = 1024 * 1024;
}

/// Reads just the metadata block at the start of a GGUF file (never the
/// tensor data). Returns null if the file isn't a GGUF the reader
/// understands or is missing the architecture fields.
Future<GgufInfo?> readGgufInfo(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final raf = await file.open();
  try {
    final reader = _GgufReader(raf, await raf.length());
    return await reader.read();
  } catch (_) {
    return null;
  } finally {
    await raf.close();
  }
}

class _GgufReader {
  _GgufReader(this._raf, this._fileLength);

  final RandomAccessFile _raf;
  final int _fileLength;
  Uint8List _buf = Uint8List(0);
  int _bufStart = 0; // file offset of _buf[0]
  int _pos = 0; // absolute file offset

  static const _chunk = 1 << 20;
  // Metadata lives at the start; refuse to wander through a corrupt file.
  static const _maxMetadataBytes = 64 << 20;

  Future<void> _ensure(int n) async {
    if (_pos + n <= _bufStart + _buf.length) return;
    if (_pos + n > _fileLength || _pos + n > _maxMetadataBytes) {
      throw const FormatException('GGUF metadata truncated');
    }
    await _raf.setPosition(_pos);
    final size = n > _chunk ? n : _chunk;
    _buf = await _raf.read(size);
    _bufStart = _pos;
    if (_buf.length < n) throw const FormatException('Short read');
  }

  Future<ByteData> _bytes(int n) async {
    await _ensure(n);
    final view = ByteData.sublistView(_buf, _pos - _bufStart, _pos - _bufStart + n);
    _pos += n;
    return view;
  }

  Future<int> _u32() async => (await _bytes(4)).getUint32(0, Endian.little);
  Future<int> _u64() async => (await _bytes(8)).getUint64(0, Endian.little);

  Future<void> _skip(int n) async {
    if (n < 0 || _pos + n > _fileLength) {
      throw const FormatException('Bad skip');
    }
    _pos += n;
  }

  /// Skips [count] length-prefixed strings (e.g. a 150k-token vocab). Walks
  /// the buffer synchronously and only awaits when it needs a refill;
  /// awaiting per item made this take seconds.
  Future<void> _skipStrings(int count) async {
    var remaining = count;
    while (remaining > 0) {
      await _ensure(8);
      final end = _bufStart + _buf.length;
      final view = ByteData.sublistView(_buf);
      while (remaining > 0 && _pos + 8 <= end) {
        final len = view.getUint64(_pos - _bufStart, Endian.little);
        if (len > 1 << 20) throw const FormatException('String too long');
        if (_pos + 8 + len > end) break; // needs a refill
        _pos += 8 + len;
        remaining--;
      }
      if (remaining > 0 && _pos + 8 <= end) {
        // A string straddles the buffer end: step over it, then refill.
        final len = await _u64();
        await _skip(len);
        remaining--;
      }
    }
  }

  Future<String> _string() async {
    final len = await _u64();
    if (len > 1 << 20) throw const FormatException('String too long');
    await _ensure(len);
    final s = utf8.decode(
        _buf.sublist(_pos - _bufStart, _pos - _bufStart + len),
        allowMalformed: true);
    _pos += len;
    return s;
  }

  // Fixed sizes of scalar value types (GGUF spec); 8 = string, 9 = array.
  static const _scalarSize = {
    0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8,
  };

  Future<Object?> _value(int type, {bool keep = true}) async {
    switch (type) {
      case 8:
        if (!keep) {
          await _skip(await _u64());
          return null;
        }
        return _string();
      case 9:
        final itemType = await _u32();
        final count = await _u64();
        final size = _scalarSize[itemType];
        if (keep && itemType == 7 && count <= 4096) {
          final d = await _bytes(count);
          return [for (var i = 0; i < count; i++) d.getUint8(i) != 0];
        }
        if (size != null) {
          await _skip(size * count);
        } else if (itemType == 8) {
          await _skipStrings(count);
        } else {
          for (var i = 0; i < count; i++) {
            await _value(itemType, keep: false);
          }
        }
        return null;
      default:
        final size = _scalarSize[type];
        if (size == null) throw FormatException('Unknown GGUF type $type');
        final d = await _bytes(size);
        switch (type) {
          case 0:
            return d.getUint8(0);
          case 1:
            return d.getInt8(0);
          case 2:
            return d.getUint16(0, Endian.little);
          case 3:
            return d.getInt16(0, Endian.little);
          case 4:
            return d.getUint32(0, Endian.little);
          case 5:
            return d.getInt32(0, Endian.little);
          case 6:
            return d.getFloat32(0, Endian.little);
          case 7:
            return d.getUint8(0) != 0;
          case 10:
            return d.getUint64(0, Endian.little);
          case 11:
            return d.getInt64(0, Endian.little);
          default:
            return d.getFloat64(0, Endian.little);
        }
    }
  }

  Future<GgufInfo?> read() async {
    final magic = await _bytes(4);
    if (utf8.decode(magic.buffer.asUint8List(magic.offsetInBytes, 4)) !=
        'GGUF') {
      return null;
    }
    final version = await _u32();
    if (version < 2) return null; // v1 used 32-bit counts
    await _u64(); // tensor count
    final kvCount = await _u64();

    final values = <String, Object?>{};
    for (var i = 0; i < kvCount; i++) {
      final key = await _string();
      final type = await _u32();
      values[key] = await _value(type);
    }

    final arch = values['general.architecture'];
    if (arch is! String) return null;
    int? intOf(String key) {
      final v = values['$arch.$key'];
      return v is int ? v : null;
    }

    final layers = intOf('block_count');
    final embedding = intOf('embedding_length');
    final heads = intOf('attention.head_count');
    if (layers == null || embedding == null || heads == null || heads == 0) {
      return null;
    }
    return GgufInfo(
      architecture: arch,
      name: values['general.name'] as String?,
      layers: layers,
      trainedContext: intOf('context_length') ?? 4096,
      embeddingLength: embedding,
      headCount: heads,
      headCountKv: intOf('attention.head_count_kv') ?? heads,
      keyLength: intOf('attention.key_length'),
      valueLength: intOf('attention.value_length'),
      fileBytes: _fileLength,
      slidingWindow: intOf('attention.sliding_window'),
      swaPattern: values['$arch.attention.sliding_window_pattern'] is List
          ? (values['$arch.attention.sliding_window_pattern'] as List).cast<bool>()
          : null,
      keyLengthSwa: intOf('attention.key_length_swa'),
      valueLengthSwa: intOf('attention.value_length_swa'),
      sharedKvLayers: intOf('attention.shared_kv_layers') ?? 0,
    );
  }
}
