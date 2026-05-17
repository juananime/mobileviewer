import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:yaml/yaml.dart';

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> runStepsFile(String filePath, String deviceId,
    {bool ios = false, String? appIdFallback, bool verbose = false}) async {
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
  final appId = header?['appId'] as String? ?? appIdFallback;
  final steps = docs.length > 1 ? docs[1] as YamlList? : null;

  if (steps == null || steps.isEmpty) {
    print('No steps found in $filePath');
    return;
  }

  final _Driver driver = ios
      ? _IosXCTestDriver(udid: deviceId, bundleId: appId, verbose: verbose)
      : _AndroidDriver(deviceId: deviceId);

  final runner = _StepRunner(driver: driver, appId: appId, ios: ios);

  print('Flow:     $filePath');
  print('Platform: ${ios ? 'iOS' : 'Android'}');
  if (appId != null) print('App:      $appId');
  print('Steps:    ${steps.length}\n');

  try {
    await runner.runSteps(steps);
  } finally {
    await driver.dispose();
  }
}

// ---------------------------------------------------------------------------
// Abstract driver
// ---------------------------------------------------------------------------

abstract class _Driver {
  Future<void> launchApp(String bundleId);
  Future<void> stopApp(String bundleId);
  Future<void> clearState(String bundleId);

  Future<void> tap(int x, int y);
  Future<void> longPress(int x, int y);
  Future<void> doubleTap(int x, int y);
  Future<void> swipe(int x1, int y1, int x2, int y2, int durationMs);
  Future<void> inputText(String text);
  Future<void> clearText();
  Future<void> hideKeyboard();
  Future<void> pressKey(String key);
  Future<void> openLink(String url);
  Future<void> back();

  Future<(int, int)?> findElementByText(String text);
  Future<(int, int)?> findElementById(String id);

  Future<void> takeScreenshot(String path);
  Future<(int, int)> getScreenSize();

  Future<void> dispose() async {}
}

// ---------------------------------------------------------------------------
// Android driver (adb + uiautomator)
// ---------------------------------------------------------------------------

class _AndroidDriver implements _Driver {
  final String deviceId;

  _AndroidDriver({required this.deviceId});

  @override
  Future<void> launchApp(String bundleId) =>
      _adb(['shell', 'monkey', '-p', bundleId, '-c',
          'android.intent.category.LAUNCHER', '1']);

  @override
  Future<void> stopApp(String bundleId) =>
      _adb(['shell', 'am', 'force-stop', bundleId]);

  @override
  Future<void> clearState(String bundleId) =>
      _adb(['shell', 'pm', 'clear', bundleId]);

  @override
  Future<void> tap(int x, int y) =>
      _adb(['shell', 'input', 'tap', '$x', '$y']);

  @override
  Future<void> longPress(int x, int y) =>
      _adb(['shell', 'input', 'swipe', '$x', '$y', '$x', '$y', '800']);

  @override
  Future<void> doubleTap(int x, int y) async {
    await _adb(['shell', 'input', 'tap', '$x', '$y']);
    await Future.delayed(const Duration(milliseconds: 80));
    await _adb(['shell', 'input', 'tap', '$x', '$y']);
  }

  @override
  Future<void> swipe(int x1, int y1, int x2, int y2, int durationMs) =>
      _adb(['shell', 'input', 'swipe',
          '$x1', '$y1', '$x2', '$y2', '$durationMs']);

  @override
  Future<void> inputText(String text) =>
      _adb(['shell', 'input', 'text', text.replaceAll(' ', '%s')]);

  @override
  Future<void> clearText() async {
    await _adb(['shell', 'input', 'keyevent', '--longpress', 'KEYCODE_A']);
    await _adb(['shell', 'input', 'keyevent', 'KEYCODE_DEL']);
  }

  @override
  Future<void> hideKeyboard() =>
      _adb(['shell', 'input', 'keyevent', 'KEYCODE_BACK']);

  @override
  Future<void> pressKey(String key) =>
      _adb(['shell', 'input', 'keyevent', _androidKeycode(key)]);

  @override
  Future<void> openLink(String url) =>
      _adb(['shell', 'am', 'start', '-a', 'android.intent.action.VIEW',
          '-d', url]);

  @override
  Future<void> back() =>
      _adb(['shell', 'input', 'keyevent', 'KEYCODE_BACK']);

  @override
  Future<void> takeScreenshot(String path) async {
    final result = await Process.run(
      'adb', ['-s', deviceId, 'exec-out', 'screencap', '-p'],
      stdoutEncoding: null,
    );
    await File(path).writeAsBytes(result.stdout as List<int>);
  }

