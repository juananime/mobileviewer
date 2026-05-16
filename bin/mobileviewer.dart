import 'dart:io';
import 'package:mobileviewer/mobileviewer.dart';
import 'package:mobileviewer/steps.dart';

void main(List<String> arguments) async {
  print('Checking Android development tools...\n');

  final results = await checkAndroidTools();

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

  // No device connected — offer to start an emulator
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

  // If a YAML file is provided, run the e2e steps
  if (arguments.isNotEmpty && arguments.first.endsWith('.yaml')) {
    await runStepsFile(arguments.first, target.id);
    return;
  }

  if (!scrcpyInstalled) {
    print('scrcpy is required to render the device screen.');
    print('Install it with: brew install scrcpy');
    return;
  }

  await openDeviceViewer(target);
}