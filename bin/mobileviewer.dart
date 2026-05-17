import 'dart:io';
import 'package:mobileviewer/mobileviewer.dart';
import 'package:mobileviewer/steps.dart';

void main(List<String> arguments) async {
  final isIos = arguments.contains('--ios');
  final positional =
      arguments.where((a) => !a.startsWith('--')).toList();
  final yamlFile =
      positional.firstWhere((a) => a.endsWith('.yaml'), orElse: () => '');

  if (isIos) {
    await _runIos(yamlFile.isNotEmpty ? yamlFile : null);
  } else {
    await _runAndroid(yamlFile.isNotEmpty ? yamlFile : null);
  }
}

// ---------------------------------------------------------------------------
// Android flow
// ---------------------------------------------------------------------------

Future<void> _runAndroid(String? yamlFile) async {
  print('Platform: Android\n');
  print('Checking Android development tools...\n');

  final results = await checkAndroidTools();
  _printToolResults(results);

  final adbInstalled = results.any((r) => r.name == 'adb' && r.installed);
  if (!adbInstalled) {
    print('adb is required to detect connected devices.');
    print('Make sure the Android SDK platform-tools are on your PATH.');
    return;
  }

  final emulatorInstalled =
      results.any((r) => r.name == 'emulator' && r.installed);
  final scrcpyInstalled =
      results.any((r) => r.name == 'scrcpy' && r.installed);

  print('Checking for connected Android devices...\n');

  var devices = await listConnectedDevices();

  if (devices.isEmpty) {
    if (!emulatorInstalled) {
      print('No devices connected and emulator tool not found.');
      return;
    }

    final avds = await listAvds();
    if (avds.isEmpty) {
      print('No devices connected and no AVDs configured.');
      print('Create one in Android Studio: Tools → AVD Manager.');
      return;
    }

    print('No devices connected. Available emulators:\n');
    for (var i = 0; i < avds.length; i++) {
      print('  ${i + 1}. ${avds[i]}');
    }
    stdout.write('\nSelect emulator to launch [1-${avds.length}]: ');
    final input = stdin.readLineSync()?.trim() ?? '';
    final choice = int.tryParse(input);
    if (choice == null || choice < 1 || choice > avds.length) {
      print('Invalid selection.');
      return;
    }

    print('');
    final booted = await launchAvd(avds[choice - 1]);
    devices = [booted];
  }

  ConnectedDevice target;

  if (devices.length == 1) {
    target = devices.first;
    print('Target: ${target.label}');
  } else {
    print('Multiple devices connected:');
    for (var i = 0; i < devices.length; i++) {
      print('  ${i + 1}. ${devices[i].label} — ${devices[i].state}');
    }
    stdout.write('\nSelect device [1-${devices.length}]: ');
    final input = stdin.readLineSync()?.trim() ?? '';
    final choice = int.tryParse(input);
    if (choice == null || choice < 1 || choice > devices.length) {
      print('Invalid selection.');
      return;
    }
    target = devices[choice - 1];
  }

  print('');

  if (yamlFile != null) {
    await runStepsFile(yamlFile, target.id);
    return;
  }

  if (!scrcpyInstalled) {
    print('scrcpy is required to render the device screen.');
    print('Install it with: brew install scrcpy');
    return;
  }

  await openDeviceViewer(target);
}

// ---------------------------------------------------------------------------
// iOS flow
// ---------------------------------------------------------------------------

Future<void> _runIos(String? yamlFile) async {
  print('Platform: iOS\n');
  print('Checking iOS development tools...\n');

  final results = await checkIosTools();
  _printToolResults(results);

  final xcrunInstalled = results.any((r) => r.name == 'xcrun' && r.installed);
  if (!xcrunInstalled) {
    print('xcrun is required for iOS automation.');
    print('Install Xcode from the Mac App Store, then run:');
    print('  xcode-select --install');
    return;
  }

  print('Checking for iOS simulators...\n');

  var devices = await listIosDevices();

  if (devices.isEmpty) {
    print('No iOS devices or simulators found.');
    print('Make sure Xcode is installed and simulators are configured.');
    return;
  }

  IosDevice target;

  if (devices.length == 1) {
    target = devices.first;
    if (!target.isBooted && target.isSimulator) {
      target = await bootIosSimulator(target);
    }
    print('Target: ${target.label}');
  } else {
    print('Available iOS devices and simulators:\n');
    for (var i = 0; i < devices.length; i++) {
      final booted = devices[i].isBooted ? ' [booted]' : '';
      print('  ${i + 1}. ${devices[i].label}$booted');
    }
    stdout.write('\nSelect target [1-${devices.length}]: ');
    final input = stdin.readLineSync()?.trim() ?? '';
    final choice = int.tryParse(input);
    if (choice == null || choice < 1 || choice > devices.length) {
      print('Invalid selection.');
      return;
    }
    target = devices[choice - 1];
    if (!target.isBooted && target.isSimulator) {
      target = await bootIosSimulator(target);
    }
  }

  print('');

  if (yamlFile != null) {
    await runStepsFile(yamlFile, target.udid, ios: true);
    return;
  }

  await openIosSimulatorViewer();
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

void _printToolResults(List<ToolCheckResult> results) {
  for (final result in results) {
    if (result.installed) {
      print('[✓] ${result.name}');
      if (result.path != null) print('    Path:    ${result.path}');
      if (result.version != null) print('    Version: ${result.version}');
    } else {
      print('[✗] ${result.name} — not found');
      if (result.error != null) print('    Error: ${result.error}');
    }
    print('');
  }
}