  @override
  Future<(int, int)?> findElementByText(String text) async {
    final xml = await _dumpUi();
    if (xml == null) return null;
    return _parseAndroidBounds(xml, text: text);
  }

  @override
  Future<(int, int)?> findElementById(String id) async {
    final xml = await _dumpUi();
    if (xml == null) return null;
    return _parseAndroidBounds(xml, resourceId: id);
  }

  (int, int)? _screenSize;

  @override
  Future<(int, int)> getScreenSize() async {
    if (_screenSize != null) return _screenSize!;
    final result = await Process.run(
        'adb', ['-s', deviceId, 'shell', 'wm', 'size']);
    final match = RegExp(r'(\d+)x(\d+)')
        .firstMatch((result.stdout as String).trim());
    if (match == null) throw 'Could not determine Android screen size';
    _screenSize = (int.parse(match.group(1)!), int.parse(match.group(2)!));
    return _screenSize!;
  }

  Future<String?> _dumpUi() async {
    await _adb(['shell', 'uiautomator', 'dump', '/sdcard/_ui_dump.xml']);
    final result = await Process.run(
        'adb', ['-s', deviceId, 'shell', 'cat', '/sdcard/_ui_dump.xml']);
    return result.stdout as String;
  }

  (int, int)? _parseAndroidBounds(String xml,
      {String? text, String? resourceId}) {
    final nodePattern = RegExp(r'<node [^/]*/?>');
    for (final nodeMatch in nodePattern.allMatches(xml)) {
      final node = nodeMatch.group(0)!;
      bool matches = false;
      if (text != null) {
        matches =
            node.contains('text="$text"') ||
            node.contains('content-desc="$text"');
      } else if (resourceId != null) {
        matches = node.contains('resource-id="$resourceId"');
      }
      if (!matches) continue;
      final boundsMatch =
          RegExp(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"').firstMatch(node);
      if (boundsMatch != null) {
        final x1 = int.parse(boundsMatch.group(1)!);
        final y1 = int.parse(boundsMatch.group(2)!);
        final x2 = int.parse(boundsMatch.group(3)!);
        final y2 = int.parse(boundsMatch.group(4)!);
        return ((x1 + x2) ~/ 2, (y1 + y2) ~/ 2);
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {}

  Future<void> _adb(List<String> args) async {
    final result = await Process.run('adb', ['-s', deviceId, ...args]);
    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw err.isNotEmpty ? err : 'adb exited with code ${result.exitCode}';
    }
  }
}

// ---------------------------------------------------------------------------
// iOS driver — XCTest runner over TCP + xcrun simctl for lifecycle
// ---------------------------------------------------------------------------

class _IosXCTestDriver implements _Driver {
  final String udid;
  final String? bundleId;
  final bool verbose;
  static const _port = 22087;

  Socket? _socket;
  _LineReader? _reader;
  Process? _runnerProcess;
  // Completes when xcodebuild exits so _connectWithRetry can bail early.
  final _runnerExited = Completer<int>();

  _IosXCTestDriver({required this.udid, this.bundleId, this.verbose = false});

  // ---- connection management ----

  Future<void> _ensureConnected() async {
    if (_socket != null) return;
    await _startRunner();
    final connected = await _connectWithRetry();
    _socket = connected.$1;
    _reader = connected.$2;
    // Send the bundle ID immediately so the runner initialises XCUIApplication
    // before the first command arrives.
    if (bundleId != null) {
      _socket!.write('${jsonEncode({'type': 'connect', 'bundleId': bundleId})}\n');
      await _reader!.readLine();
    }
  }

  Future<void> _startRunner() async {
    // Kill any leftover process still holding our port from a previous run.
    await Process.run('bash',
        ['-c', 'lsof -ti:$_port | xargs kill -9 2>/dev/null; true']);

    final buildDir = _buildDir();
    var xctestrun = _findXctestrun(buildDir);
    if (xctestrun == null) {
      await _buildRunner(buildDir);
      xctestrun = _findXctestrun(buildDir);
      if (xctestrun == null) {
        throw 'XCTest runner build failed — no .xctestrun found in $buildDir';
      }
    }
    _runnerProcess = await Process.start('xcodebuild', [
      'test-without-building',
      '-xctestrun', xctestrun,
      '-destination', 'id=$udid',
    ]);
    if (verbose) {
      _runnerProcess!.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write);
      _runnerProcess!.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderr.write);
    }
    _runnerProcess!.exitCode.then(_runnerExited.complete);
  }

  Future<void> _buildRunner(String buildDir) async {
    final cwd = Directory.current.path;
    final buildScript = '$cwd/xctest-runner/build.sh';
    if (!File(buildScript).existsSync()) {
      throw 'Could not find xctest-runner/build.sh.\n'
          'Make sure you run the CLI from the project root.';
    }
    print('XCTest runner not built — building now...');
    if (verbose) {
      final process = await Process.start(
        'bash', [buildScript],
        workingDirectory: cwd,
        mode: ProcessStartMode.inheritStdio,
      );
      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw 'XCTest runner build failed (exit $exitCode).';
      }
    } else {
      final result = await Process.run('bash', [buildScript], workingDirectory: cwd);
      if (result.exitCode != 0) {
        stderr.write(result.stdout as String);
        stderr.write(result.stderr as String);
        throw 'XCTest runner build failed (exit ${result.exitCode}).\n'
            'Re-run with --verbose for full output.';
      }
    }
    print('XCTest runner ready.\n');
  }

