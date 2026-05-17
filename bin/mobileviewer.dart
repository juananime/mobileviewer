import 'dart:io';
import 'package:mobileviewer/mobileviewer.dart';
import 'package:mobileviewer/steps.dart';

void _printHelp() {
  print('''
Usage: mobileviewer --ios|--android [options] [flow.yaml]

Platform (required):
  --ios              Target an iOS simulator
  --android          Target an Android device or emulator

Options:
  --app <path>       Path to a .app bundle to install before running (iOS only)
  --verbose, -v      Stream raw xcodebuild / runner output (hidden by default)
  --help, -h         Show this help message

Examples:
  mobileviewer --ios flow.yaml
  mobileviewer --ios --app MyApp.app flow.yaml
  mobileviewer --ios --verbose flow.yaml
  mobileviewer --android flow.yaml
''');
}

void main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    _printHelp();
    return;
  }

  final isIos = arguments.contains('--ios');
  final isAndroid = arguments.contains('--android');
  final isVerbose = arguments.contains('--verbose') || arguments.contains('-v');

  if (!isIos && !isAndroid) {
    _printHelp();
    exit(1);
  }

  // Collect values that follow a named flag (e.g. --app <value>) so they are
  // not mistaken for positional arguments.
  final namedArgValues = <String>{};
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i].startsWith('--') && !arguments[i + 1].startsWith('--')) {
      namedArgValues.add(arguments[i + 1]);
    }
  }

  final appArgIndex = arguments.indexOf('--app');
  final appPath = appArgIndex != -1 && appArgIndex + 1 < arguments.length
      ? arguments[appArgIndex + 1]
      : null;

  final positional = arguments
      .where((a) => !a.startsWith('--') && !namedArgValues.contains(a))
      .toList();
  final yamlFile =
      positional.firstWhere((a) => a.endsWith('.yaml'), orElse: () => '');

  if (isIos) {
    await _runIos(yamlFile.isNotEmpty ? yamlFile : null,
        appPath: appPath, verbose: isVerbose);
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

Future<void> _runIos(String? yamlFile, {String? appPath, bool verbose = false}) async {
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

  final booted = devices.where((d) => d.isBooted).toList();

  if (booted.length == 1) {
    // Exactly one booted simulator — use it without prompting.
    target = booted.first;
    print('Target: ${target.label}');
  } else {
    // No booted simulators: show full list. Multiple booted: show only those.
    final candidates = booted.isNotEmpty ? booted : devices;
    final label = booted.isNotEmpty
        ? 'Multiple booted simulators found'
        : 'Available iOS devices and simulators';
    print('$label:\n');
    for (var i = 0; i < candidates.length; i++) {
      final bootedTag = candidates[i].isBooted ? ' [booted]' : '';
      print('  ${i + 1}. ${candidates[i].label}$bootedTag');
    }
    stdout.write('\nSelect target [1-${candidates.length}]: ');
    final input = stdin.readLineSync()?.trim() ?? '';
    final choice = int.tryParse(input);
    if (choice == null || choice < 1 || choice > candidates.length) {
      print('Invalid selection.');
      return;
    }
    target = candidates[choice - 1];
    if (!target.isBooted && target.isSimulator) {
      target = await bootIosSimulator(target);
    }
  }

  print('');

  // Install the app binary if --app was provided.
  String? bundleId;
  if (appPath != null) {
    print('Installing app: $appPath ...');
    await installIosApp(target.udid, appPath);
    bundleId = await extractBundleId(appPath);
    if (bundleId != null) {
      print('Bundle ID:      $bundleId');
    }
    print('');
  }

  if (yamlFile != null) {
    await runStepsFile(yamlFile, target.udid,
        ios: true, appIdFallback: bundleId, verbose: verbose);
    return;
  }

  // No YAML flow — launch the app directly (if installed) and open Simulator.
  if (bundleId != null) {
    print('Launching $bundleId ...');
    await Process.run('xcrun', ['simctl', 'launch', target.udid, bundleId]);
    print('');
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