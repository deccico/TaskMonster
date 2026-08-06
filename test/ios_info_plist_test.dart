import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();

  test('Face ID usage description is declared for the parent lock', () {
    // The parent-lock verify dialog authenticates biometric-first via
    // local_auth; on Face ID devices iOS blocks the prompt unless
    // NSFaceIDUsageDescription is present in Info.plist.
    final value = RegExp(
      r'<key>NSFaceIDUsageDescription</key>\s*<string>([^<]+)</string>',
    ).firstMatch(plist);
    expect(value, isNotNull,
        reason: 'Info.plist must declare NSFaceIDUsageDescription');
    expect(value!.group(1)!.trim(), isNotEmpty);
  });
}
