import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_monster/models/monster_state.dart';
import 'package:task_monster/models/parent_lock_state.dart';
import 'package:task_monster/screens/home_screen.dart';
import 'package:task_monster/services/biometric_gate.dart';
import 'package:task_monster/services/update_checker.dart';
import 'package:task_monster/version.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Test double for the fingerprint reader: availability and the outcome of
/// an authentication attempt are both scripted per test.
class FakeBiometrics extends BiometricGate {
  FakeBiometrics({this.isAvailable = false, this.approves = false});

  bool isAvailable;
  bool approves;

  @override
  Future<bool> get available async => isAvailable;

  @override
  Future<bool> authenticate(String reason) async => approves;
}

/// Drives the real HomeScreen through the Idle -> Working -> Evolving -> Idle
/// flow to confirm the guided loop is wired correctly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The audioplayers plugin has no native side in tests; stub its channels.
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in const <String>[
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
      return null;
    });
  }

  // wakelock_plus has no native side in tests; stub its channel too.
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/wakelock'),
    (call) async => null,
  );

  // Clipboard (SystemChannels.platform) has no host in tests either; without
  // a stub, Clipboard.setData never completes.
  messenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => null,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  late ParentLockState lockState;
  late UpdateChecker updateChecker;
  late FakeBiometrics biometrics;
  String? deployedVersion; // what the fake version.json fetch reports

  Future<MonsterState> pumpApp(WidgetTester tester) async {
    final state = MonsterState();
    await state.load();
    lockState = ParentLockState();
    await lockState.load();
    deployedVersion = null;
    updateChecker = UpdateChecker(fetchVersion: () async => deployedVersion);
    biometrics = FakeBiometrics();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MonsterState>.value(value: state),
          ChangeNotifierProvider<ParentLockState>.value(value: lockState),
          ChangeNotifierProvider<UpdateChecker>.value(value: updateChecker),
          Provider<BiometricGate>.value(value: biometrics),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    return state;
  }

  /// Taps the given digits on the PIN keypad, pumping between taps.
  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.widgetWithText(FilledButton, digit));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500)); // shake animation
  }

  // Cancels the periodic ticker / animation timers before the framework's
  // pending-timer check at teardown.
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  }

  testWidgets('idle shows the prompt and a Start button', (tester) async {
    await pumpApp(tester);

    expect(find.text('Are you ready to start your task?'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('Stage 1'), findsOneWidget);
    // Reset control is present in the app bar (icon-only, with a tooltip).
    expect(find.byTooltip('Reset'), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt), findsOneWidget);
    // The active profile button shows the default user's name.
    expect(find.widgetWithText(TextButton, 'Player 1'), findsOneWidget);
    // The version badge is shown.
    expect(find.text('v$kAppVersion'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('profile switcher adds a user and switches the active name', (
    tester,
  ) async {
    await pumpApp(tester);

    // Open the switcher sheet from the app-bar profile button.
    await tester.tap(find.widgetWithText(TextButton, 'Player 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Users'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Add user'), findsOneWidget);

    // Add a new user via the editor dialog.
    await tester.tap(find.widgetWithText(ListTile, 'Add user'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('New user'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Sam');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // The app bar now shows the newly-created, now-active user.
    expect(find.widgetWithText(TextButton, 'Sam'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Player 1'), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('Start -> 10s wait -> Ready -> evolve -> back to Start', (
    tester,
  ) async {
    final state = await pumpApp(tester);

    // Start the task; Ready is present but locked.
    await tester.tap(find.text('START'));
    await tester.pump();
    expect(find.textContaining('Ready in'), findsOneWidget);
    expect(state.currentStage, 1); // no evolution yet

    // Advance the 10-second task timer one tick at a time.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text("I'M READY!"), findsOneWidget);

    // Press Ready -> evolution happens, phase becomes Evolving.
    await tester.tap(find.text("I'M READY!"));
    await tester.pump();
    expect(state.currentStage, 2);
    expect(find.text('Stage 2'), findsOneWidget);
    expect(find.text('Evolving…'), findsOneWidget);

    // After the 3-second celebration we return to Idle.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('START'), findsOneWidget);
    expect(find.text('Are you ready to start your task?'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('Ready is ignored before the 10s gate', (tester) async {
    final state = await pumpApp(tester);

    await tester.tap(find.text('START'));
    await tester.pump(const Duration(seconds: 5));

    // Still locked: the ready label is absent, so tapping the disabled button
    // must not evolve.
    expect(find.text("I'M READY!"), findsNothing);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();
    expect(state.currentStage, 1);

    await teardownTree(tester);
  });

  testWidgets('fires the cheerful wrap-up nudge at the 5-minute mark', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('START'));
    await tester.pump();

    // Well before 5 minutes: normal working state, no nudge.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Task in progress'), findsOneWidget);
    expect(find.text('Time to wrap up! 🎉'), findsNothing);

    // Advance to the 5-minute (300s) mark, one tick at a time.
    for (var i = 30; i < 300; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    // The nudge is now showing: amber "wrap up" subtext + upbeat message,
    // and the working timer keeps running (Ready stays available).
    expect(find.text('Time to wrap up! 🎉'), findsOneWidget);
    expect(find.text('Task in progress'), findsNothing);
    expect(find.text("Time's up — hit READY! 🎉"), findsOneWidget);
    expect(find.text("I'M READY!"), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('reset button confirms then returns to Stage 1', (tester) async {
    final state = await pumpApp(tester);

    // Evolve once via the full flow so we have progress to reset.
    await tester.tap(find.text('START'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text("I'M READY!"));
    await tester.pump(const Duration(seconds: 3));
    expect(state.currentStage, 2);

    // Open the reset dialog and confirm. (pumpAndSettle can't be used: the
    // cheer mascot animates continuously, so the tree never settles.)
    await tester.tap(find.byIcon(Icons.restart_alt));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Reset progress?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pump();

    expect(state.currentStage, 1);
    expect(find.text('START'), findsOneWidget); // back to idle

    await teardownTree(tester);
  });

  testWidgets('parent lock gates Ready behind the PIN dialog', (tester) async {
    final state = await pumpApp(tester);
    await lockState.enable('1234');
    await tester.pump();

    // Complete a task and press Ready -> the grown-up dialog appears and the
    // stage must NOT advance yet.
    await tester.tap(find.text('START'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text("I'M READY!"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Ask a grown-up! 🔒'), findsOneWidget);
    expect(state.currentStage, 1);

    // Wrong PIN: rejected, dialog stays, still stage 1.
    await enterPin(tester, '9999');
    expect(find.text('Wrong PIN — try again'), findsOneWidget);
    expect(find.text('Ask a grown-up! 🔒'), findsOneWidget);
    expect(state.currentStage, 1);

    // Correct PIN: approved, evolution runs.
    await enterPin(tester, '1234');
    await tester.pump();
    expect(state.currentStage, 2);
    expect(find.text('Evolving…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await teardownTree(tester);
  });

  testWidgets('dismissing the parent dialog keeps the task running', (
    tester,
  ) async {
    final state = await pumpApp(tester);
    await lockState.enable('1234');
    await tester.pump();

    await tester.tap(find.text('START'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text("I'M READY!"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Cancel: no evolution, and Ready is still available for a retry.
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(state.currentStage, 1);
    expect(find.text("I'M READY!"), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('parent lock is enabled from the header lock icon', (
    tester,
  ) async {
    await pumpApp(tester);

    // The header shows an open lock while the lock is off.
    expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.lock_open_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Choose and confirm a PIN. Without a biometric reader there is no
    // fingerprint opt-in switch.
    expect(find.text('Set parent PIN'), findsOneWidget);
    expect(find.text('Allow fingerprint approval'), findsNothing);
    await enterPin(tester, '1234');
    expect(find.text('Confirm PIN'), findsOneWidget);
    await enterPin(tester, '1234');
    await tester.pump();

    expect(lockState.enabled, isTrue);
    expect(lockState.verify('1234'), isTrue);
    // Icon reflects the enabled state.
    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.byIcon(Icons.lock_open_outlined), findsNothing);

    // The users sheet no longer hosts the toggle.
    await tester.tap(find.widgetWithText(TextButton, 'Player 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Parent lock'), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('setup offers the fingerprint switch; left on, it allows '
      'biometric approval', (tester) async {
    await pumpApp(tester);
    biometrics.isAvailable = true;
    await tester.pump();

    await tester.tap(find.byIcon(Icons.lock_open_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Setup shows the opt-in switch (on by default), not the fingerprint
    // prompt — choosing a PIN always happens on the keypad.
    expect(find.text('Allow fingerprint approval'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsNothing);

    await enterPin(tester, '1234');
    await enterPin(tester, '1234');
    await tester.pump();

    expect(lockState.enabled, isTrue);
    expect(lockState.biometricAllowed, isTrue);

    await teardownTree(tester);
  });

  testWidgets('fingerprint opt-out at setup hides the button at the gate', (
    tester,
  ) async {
    final state = await pumpApp(tester);
    biometrics
      ..isAvailable = true
      ..approves = true;
    await tester.pump();

    // Enable the lock, switching fingerprint approval OFF.
    await tester.tap(find.byIcon(Icons.lock_open_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await enterPin(tester, '1234');
    await enterPin(tester, '1234');
    await tester.pump();
    expect(lockState.enabled, isTrue);
    expect(lockState.biometricAllowed, isFalse);

    // Reach the evolution gate: the dialog is PIN-only despite the reader.
    await tester.tap(find.text('START'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text("I'M READY!"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Ask a grown-up! 🔒'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
    // The keypad shows straight away — no fallback step.
    expect(find.widgetWithText(FilledButton, '5'), findsOneWidget);

    // The PIN still approves.
    await enterPin(tester, '1234');
    await tester.pump();
    expect(state.currentStage, 2);

    await tester.pump(const Duration(seconds: 3));
    await teardownTree(tester);
  });

  testWidgets('fingerprint leads at the parent gate and approves without '
      'any tap', (tester) async {
    final state = await pumpApp(tester);
    await lockState.enable('1234');
    biometrics
      ..isAvailable = true
      ..approves = true;
    await tester.pump();

    // Reach the gate: complete a task and press Ready.
    await tester.tap(find.text('START'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text("I'M READY!"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // The dialog auto-runs the fingerprint prompt and approves on its own —
    // no button press, no PIN.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(state.currentStage, 2); // approved without a PIN
    await tester.pump(const Duration(seconds: 3));
    await teardownTree(tester);
  });

  testWidgets('a failed fingerprint keeps the dialog and the PIN works', (
    tester,
  ) async {
    final state = await pumpApp(tester);
    await lockState.enable('1234');
    biometrics
      ..isAvailable = true
      ..approves = false;
    await tester.pump();

    await tester.tap(find.text('START'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text("I'M READY!"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // The auto-run prompt was rejected: the dialog stays on the
    // fingerprint-first view, keypad hidden behind the fallback button.
    await tester.pump();
    expect(find.text('Ask a grown-up! 🔒'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
    expect(find.text('Fingerprint not recognized — try again'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '5'), findsNothing);
    expect(state.currentStage, 1);

    // Tapping the icon retries; still rejected, still stage 1.
    await tester.tap(find.byIcon(Icons.fingerprint));
    await tester.pump();
    expect(state.currentStage, 1);

    // The PIN fallback reveals the keypad, which still approves.
    await tester.tap(find.text('Use PIN instead'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '5'), findsOneWidget);
    await enterPin(tester, '1234');
    await tester.pump();
    expect(state.currentStage, 2);

    await tester.pump(const Duration(seconds: 3));
    await teardownTree(tester);
  });

  testWidgets('fingerprint unlocks the parent lock from the header', (
    tester,
  ) async {
    await pumpApp(tester);
    await lockState.enable('1234');
    biometrics
      ..isAvailable = true
      ..approves = true;
    await tester.pump();

    expect(find.byIcon(Icons.lock), findsOneWidget);
    await tester.tap(find.byIcon(Icons.lock));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // The prompt auto-runs and approves without any tap.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(lockState.enabled, isFalse);
    expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('no fingerprint button without a biometric reader', (
    tester,
  ) async {
    await pumpApp(tester);
    await lockState.enable('1234');
    // biometrics.isAvailable stays false (the default).
    await tester.pump();

    await tester.tap(find.byIcon(Icons.lock));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Ask a grown-up! 🔒'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsNothing);
    // The keypad is the primary (and only) gate.
    expect(find.widgetWithText(FilledButton, '5'), findsOneWidget);

    await teardownTree(tester);
  });

  testWidgets('the gate shows fingerprint first: keypad hidden until '
      '"Use PIN instead"', (tester) async {
    await pumpApp(tester);
    await lockState.enable('1234');
    biometrics
      ..isAvailable = true
      ..approves = false;
    await tester.pump();

    await tester.tap(find.byIcon(Icons.lock));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    // Fingerprint-first view: icon and fallback button, no keypad.
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
    expect(find.text('Use PIN instead'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '5'), findsNothing);

    // The fallback reveals the keypad and hides the fingerprint view.
    await tester.tap(find.text('Use PIN instead'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '5'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsNothing);

    await teardownTree(tester);
  });

  testWidgets('info menu opens About, Support, and Credits dialogs', (
    tester,
  ) async {
    // Runs as Android (flutter_test's default target platform), where the
    // donation entry is shown — the iOS case is covered by the test below.
    await pumpApp(tester);

    Future<void> openMenu() async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> openEntry(String title) async {
      await tester.tap(find.widgetWithText(ListTile, title));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> closeDialog() async {
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    // The kebab button opens a sheet listing the three entries.
    await openMenu();
    expect(find.widgetWithText(ListTile, 'About Task Monster'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Support'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Buy me a coffee'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Credits'), findsOneWidget);

    // About: the kid-friendly pitch plus the app version.
    await openEntry('About Task Monster');
    expect(find.text('About Task Monster 🐾'), findsOneWidget);
    expect(
      find.textContaining('turns everyday tasks into an adventure'),
      findsOneWidget,
    );
    expect(find.text('Version v$kAppVersion'), findsOneWidget);
    await closeDialog();

    // Support: shows the contact email and copies it to the clipboard.
    await openMenu();
    await openEntry('Support');
    expect(find.textContaining('hello@darumatic.com'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Copy email'));
    // Extra pumps: the async clipboard write resolves, then the snackbar
    // animates in.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Email address copied!'), findsOneWidget); // snackbar
    await tester.pump(const Duration(seconds: 5)); // let the snackbar expire

    // Buy me a coffee: the pitch plus the branded link button. The link is
    // adult-gated (Play Families policy), so tapping the CTA shows the
    // arithmetic challenge instead of leaving the app.
    await openMenu();
    await openEntry('Buy me a coffee');
    expect(find.text('Keep Task Monster rolling ☕'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Buy me a coffee'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Grown-ups only'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Keep Task Monster rolling ☕'), findsOneWidget);
    await closeDialog();

    // Credits: author and technology partner.
    await openMenu();
    await openEntry('Credits');
    expect(find.text('CREATED BY'), findsOneWidget);
    expect(find.text('Adrian Deccico'), findsOneWidget);
    expect(find.text('TECHNOLOGY PARTNER'), findsOneWidget);
    expect(find.text('Darumatic'), findsOneWidget);
    expect(find.text('darumatic.com'), findsOneWidget);
    await closeDialog();

    await teardownTree(tester);
  });

  testWidgets('info menu hides the donation entry on iOS', (tester) async {
    // App Store Review does not allow the donation link, so the entry is
    // dropped from the sheet on iOS — the rest of the menu stays put.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.widgetWithText(ListTile, 'Buy me a coffee'), findsNothing);
    expect(find.widgetWithText(ListTile, 'About Task Monster'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Support'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Credits'), findsOneWidget);

    // Reset inside the body: the binding asserts no foundation debug variable
    // is still set once the test function returns.
    debugDefaultTargetPlatformOverride = null;
    await teardownTree(tester);
  });

  testWidgets('update banner appears when a newer deploy is detected', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('✨ A new version is ready!'), findsNothing);

    deployedVersion = '99.0.0';
    await updateChecker.check();
    await tester.pump();

    expect(find.text('✨ A new version is ready!'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Update'), findsOneWidget);
    // Tapping Update must not crash (the reload is a no-op off web).
    await tester.tap(find.widgetWithText(FilledButton, 'Update'));
    await tester.pump();

    await teardownTree(tester);
  });
}
