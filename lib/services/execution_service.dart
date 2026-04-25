import 'package:get/get.dart';

/// Parses LLM output for CMD: tags and executes commands.
class ExecutionService extends GetxService {

  /// Parse raw LLM output. Returns a result map:
  /// { 'type': 'cmd'|'msg', 'display': String, 'cmdResult': String? }
  Future<Map<String, String>> processOutput(String rawOutput) async {
    final trimmed = rawOutput.trim();

    // Extract ONLY the first line for CMD: detection.
    // The model must output CMD: as the very first thing on the first line.
    final firstLine = trimmed.split('\n').first.trim();

    // Strict match: first line must be EXACTLY "CMD: <command>" with nothing else
    final cmdMatch = RegExp(r'^CMD:\s*(.+)$').firstMatch(firstLine);

    if (cmdMatch != null && _isValidCommand(cmdMatch.group(1)!.trim())) {
      final command = cmdMatch.group(1)!.trim();

      // Only take the command part (first line), ignore any rambling after
      if (command.isEmpty) {
        return {
          'type': 'msg',
          'display': 'Received empty command.',
        };
      }

      // Execute the command
      final result = await _runCommand(command);

      return {
        'type': 'cmd',
        'command': command,
        'display': '⚡ Executed: `$command`',
        'cmdResult': result,
      };
    }

    // Otherwise treat as MSG:
    String display = trimmed;
    if (display.startsWith('MSG:')) {
      display = display.substring(4).trim();
    }

    return {
      'type': 'msg',
      'display': display,
    };
  }

  /// Validate that a command looks like a real ADB shell command,
  /// not hallucinated garbage from the model.
  bool _isValidCommand(String cmd) {
    if (cmd.isEmpty) return false;
    // Must not contain markdown, code blocks, or multiple lines
    if (cmd.contains('```') || cmd.contains('"""')) return false;
    // Must start with a known command prefix or look like a shell command
    final validPrefixes = [
      'am ', 'pm ', 'svc ', 'cmd ', 'input ', 'settings ',
      'monkey ', 'screencap ', 'dumpsys ', 'getprop ', 'setprop ',
      'wm ', 'content ', 'bmgr ', 'appops ', 'service ',
      'kill ', 'ps ', 'ls ', 'cat ', 'echo ', 'rm ', 'cp ', 'mv ',
      'chmod ', 'chown ', 'mkdir ', 'touch ', 'grep ', 'find ',
      'reboot', 'logcat', 'top', 'df ', 'mount ',
    ];
    final lower = cmd.toLowerCase();
    return validPrefixes.any((p) => lower.startsWith(p));
  }

  /// Directly execute a command string (for task steps).
  Future<String> executeCommand(String command) async {
    return await _runCommand(command);
  }

  /// Run a command. Override this to integrate with a command executor.
  Future<String> _runCommand(String command) async {
    // Command execution is currently disabled.
    // To enable, integrate with a shell/process executor.
    return 'Command execution is not available. Command: $command';
  }
}
