import 'dart:io';
import 'package:yaml/yaml.dart';

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> runStepsFile(String filePath, String deviceId) async {
  final file = File(filePath);
  if (!await file.exists()) {
    print('Error: file not found — $filePath');
    exit(1);
  }

  // Maestro format: two YAML documents separated by ---
  // Doc 1: { appId: com.example.app, ... }
  // Doc 2: [ - launchApp, - tapOn: "text", ... ]
  final docs = loadYamlStream(await file.readAsString()).toList();
  if (docs.isEmpty) {
    print('Empty file: $filePath');
    return;
  }

  final header = docs.first as YamlMap?;
  final appId = header?['appId'] as String?;
  final steps = docs.length > 1 ? docs[1] as YamlList? : null;

  if (steps == null || steps.isEmpty) {
    print('No steps found in $filePath');
    return;
  }

  final runner = _StepRunner(deviceId: deviceId, appId: appId);

  print('Flow:  $filePath');
  if (appId != null) print('App:   $appId');
  print('Steps: ${steps.length}\n');

  await runner.runSteps(steps);
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

class _StepRunner {
  final String deviceId;
  final String? appId;

  _StepRunner({required this.deviceId, this.appId});

  Future<void> runSteps(YamlList steps) async {
    for (var i = 0; i < steps.length; i++) {
      final raw = steps[i];
      String type;
      dynamic params;

      if (raw is String) {
        // e.g. "- launchApp" or "- back"
        type = raw;
        params = null;
      } else if (raw is YamlMap) {
        type = raw.keys.first as String;
        params = raw[type];
      } else {
        print('  [${i + 1}/${steps.length}] unrecognised step — skipped');
        continue;
      }

      final label = _stepLabel(type, params);
      stdout.write('  [${i + 1}/${steps.length}] $label ... ');

      try {
        await _execute(type, params);
        print('✓');
      } catch (e) {
        print('✗\n\nFailed: $e');
        exit(1);
      }
    }

    print('\nAll steps passed.');
  }

  Future<void> _execute(String type, dynamic params) async {
    switch (type) {
      // --- App lifecycle ---
      case 'launchApp':
        final pkg = params is String
            ? params
            : (params is YamlMap ? params['appId'] as String? : null) ?? appId;
        if (pkg == null) throw 'launchApp requires an appId';
        await _adb(['shell', 'monkey', '-p', pkg, '-c',
            'android.intent.category.LAUNCHER', '1']);

      case 'stopApp':
        final pkg = params is String ? params : appId;
        if (pkg == null) throw 'stopApp requires an appId';
        await _adb(['shell', 'am', 'force-stop', pkg]);

      case 'clearState':
        final pkg = params is String ? params : appId;
        if (pkg == null) throw 'clearState requires an appId';
        await _adb(['shell', 'pm', 'clear', pkg]);

      // --- Navigation ---
      case 'back':
        await _adb(['shell', 'input', 'keyevent', 'KEYCODE_BACK']);

      case 'scroll':
        final dir = params is YamlMap
            ? (params['direction'] as String? ?? 'DOWN').toUpperCase()
            : 'DOWN';
        await _swipeDirection(dir, slow: true);

      case 'scrollUntilVisible':
        final text = params is String
            ? params
            : (params is YamlMap ? params['text'] as String? : null);
        if (text == null) throw 'scrollUntilVisible requires a text value';
        await _scrollUntilVisible(text);

      // --- Interaction ---
      case 'tapOn':
        await _tapOn(params);

      case 'longPressOn':
        await _tapOn(params, longPress: true);

      case 'doubleTapOn':
        final (x, y) = await _resolveTarget(params);
        await _adb(['shell', 'input', 'tap', '$x', '$y']);
        await Future.delayed(const Duration(milliseconds: 80));
        await _adb(['shell', 'input', 'tap', '$x', '$y']);

      case 'swipe':
        if (params is YamlMap && params.containsKey('direction')) {
          await _swipeDirection(
              (params['direction'] as String).toUpperCase());
        } else if (params is YamlMap &&
            params.containsKey('start') &&
            params.containsKey('end')) {
          final (x1, y1) = await _resolvePoint(params['start'] as String);
          final (x2, y2) = await _resolvePoint(params['end'] as String);
          final duration = params['duration'] ?? 400;
          await _adb(['shell', 'input', 'swipe',
              '$x1', '$y1', '$x2', '$y2', '$duration']);
        } else {
          throw 'swipe requires direction or start/end';
        }

      case 'inputText':
        final text = params is String ? params : params['text'] as String;
        final escaped = text.replaceAll(' ', '%s');
        await _adb(['shell', 'input', 'text', escaped]);

      case 'clearText':
        // Select all then delete
        await _adb(['shell', 'input', 'keyevent',
            '--longpress', 'KEYCODE_A']);
        await _adb(['shell', 'input', 'keyevent', 'KEYCODE_DEL']);

      case 'hideKeyboard':
        await _adb(['shell', 'input', 'keyevent', 'KEYCODE_BACK']);

      case 'pressKey':
        final key = params is String ? params : params['key'] as String;
        await _adb(['shell', 'input', 'keyevent', _keycode(key)]);

      case 'openLink':
        final url = params is String ? params : params['url'] as String;
        await _adb(['shell', 'am', 'start', '-a',
            'android.intent.action.VIEW', '-d', url]);

      // --- Assertions ---
      case 'assertVisible':
        final text = params is String ? params : params['text'] as String;
        final found = await _findElementByText(text);
        if (found == null) throw 'Element not visible: "$text"';

      case 'assertNotVisible':
        final text = params is String ? params : params['text'] as String;
        final found = await _findElementByText(text);
        if (found != null) throw 'Element should not be visible: "$text"';

      // --- Utilities ---
      case 'takeScreenshot':
        final name = params is String
            ? params
            : (params is YamlMap ? params['path'] as String? : null) ??
                'screenshot';
        final path = name.endsWith('.png') ? name : '$name.png';
        final result = await Process.run(
          'adb', ['-s', deviceId, 'exec-out', 'screencap', '-p'],
          stdoutEncoding: null,
        );
        await File(path).writeAsBytes(result.stdout as List<int>);

      case 'wait':
        final ms = params is YamlMap
            ? (params['maxDuration'] as int? ?? 1000)
            : 1000;
        await Future.delayed(Duration(milliseconds: ms));

      case 'waitForAnimationToEnd':
        await Future.delayed(const Duration(milliseconds: 800));

      case 'repeat':
        if (params is! YamlMap) throw 'repeat requires times and commands';
        final times = params['times'] as int? ?? 1;
        final commands = params['commands'] as YamlList?;
        if (commands == null) throw 'repeat requires a commands list';
        for (var i = 0; i < times; i++) {
          await runSteps(commands);
        }

      case 'runFlow':
        final path = params is String ? params : params['file'] as String;
        await runStepsFile(path, deviceId);

      default:
        throw 'Unknown step: "$type"';
    }
  }

  // ---------------------------------------------------------------------------
  // Element finding via uiautomator
  // ---------------------------------------------------------------------------

  Future<String?> _dumpUi() async {
    await _adb(['shell', 'uiautomator', 'dump', '/sdcard/_ui_dump.xml']);
    final result = await Process.run(
      'adb', ['-s', deviceId, 'shell', 'cat', '/sdcard/_ui_dump.xml'],
    );
    return result.stdout as String;
  }

  Future<(int, int)?> _findElementByText(String text) async {
    final xml = await _dumpUi();
    if (xml == null) return null;

    // Match text="..." or content-desc="..."
    final pattern = RegExp(
      r'<node[^>]*(?:text|content-desc)="' +
          RegExp.escape(text) +
          r'"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
    );
    // Also try reversed attribute order
    final pattern2 = RegExp(
      r'<node[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"[^>]*(?:text|content-desc)="' +
          RegExp.escape(text) +
          r'"',
    );

    Match? match = pattern.firstMatch(xml) ?? pattern2.firstMatch(xml);

    // Fallback: find bounds near text anywhere in the node string
    if (match == null) {
      final nodePattern = RegExp(r'<node [^/]*/?>');
      for (final nodeMatch in nodePattern.allMatches(xml)) {
        final node = nodeMatch.group(0)!;
        if (node.contains('text="$text"') ||
            node.contains('content-desc="$text"')) {
          final boundsMatch =
              RegExp(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
                  .firstMatch(node);
          if (boundsMatch != null) {
            match = boundsMatch;
            break;
          }
        }
      }
    }

    if (match == null) return null;
    final x1 = int.parse(match.group(1)!);
    final y1 = int.parse(match.group(2)!);
    final x2 = int.parse(match.group(3)!);
    final y2 = int.parse(match.group(4)!);
    return ((x1 + x2) ~/ 2, (y1 + y2) ~/ 2);
  }

  Future<(int, int)?> _findElementById(String resourceId) async {
    final xml = await _dumpUi();
    if (xml == null) return null;

    final nodePattern = RegExp(r'<node [^/]*/?>');
    for (final nodeMatch in nodePattern.allMatches(xml)) {
      final node = nodeMatch.group(0)!;
      if (node.contains('resource-id="$resourceId"')) {
        final boundsMatch =
            RegExp(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
                .firstMatch(node);
        if (boundsMatch != null) {
          final x1 = int.parse(boundsMatch.group(1)!);
          final y1 = int.parse(boundsMatch.group(2)!);
          final x2 = int.parse(boundsMatch.group(3)!);
          final y2 = int.parse(boundsMatch.group(4)!);
          return ((x1 + x2) ~/ 2, (y1 + y2) ~/ 2);
        }
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Tap helpers
  // ---------------------------------------------------------------------------

  Future<void> _tapOn(dynamic params, {bool longPress = false}) async {
    final (x, y) = await _resolveTarget(params);
    if (longPress) {
      await _adb(['shell', 'input', 'swipe',
          '$x', '$y', '$x', '$y', '800']);
    } else {
      await _adb(['shell', 'input', 'tap', '$x', '$y']);
    }
  }

  Future<(int, int)> _resolveTarget(dynamic params) async {
    if (params is String) {
      final pos = await _findElementByText(params);
      if (pos == null) throw 'Element not found: "$params"';
      return pos;
    }

    if (params is YamlMap) {
      if (params.containsKey('id')) {
        final pos = await _findElementById(params['id'] as String);
        if (pos == null) throw 'Element not found by id: "${params['id']}"';
        return pos;
      }
      if (params.containsKey('text')) {
        final pos = await _findElementByText(params['text'] as String);
        if (pos == null) throw 'Element not found: "${params['text']}"';
        return pos;
      }
      if (params.containsKey('point')) {
        return _resolvePoint(params['point'] as String);
      }
    }

    throw 'tapOn requires text, id, or point';
  }

  // ---------------------------------------------------------------------------
  // Screen size & coordinate helpers
  // ---------------------------------------------------------------------------

  (int, int)? _screenSize;

  Future<(int, int)> _getScreenSize() async {
    if (_screenSize != null) return _screenSize!;
    final result = await Process.run(
        'adb', ['-s', deviceId, 'shell', 'wm', 'size']);
    final output = (result.stdout as String).trim();
    final match = RegExp(r'(\d+)x(\d+)').firstMatch(output);
    if (match == null) throw 'Could not determine screen size';
    _screenSize = (int.parse(match.group(1)!), int.parse(match.group(2)!));
    return _screenSize!;
  }

  Future<(int, int)> _resolvePoint(String point) async {
    // "50%, 80%" or "540, 800"
    final parts = point.split(',').map((s) => s.trim()).toList();
    if (parts.length != 2) throw 'Invalid point: $point';

    if (parts[0].endsWith('%') || parts[1].endsWith('%')) {
      final (w, h) = await _getScreenSize();
      final px = double.parse(parts[0].replaceAll('%', '')) / 100;
      final py = double.parse(parts[1].replaceAll('%', '')) / 100;
      return ((w * px).round(), (h * py).round());
    }

    return (int.parse(parts[0]), int.parse(parts[1]));
  }

  Future<void> _swipeDirection(String direction, {bool slow = false}) async {
    final (w, h) = await _getScreenSize();
    final cx = w ~/ 2;
    final duration = slow ? 600 : 300;

    final coords = switch (direction) {
      'UP'    => (cx, (h * 0.8).round(), cx, (h * 0.2).round()),
      'DOWN'  => (cx, (h * 0.2).round(), cx, (h * 0.8).round()),
      'LEFT'  => ((w * 0.8).round(), h ~/ 2, (w * 0.2).round(), h ~/ 2),
      'RIGHT' => ((w * 0.2).round(), h ~/ 2, (w * 0.8).round(), h ~/ 2),
      _       => throw 'Unknown swipe direction: $direction',
    };

    await _adb(['shell', 'input', 'swipe',
        '${coords.$1}', '${coords.$2}',
        '${coords.$3}', '${coords.$4}',
        '$duration']);
  }

  Future<void> _scrollUntilVisible(String text,
      {int maxScrolls = 10}) async {
    for (var i = 0; i < maxScrolls; i++) {
      final pos = await _findElementByText(text);
      if (pos != null) return;
      await _swipeDirection('UP', slow: true);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    throw 'Element never became visible after $maxScrolls scrolls: "$text"';
  }

  // ---------------------------------------------------------------------------
  // ADB helper
  // ---------------------------------------------------------------------------

  Future<void> _adb(List<String> args) async {
    final result =
        await Process.run('adb', ['-s', deviceId, ...args]);
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw err.isNotEmpty ? err : 'adb exited with code ${result.exitCode}';
    }
  }
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

String _keycode(String key) {
  const keycodes = {
    'enter':        'KEYCODE_ENTER',
    'back':         'KEYCODE_BACK',
    'home':         'KEYCODE_HOME',
    'tab':          'KEYCODE_TAB',
    'delete':       'KEYCODE_DEL',
    'backspace':    'KEYCODE_DEL',
    'menu':         'KEYCODE_MENU',
    'search':       'KEYCODE_SEARCH',
    'up':           'KEYCODE_DPAD_UP',
    'down':         'KEYCODE_DPAD_DOWN',
    'left':         'KEYCODE_DPAD_LEFT',
    'right':        'KEYCODE_DPAD_RIGHT',
    'power':        'KEYCODE_POWER',
    'volume_up':    'KEYCODE_VOLUME_UP',
    'volume_down':  'KEYCODE_VOLUME_DOWN',
    'space':        'KEYCODE_SPACE',
    'escape':       'KEYCODE_ESCAPE',
  };
  return keycodes[key.toLowerCase()] ?? key;
}

String _stepLabel(String type, dynamic params) {
  if (params == null) return type;
  if (params is String) return '$type: "$params"';
  if (params is YamlMap) {
    final summary =
        params.entries.map((e) => '${e.key}: ${e.value}').join(', ');
    return '$type ($summary)';
  }
  return type;
}
