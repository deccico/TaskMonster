import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the iOS App Store export path.
///
/// The default *automatic* export signing asks the Apple ID signed into
/// Xcode.app for a distribution certificate. The release Mac builds from the
/// CLI and has no Xcode account, so that default fails the release at the very
/// last step ("No Accounts") — after a full archive has been built. An App
/// Store Connect API key does not help: cloud-managed signing rejects it with
/// "Cloud signing permission error".
///
/// The fix is manual export options wired into scripts/release_ios.sh. These
/// tests keep the pieces in sync: the plist stays manual, the script passes it,
/// and the profile name matches the one scripts/mint_ios_profile.py creates.
void main() {
  final plist = File('ios/ExportOptions.plist');
  final script = File('scripts/release_ios.sh');
  final minter = File('scripts/mint_ios_profile.py');

  test('export options use manual App Store signing', () {
    expect(
      plist.existsSync(),
      isTrue,
      reason: 'ios/ExportOptions.plist is required by scripts/release_ios.sh',
    );
    final xml = plist.readAsStringSync();

    // Manual signing is the whole point — automatic needs an Xcode account.
    expect(xml, contains('<key>signingStyle</key>'));
    expect(xml, contains('<string>manual</string>'));
    expect(xml, isNot(contains('<string>automatic</string>')));
    expect(xml, contains('<string>app-store-connect</string>'));
    expect(xml, contains('<string>Apple Distribution</string>'));
    expect(xml, contains('<string>76UL6RCLTT</string>'));

    // The bundle id must map to the profile name installed on the release Mac.
    expect(xml, contains('<key>com.darumatic.taskMonster</key>'));
    expect(xml, contains('<string>Task Monster App Store</string>'));
  });

  test('release_ios.sh exports with the plist and preflights signing', () {
    expect(script.existsSync(), isTrue);
    final sh = script.readAsStringSync();

    expect(
      sh,
      contains('-exportOptionsPlist ios/ExportOptions.plist'),
      reason: 'without the plist the export falls back to automatic signing',
    );

    // Fail fast on missing signing material rather than after the archive.
    expect(sh, contains('security find-identity'));
    expect(sh, contains('Apple Distribution: DARUMATIC PTY LTD'));
    expect(sh, contains('Task Monster App Store'));
    expect(sh, contains('mint_ios_profile.py'));
  });

  test('the profile minter targets the same app and profile name', () {
    expect(minter.existsSync(), isTrue);
    final py = minter.readAsStringSync();

    // A profile is matched by name at export time, so a drift between these
    // two files breaks the release with a "profile not installed" preflight.
    expect(py, contains('PROFILE_NAME = "Task Monster App Store"'));
    expect(py, contains('BUNDLE_ID = "com.darumatic.taskMonster"'));
    expect(py, contains('PROFILE_TYPE = "IOS_APP_STORE"'));
  });
}
