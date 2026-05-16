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

class ConnectedDevice {
  final String id;
  final String state;
  final String? model;

  const ConnectedDevice({required this.id, required this.state, this.model});

  String get label => model != null ? '$model ($id)' : id;
}

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

Future<void> openDeviceViewer(ConnectedDevice device) async {
  print('Opening ${device.label} in scrcpy...\n');
  final process = await Process.start(
    'scrcpy',
    ['-s', device.id, '--window-title', device.label],
    mode: ProcessStartMode.inheritStdio,
  );
  await process.exitCode;
}