import 'package:mobileviewer/mobileviewer.dart';
import 'package:test/test.dart';

void main() {
  test('ConnectedDevice label uses model when available', () {
    final device = ConnectedDevice(id: 'emulator-5554', state: 'device', model: 'Pixel_6');
    expect(device.label, 'Pixel_6 (emulator-5554)');
  });

  test('ConnectedDevice label falls back to id', () {
    final device = ConnectedDevice(id: 'emulator-5554', state: 'device');
    expect(device.label, 'emulator-5554');
  });
}