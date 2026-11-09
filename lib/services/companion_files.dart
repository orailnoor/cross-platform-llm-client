import 'dart:io';

/// Finds the helper files that ride along with a GGUF model in the same
/// folder: its vision projector ("mmproj") and its MTP draft head ("mtp").
///
/// Matching is by name: both names are split into tokens, quantisation and
/// noise tokens are dropped, and the helper whose tokens best overlap the
/// model's wins. Size tokens ("12b", "e4b", "26b", "a4b") must agree when
/// both names have them, so a 26B projector is never paired with a 12B model.
class CompanionFiles {
  /// Override value that turns a helper off for a model.
  static const none = 'none';

  static bool isMmprojName(String filename) {
    final lower = _base(filename);
    return filename.toLowerCase().endsWith('.gguf') && lower.contains('mmproj');
  }

  /// MTP draft head: a "mtp" token in the name ("mtp-gemma-4-26B-A4B-it").
  static bool isMtpName(String filename) {
    if (!filename.toLowerCase().endsWith('.gguf') || isMmprojName(filename)) {
      return false;
    }
    return _rawTokens(_base(filename)).contains('mtp');
  }

  /// Other non-model GGUF helpers (importance matrices).
  static bool isOtherHelperName(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.gguf') && lower.contains('imatrix');
  }

  /// Any GGUF that must not be listed or loaded as a model.
  static bool isHelperName(String filename) =>
      isMmprojName(filename) || isMtpName(filename) || isOtherHelperName(filename);

  /// Vision projector for [modelPath] in the same folder, or null.
  static Future<String?> findMmproj(String modelPath) =>
      _find(modelPath, isMmprojName);

  /// MTP draft head for [modelPath] in the same folder, or null.
  static Future<String?> findMtp(String modelPath) =>
      _find(modelPath, isMtpName);

  /// Applies a per-model override: [none] disables, an existing path wins,
  /// anything else (empty, missing file) falls back to [fallback].
  static Future<String?> applyOverride(
      String? override, Future<String?> Function() fallback) async {
    final value = override?.trim() ?? '';
    if (value == none) return null;
    if (value.isNotEmpty && await File(value).exists()) return value;
    return fallback();
  }

  static Future<List<String>> listHelpers(String dirPath,
      {required bool mtp}) async {
    final out = <String>[];
    try {
      await for (final e in Directory(dirPath).list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (mtp ? isMtpName(name) : isMmprojName(name)) out.add(e.path);
      }
    } catch (_) {}
    out.sort();
    return out;
  }

  static Future<String?> _find(
      String modelPath, bool Function(String) isCandidate) async {
    final file = File(modelPath);
    final dir = file.parent;
    final modelName = file.uri.pathSegments.last;
    if (!modelName.toLowerCase().endsWith('.gguf')) return null;
    final candidates = <String>[];
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (name == modelName || name.endsWith('.part')) continue;
        if (isCandidate(name)) candidates.add(name);
      }
    } catch (_) {
      return null;
    }
    if (candidates.isEmpty) return null;
    final best = bestMatch(modelName, candidates);
    return best == null ? null : '${dir.path}/$best';
  }

  /// The candidate that belongs to [modelName], or null. Exposed for tests.
  static String? bestMatch(String modelName, List<String> candidates) {
    final model = _tokens(modelName);
    final modelSizes = model.where(_isSizeToken).toSet();
    String? best;
    var bestScore = 0.0;
    var bestShared = 0;
    final compatible = <String>[];
    for (final name in candidates..sort()) {
      final cand = _tokens(name);
      final candSizes = cand.where(_isSizeToken).toSet();
      if (modelSizes.isNotEmpty &&
          candSizes.isNotEmpty &&
          (modelSizes.length != candSizes.length ||
              !modelSizes.containsAll(candSizes))) {
        continue; // different model size
      }
      compatible.add(name);
      if (cand.isEmpty) continue;
      final shared = cand.intersection(model).length;
      final score = shared / cand.length;
      if (score > bestScore || (score == bestScore && shared > bestShared)) {
        best = name;
        bestScore = score;
        bestShared = shared;
      }
    }
    if (best != null && bestScore >= 0.5 && bestShared >= 2) return best;
    // The only helper of its kind in the folder (and not another size).
    if (candidates.length == 1 && compatible.length == 1) return compatible.first;
    return null;
  }

  static String _base(String filename) {
    var lower = filename.toLowerCase();
    if (lower.endsWith('.gguf')) lower = lower.substring(0, lower.length - 5);
    return lower;
  }

  static List<String> _rawTokens(String base) => base
      // "gemma4" -> "gemma 4", "qwen3" -> "qwen 3" (but not "e4b"/"a4b").
      .replaceAllMapped(RegExp(r'([a-z]{3,})(\d)'), (m) => '${m[1]} ${m[2]}')
      .split(RegExp(r'[-_.\s]+'))
      .where((t) => t.isNotEmpty)
      .toList();

  static final _noise = RegExp(
      r'^(mmproj|mtp|assistant|draft|model|gguf|unsloth|it|instruct|chat|'
      r'q\d+|iq\d+|k|m|s|l|xs|xxs|xl|ud|i1|bf16|f16|f32|fp16|fp8|bf|mxfp4|'
      r'imatrix|heretic|v\d+)$');

  static Set<String> _tokens(String filename) =>
      _rawTokens(_base(filename)).where((t) => !_noise.hasMatch(t)).toSet();

  static bool _isSizeToken(String t) =>
      RegExp(r'^\d+(\.\d+)?[bm]$').hasMatch(t) ||
      RegExp(r'^[a-z]\d+(\.\d+)?b$').hasMatch(t);
}
