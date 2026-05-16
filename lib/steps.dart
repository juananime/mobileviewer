import 'dart:io';
import 'package:yaml/yaml.dart';

Future<void> runStepsFile(String filePath, String deviceId) async {
  final file = File(filePath);
  if (!await file.exists()) {
    print('Error: file not found — $filePath');
    exit(1);
  }

  final doc = loadYaml(await file.readAsString());
  final name = doc['name'] as String? ?? filePath;
  final rawSteps = doc['steps'] as YamlList?;

  if (rawSteps == null || rawSteps.isEmpty) {
    print('No steps found in $filePath');
    return;
  }

  print('Test: $name');
  print('Steps: ${rawSteps.length}\n');

  for (var i = 0; i < rawSteps.length; i++) {
    final entry = rawSteps[i] as YamlMap;
    final type = entry.keys.first as String;
    final params = entry[type];

    stdout.write('  [${i + 1}/${rawSteps.length}] $type');
    if (params is YamlMap) {
      final summary = params.entries
          .map((e) => '${e.key}=${e.value}')
          .join(', ');
      stdout.write(' ($summary)');
    }
    stdout.write(' ... ');

    try {
      await _execute(type, params, deviceId);
      print('✓');
    } catch (e) {
      print('✗\n\nFailed: $e');
      exit(1);
    }
  }

  print('\nAll steps passed.');
}

Future<void> _execute(String type, dynamic params, String deviceId) async {
  switch (type) {
    case 'launch_app':
      final package = _require(params, 'package', type);
      await _adb(deviceId, ['shell', 'monkey', '-p', package, '-c',
          'android.intent.category.LAUNCHER', '1']);

    case 'tap':
      final x = _require(params, 'x', type);
      final y = _require(params, 'y', type);
      await _adb(deviceId, ['shell', 'input', 'tap', '$x', '$y']);

    case 'swipe':
      final x1 = _require(params, 'x1', type);
      final y1 = _require(params, 'y1', type);
      final x2 = _require(params, 'x2', type);
      final y2 = _require(params, 'y2', type);
      final duration = params['duration'] ?? 300;
      await _adb(deviceId,
          ['shell', 'input', 'swipe', '$x1', '$y1', '$x2', '$y2', '$duration']);

    case 'input_text':
      final text = _require(params, 'text', type);
      // Escape spaces for adb shell input text
      final escaped = '$text'.replaceAll(' ', '%s');
      await _adb(deviceId, ['shell', 'input', 'text', escaped]);

    case 'press_key':
      final key = _require(params, 'key', type);
      final keycode = _keycode(key);
      await _adb(deviceId, ['shell', 'input', 'keyevent', keycode]);

    case 'wait':
      final seconds = _require(params, 'seconds', type);
      await Future.delayed(Duration(milliseconds: (double.parse('$seconds') * 1000).round()));

    case 'screenshot':
      final saveAs = params?['save_as'] as String? ?? 'screenshot.png';
      final result = await Process.run(
        'adb', ['-s', deviceId, 'exec-out', 'screencap', '-p'],
        stdoutEncoding: null,
      );
      await File(saveAs).writeAsBytes(result.stdout as List<int>);

    case 'adb':
      final command = _require(params, 'command', type);
      final args = '$command'.split(' ');
      await _adb(deviceId, args);

    default:
      throw 'Unknown step type: "$type"';
  }
}

Future<void> _adb(String deviceId, List<String> args) async {
  final result = await Process.run('adb', ['-s', deviceId, ...args]);
  if (result.exitCode != 0) {
    final err = (result.stderr as String).trim();
    throw err.isNotEmpty ? err : 'adb exited with code ${result.exitCode}';
  }
}

dynamic _require(dynamic params, String key, String step) {
  if (params == null || params[key] == null) {
    throw 'Step "$step" is missing required field: $key';
  }
  return params[key];
}

String _keycode(String key) {
  const keycodes = {
    'back': 'KEYCODE_BACK',
    'home': 'KEYCODE_HOME',
    'enter': 'KEYCODE_ENTER',
    'tab': 'KEYCODE_TAB',
    'delete': 'KEYCODE_DEL',
    'menu': 'KEYCODE_MENU',
    'search': 'KEYCODE_SEARCH',
    'up': 'KEYCODE_DPAD_UP',
    'down': 'KEYCODE_DPAD_DOWN',
    'left': 'KEYCODE_DPAD_LEFT',
    'right': 'KEYCODE_DPAD_RIGHT',
    'power': 'KEYCODE_POWER',
    'volume_up': 'KEYCODE_VOLUME_UP',
    'volume_down': 'KEYCODE_VOLUME_DOWN',
  };
  return keycodes[key.toLowerCase()] ?? key;
}