  Future<(Socket, _LineReader)> _connectWithRetry() async {
    for (var i = 0; i < 120; i++) {
      // If xcodebuild already exited, fail immediately with its exit code.
      if (_runnerExited.isCompleted) {
        final code = await _runnerExited.future;
        throw 'xcodebuild exited with code $code before the TCP server was ready.\n'
            'Check the xcodebuild output above for the specific error.';
      }
      try {
        final s = await Socket.connect(
            InternetAddress.loopbackIPv4, _port,
            timeout: const Duration(seconds: 1));
        final r = _LineReader(s);
        return (s, r);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    throw 'Could not connect to XCTest runner on port $_port after 60 s.\n'
        'Check that the simulator is booted and the runner built successfully.';
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> cmd) async {
    await _ensureConnected();
    _socket!.write('${jsonEncode(cmd)}\n');
    final line = await _reader!.readLine();
    final resp = jsonDecode(line) as Map<String, dynamic>;
    if (resp['ok'] != true) throw resp['error'] ?? 'runner error';
    return resp;
  }

  @override
  Future<void> dispose() async {
    try { await _send({'type': 'quit'}); } catch (_) {}
    _socket?.destroy();
    _runnerProcess?.kill();
  }

  // ---- _Driver implementation ----

  @override
  Future<void> launchApp(String bundleId) =>
      _send({'type': 'launchApp', 'bundleId': bundleId});

  @override
  Future<void> stopApp(String bundleId) =>
      _send({'type': 'stopApp', 'bundleId': bundleId});

  @override
  Future<void> clearState(String bundleId) async {
    try { await stopApp(bundleId); } catch (_) {}
    // Delete the simulator data container (simulator only)
    final r = await Process.run('xcrun',
        ['simctl', 'get_app_container', udid, bundleId, 'data']);
    final path = (r.stdout as String).trim();
    if (path.isNotEmpty) await Process.run('rm', ['-rf', path]);
  }

  @override
  Future<void> tap(int x, int y) =>
      _send({'type': 'tap', 'x': x.toDouble(), 'y': y.toDouble()});

  @override
  Future<void> longPress(int x, int y) =>
      _send({'type': 'longPress', 'x': x.toDouble(), 'y': y.toDouble()});

  @override
  Future<void> doubleTap(int x, int y) =>
      _send({'type': 'doubleTap', 'x': x.toDouble(), 'y': y.toDouble()});

  @override
  Future<void> swipe(int x1, int y1, int x2, int y2, int durationMs) =>
      _send({
        'type': 'swipe',
        'x1': x1.toDouble(), 'y1': y1.toDouble(),
        'x2': x2.toDouble(), 'y2': y2.toDouble(),
        'duration': durationMs / 1000.0,
      });

  @override
  Future<void> inputText(String text) =>
      _send({'type': 'inputText', 'text': text});

  @override
  Future<void> clearText() => _send({'type': 'clearText'});

  @override
  Future<void> hideKeyboard() => _send({'type': 'hideKeyboard'});

  @override
  Future<void> pressKey(String key) =>
      _send({'type': 'pressKey', 'key': key});

  @override
  Future<void> openLink(String url) =>
      _send({'type': 'openLink', 'url': url});

  @override
  Future<void> back() => _send({'type': 'back'});

  @override
  Future<void> takeScreenshot(String path) async {
    final resp = await _send({'type': 'screenshot'});
    final bytes = base64Decode(resp['data'] as String);
    await File(path).writeAsBytes(bytes);
  }

  @override
  Future<(int, int)?> findElementByText(String text) async {
    try {
      final r = await _send({'type': 'findByText', 'text': text});
      return ((r['x'] as num).round(), (r['y'] as num).round());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<(int, int)?> findElementById(String id) async {
    try {
      final r = await _send({'type': 'findById', 'id': id});
      return ((r['x'] as num).round(), (r['y'] as num).round());
    } catch (_) {
      return null;
    }
  }

  (int, int)? _screenSize;

  @override
  Future<(int, int)> getScreenSize() async {
    if (_screenSize != null) return _screenSize!;
    final r = await _send({'type': 'screenSize'});
    _screenSize = (
      (r['width'] as num).round(),
      (r['height'] as num).round(),
    );
    return _screenSize!;
  }

  // ---- helpers ----

  static String _buildDir() {
    // Resolve relative to where the CLI is invoked from
    final cwd = Directory.current.path;
    return '$cwd/.build/xctest';
  }

  static String? _findXctestrun(String buildDir) {
    final dir = Directory(buildDir);
    if (!dir.existsSync()) return null;
    final hits = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.xctestrun'))
        .toList();
    return hits.isEmpty ? null : hits.first.path;
  }
}

// ---------------------------------------------------------------------------
// TCP line reader (single-listener, request-response safe)
// ---------------------------------------------------------------------------

class _LineReader {
  final _buf = StringBuffer();
  final _pending = <Completer<String>>[];
  final _lines = <String>[];

  _LineReader(Socket socket) {
    socket.listen((data) {
      _buf.write(utf8.decode(data));
      _flush();
    });
  }

  void _flush() {
    final s = _buf.toString();
    var start = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == '\n') {
        _deliver(s.substring(start, i));
        start = i + 1;
      }
    }
    _buf.clear();
    _buf.write(s.substring(start));
  }

  void _deliver(String line) {
    if (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(line);
    } else {
      _lines.add(line);
    }
  }

  Future<String> readLine() {
    if (_lines.isNotEmpty) return Future.value(_lines.removeAt(0));
    final c = Completer<String>();
    _pending.add(c);
    return c.future;
  }
}

// ---------------------------------------------------------------------------
// Step runner
// ---------------------------------------------------------------------------

class _StepRunner {
  final _Driver driver;
  final String? appId;
  final bool ios;

  _StepRunner({required this.driver, this.appId, required this.ios});

  Future<void> runSteps(YamlList steps) async {
    for (var i = 0; i < steps.length; i++) {
      final raw = steps[i];
      String type;
      dynamic params;

      if (raw is String) {
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
        await driver.launchApp(pkg);

      case 'stopApp':
        final pkg = params is String ? params : appId;
        if (pkg == null) throw 'stopApp requires an appId';
        await driver.stopApp(pkg);

      case 'clearState':
        final pkg = params is String ? params : appId;
        if (pkg == null) throw 'clearState requires an appId';
        await driver.clearState(pkg);

      // --- Navigation ---
      case 'back':
        await driver.back();

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
        await driver.doubleTap(x, y);

      case 'swipe':
        if (params is YamlMap && params.containsKey('direction')) {
          await _swipeDirection(
              (params['direction'] as String).toUpperCase());
        } else if (params is YamlMap &&
            params.containsKey('start') &&
            params.containsKey('end')) {
          final (x1, y1) = await _resolvePoint(params['start'] as String);
          final (x2, y2) = await _resolvePoint(params['end'] as String);
          final duration = (params['duration'] as int?) ?? 400;
          await driver.swipe(x1, y1, x2, y2, duration);
        } else {
          throw 'swipe requires direction or start/end';
        }

      case 'inputText':
        final text = params is String ? params : params['text'] as String;
        await driver.inputText(text);

      case 'clearText':
        await driver.clearText();

      case 'hideKeyboard':
        await driver.hideKeyboard();

      case 'pressKey':
        final key = params is String ? params : params['key'] as String;
        await driver.pressKey(key);

      case 'openLink':
        final url = params is String ? params : params['url'] as String;
        await driver.openLink(url);

      // --- Assertions ---
      case 'assertVisible':
        final text = params is String ? params : params['text'] as String;
        final found = await driver.findElementByText(text);
        if (found == null) throw 'Element not visible: "$text"';

      case 'assertNotVisible':
        final text = params is String ? params : params['text'] as String;
        final found = await driver.findElementByText(text);
        if (found != null) throw 'Element should not be visible: "$text"';

      // --- Utilities ---
      case 'takeScreenshot':
        final name = params is String
            ? params
            : (params is YamlMap ? params['path'] as String? : null) ??
                'screenshot';
        final path = name.endsWith('.png') ? name : '$name.png';
        await driver.takeScreenshot(path);

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
        final deviceId = switch (driver) {
          _AndroidDriver d => d.deviceId,
          _IosXCTestDriver d => d.udid,
          _ => throw 'Unknown driver type',
        };
        await runStepsFile(path, deviceId, ios: ios);

      default:
        throw 'Unknown step: "$type"';
    }
  }

  // ---------------------------------------------------------------------------
  // Higher-level helpers (built on driver primitives)
  // ---------------------------------------------------------------------------

  Future<void> _tapOn(dynamic params, {bool longPress = false}) async {
    final (x, y) = await _resolveTarget(params);
    if (longPress) {
      await driver.longPress(x, y);
    } else {
      await driver.tap(x, y);
    }
  }

  Future<(int, int)> _resolveTarget(dynamic params) async {
    if (params is String) {
      final pos = await driver.findElementByText(params);
      if (pos == null) throw 'Element not found: "$params"';
      return pos;
    }

    if (params is YamlMap) {
      if (params.containsKey('id')) {
        final pos = await driver.findElementById(params['id'] as String);
        if (pos == null) throw 'Element not found by id: "${params['id']}"';
        return pos;
      }
      if (params.containsKey('text')) {
        final pos = await driver.findElementByText(params['text'] as String);
        if (pos == null) throw 'Element not found: "${params['text']}"';
        return pos;
      }
      if (params.containsKey('point')) {
        return _resolvePoint(params['point'] as String);
      }
    }

    throw 'tapOn requires text, id, or point';
  }

  Future<(int, int)> _resolvePoint(String point) async {
    final parts = point.split(',').map((s) => s.trim()).toList();
    if (parts.length != 2) throw 'Invalid point: $point';

    if (parts[0].endsWith('%') || parts[1].endsWith('%')) {
      final (w, h) = await driver.getScreenSize();
      final px = double.parse(parts[0].replaceAll('%', '')) / 100;
      final py = double.parse(parts[1].replaceAll('%', '')) / 100;
      return ((w * px).round(), (h * py).round());
    }

    return (int.parse(parts[0]), int.parse(parts[1]));
  }

  Future<void> _swipeDirection(String direction, {bool slow = false}) async {
    final (w, h) = await driver.getScreenSize();
    final cx = w ~/ 2;
    final duration = slow ? 600 : 300;

    final coords = switch (direction) {
      'UP'    => (cx, (h * 0.8).round(), cx, (h * 0.2).round()),
      'DOWN'  => (cx, (h * 0.2).round(), cx, (h * 0.8).round()),
      'LEFT'  => ((w * 0.8).round(), h ~/ 2, (w * 0.2).round(), h ~/ 2),
      'RIGHT' => ((w * 0.2).round(), h ~/ 2, (w * 0.8).round(), h ~/ 2),
      _       => throw 'Unknown swipe direction: $direction',
    };

    await driver.swipe(
        coords.$1, coords.$2, coords.$3, coords.$4, duration);
  }

  Future<void> _scrollUntilVisible(String text,
      {int maxScrolls = 10}) async {
    for (var i = 0; i < maxScrolls; i++) {
      final pos = await driver.findElementByText(text);
      if (pos != null) return;
      await _swipeDirection('UP', slow: true);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    throw 'Element never became visible after $maxScrolls scrolls: "$text"';
  }
}

// ---------------------------------------------------------------------------
// Key code tables
// ---------------------------------------------------------------------------

String _androidKeycode(String key) {
  const keycodes = {
    'enter':       'KEYCODE_ENTER',
    'back':        'KEYCODE_BACK',
    'home':        'KEYCODE_HOME',
    'tab':         'KEYCODE_TAB',
    'delete':      'KEYCODE_DEL',
    'backspace':   'KEYCODE_DEL',
    'menu':        'KEYCODE_MENU',
    'search':      'KEYCODE_SEARCH',
    'up':          'KEYCODE_DPAD_UP',
    'down':        'KEYCODE_DPAD_DOWN',
    'left':        'KEYCODE_DPAD_LEFT',
    'right':       'KEYCODE_DPAD_RIGHT',
    'power':       'KEYCODE_POWER',
    'volume_up':   'KEYCODE_VOLUME_UP',
    'volume_down': 'KEYCODE_VOLUME_DOWN',
    'space':       'KEYCODE_SPACE',
    'escape':      'KEYCODE_ESCAPE',
  };
  return keycodes[key.toLowerCase()] ?? key;
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

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