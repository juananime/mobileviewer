import 'dart:convert';
import 'dart:io';

class ToolCheckResult {
  final String name;
  final bool installed;
  final String? path;
  final String? version;
  final String? error;

  const ToolCheckResult({
    required this.name,
    required this.installed,
    this.path,
    this.version,
    this.error,
  });
}

Future<ToolCheckResult> checkTool(String toolName) async {
  try {
    final whichCommand = Platform.isWindows ? 'where' : 'which';
    final whichResult = await Process.run(whichCommand, [toolName]);

    if (whichResult.exitCode != 0) {
      return ToolCheckResult(name: toolName, installed: false);
    }

    final toolPath = (whichResult.stdout as String).trim().split('\n').first;

    final versionArgs = toolName == 'emulator' ? ['-version'] : ['version'];
    final versionResult = await Process.run(toolName, versionArgs);
    final versionOutput = (versionResult.stdout as String).trim();
    final versionLine =
        versionOutput.isNotEmpty ? versionOutput.split('\n').first : null;

    return ToolCheckResult(
      name: toolName,
      installed: true,
      path: toolPath,
      version: versionLine,
    );
  } catch (e) {
    return ToolCheckResult(
        name: toolName, installed: false, error: e.toString());
  }
}

Future<List<ToolCheckResult>> checkAndroidTools() async {
  final results = await Future.wait([
    checkTool('adb'),
    checkTool('emulator'),
    checkTool('scrcpy'),
  ]);
  return results;
}

Future<List<ToolCheckResult>> checkIosTools() async {
  final results = await Future.wait([
    checkTool('xcrun'),
    checkTool('xcodebuild'),
  ]);
  return results;
}

// ---------------------------------------------------------------------------
// Device types
// ---------------------------------------------------------------------------

class ConnectedDevice {
  final String id;
  final String state;
  final String? model;

  const ConnectedDevice({required this.id, required this.state, this.model});

  String get label => model != null ? '$model ($id)' : id;
}

class IosDevice {
  final String udid;
  final String name;
  final String state;
  final String osVersion;
  final bool isSimulator;

  const IosDevice({
    required this.udid,
    required this.name,
    required this.state,
    required this.osVersion,
    required this.isSimulator,
  });

  String get label =>
      '$name — $osVersion${isSimulator ? ' (Simulator)' : ''} ($udid)';

  bool get isBooted => state.toLowerCase() == 'booted';
}

// ---------------------------------------------------------------------------
// Android device management
// ---------------------------------------------------------------------------

Future<List<ConnectedDevice>> listConnectedDevices() async {
  final result = await Process.run('adb', ['devices', '-l']);
  final lines = (result.stdout as String).trim().split('\n');

  final deviceLines = lines.skip(1).where((l) => l.trim().isNotEmpty);

  final devices = <ConnectedDevice>[];
  for (final line in deviceLines) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final id = parts[0];
    final state = parts[1];
    final modelEntry =
        parts.firstWhere((p) => p.startsWith('model:'), orElse: () => '');
    final model = modelEntry.isNotEmpty ? modelEntry.substring(6) : null;
    devices.add(ConnectedDevice(id: id, state: state, model: model));
  }
  return devices;
}

Future<List<String>> listAvds() async {
  final result = await Process.run('emulator', ['-list-avds']);
  final output = (result.stdout as String).trim();
  if (output.isEmpty) return [];
  return output.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
}

Future<ConnectedDevice> launchAvd(String avdName) async {
  print('Starting emulator: $avdName ...');
  await Process.start('emulator', ['-avd', avdName],
      mode: ProcessStartMode.detached);

  stdout.write('Waiting for device to boot');
  for (var i = 0; i < 60; i++) {
    await Future.delayed(const Duration(seconds: 3));
    stdout.write('.');

    final devices = await listConnectedDevices();
    final emulator = devices.where((d) => d.id.startsWith('emulator-')).toList();
    if (emulator.isEmpty) continue;

    final target = emulator.first;
    final bootResult = await Process.run('adb', [
      '-s', target.id, 'shell', 'getprop', 'sys.boot_completed'
    ]);
    if ((bootResult.stdout as String).trim() == '1') {
      print('\nEmulator ready: ${target.label}\n');
      return target;
    }
  }

  throw 'Emulator did not boot within 3 minutes.';
}

Future<void> openDeviceViewer(ConnectedDevice device) async {
  print('Opening ${device.label} in scrcpy...\n');
  final process = await Process.start(
    'scrcpy',
    ['-s', device.id, '--window-title', device.label],
    mode: ProcessStartMode.inheritStdio,
  );
  await process.exitCode;
}

// ---------------------------------------------------------------------------
// iOS device management
// ---------------------------------------------------------------------------

Future<List<IosDevice>> listIosDevices() async {
  final result = await Process.run(
      'xcrun', ['simctl', 'list', 'devices', '--json']);
  if (result.exitCode != 0) return [];

  final devices = <IosDevice>[];
  try {
    final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final deviceMap = json['devices'] as Map<String, dynamic>;

    for (final entry in deviceMap.entries) {
      final runtime = entry.key;
      final devList = entry.value as List<dynamic>;

      final osMatch = RegExp(r'iOS-(\d+)-(\d+)').firstMatch(runtime);
      if (osMatch == null) continue; // skip non-iOS runtimes (watchOS, tvOS…)
      final osVersion = 'iOS ${osMatch.group(1)}.${osMatch.group(2)}';

      for (final dev in devList) {
        final map = dev as Map<String, dynamic>;
        if (map['isAvailable'] != true) continue;
        devices.add(IosDevice(
          udid: map['udid'] as String,
          name: map['name'] as String,
          state: map['state'] as String? ?? '',
          osVersion: osVersion,
          isSimulator: true,
        ));
      }
    }
  } catch (_) {}

  return devices;
}

Future<IosDevice> bootIosSimulator(IosDevice sim) async {
  if (sim.isBooted) return sim;

  print('Booting simulator: ${sim.name} ...');
  await Process.run('xcrun', ['simctl', 'boot', sim.udid]);

  stdout.write('Waiting for simulator to boot');
  for (var i = 0; i < 30; i++) {
    await Future.delayed(const Duration(seconds: 2));
    stdout.write('.');

    final devices = await listIosDevices();
    final updated = devices.where((d) => d.udid == sim.udid).firstOrNull;
    if (updated != null && updated.isBooted) {
      print('\nSimulator ready: ${updated.name}\n');
      return updated;
    }
  }

  throw 'Simulator did not boot within 60 seconds.';
}

Future<void> openIosSimulatorViewer() async {
  print('Opening Simulator app...\n');
  await Process.run('open', ['-a', 'Simulator']);
}