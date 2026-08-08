import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/animals.dart';
import '../data/stages.dart';
import '../models/monster_state.dart';
import '../models/parent_lock_state.dart';
import '../models/profile.dart';
import '../services/adult_gate.dart';
import '../services/analytics.dart';
import '../services/open_url_io.dart'
    if (dart.library.js_interop) '../services/open_url_web.dart';
import '../services/parent_gate.dart';
import '../services/update_checker.dart';
import '../version.dart';
import '../widgets/cheer_character.dart';
import '../widgets/monster_display.dart';
import '../widgets/pin_pad_dialog.dart';
import '../widgets/stage_tracker.dart';

/// The guided task loop: Idle -> Working -> Evolving -> Idle.
enum _Phase { idle, working, evolving }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  /// Minimum seconds the user must "work" before Ready unlocks.
  static const int _minTaskSeconds = 10;

  /// Seconds of work after which we cheerfully nudge the user to wrap up.
  /// ~5 minutes is about the practical limit to finish a single task.
  static const int _alarmSeconds = 5 * 60; // 300

  /// How long the evolution celebration plays before returning to Idle.
  static const int _evolveSeconds = 3;

  static const List<String> _idleCheers = <String>[
    "Ready to crush a task? 💪",
    "What are we tackling next?",
    "Let's make progress!",
    "Your monster's counting on you!",
  ];
  static const List<String> _workingCheers = <String>[
    "You've got this — keep going!",
    "Focus mode: ON 🔥",
    "Every second counts!",
    "Stay with it, almost there!",
  ];
  static const List<String> _evolveCheers = <String>[
    "WOOHOO! 🎉",
    "Incredible work!",
    "Level up! ⭐",
    "That's how it's done!",
  ];

  final AudioPlayer _player = AudioPlayer();
  // Separate player so the wrap-up alarm can't be cut off by (or cut off) the
  // evolve sound if the two ever overlap.
  final AudioPlayer _alarmPlayer = AudioPlayer();
  final Random _rng = Random();

  _Phase _phase = _Phase.idle;
  int _elapsed = 0; // seconds since Start, during the working phase
  bool _alarmFired = false; // true once the 5-minute wrap-up nudge has played
  int _triggerCount = 0; // drives the monster evolve animation
  late String _cheerMessage = _pick(_idleCheers);

  Timer? _workTimer;
  Timer? _evolveTimer;

  bool get _ready => _elapsed >= _minTaskSeconds;

  String _pick(List<String> list) => list[_rng.nextInt(list.length)];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player.setReleaseMode(ReleaseMode.stop);
    _alarmPlayer.setReleaseMode(ReleaseMode.stop);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _workTimer?.cancel();
    _evolveTimer?.cancel();
    _player.dispose();
    _alarmPlayer.dispose();
    unawaited(_setWakelock(false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A browser screen wake lock is auto-released whenever the page/app is
    // hidden (e.g. on mobile Firefox/Chrome when you switch tabs or apps). When
    // we come back to the foreground mid-task, re-assert it so the screen keeps
    // staying awake.
    if (state == AppLifecycleState.resumed && _phase == _Phase.working) {
      unawaited(_setWakelock(true));
    }
    // A tab refocused after days away should learn about new deploys
    // immediately rather than waiting for the next poll.
    if (state == AppLifecycleState.resumed) {
      unawaited(context.read<UpdateChecker>().check());
    }
  }

  void _onStart() {
    _workTimer?.cancel();
    analytics.logEvent('task_started', <String, Object>{
      'stage': context.read<MonsterState>().currentStage,
    });
    setState(() {
      _phase = _Phase.working;
      _elapsed = 0;
      _alarmFired = false;
      _cheerMessage = _pick(_workingCheers);
    });
    _workTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsed++;
        if (!_alarmFired && _elapsed >= _alarmSeconds) {
          _alarmFired = true;
          _fireWrapUpAlarm();
        }
      });
    });
    unawaited(_setWakelock(true));
  }

  Future<void> _onReady() async {
    if (_phase != _Phase.working || !_ready) return;

    // Parental lock: a grown-up approves the evolution before it happens.
    // The work timer keeps running while the dialog is up, so a denied or
    // dismissed approval loses nothing — the kid can call the parent over
    // and press Ready again.
    final approved = await ParentGate.requestApproval(context);
    if (!mounted || !approved || _phase != _Phase.working) return;

    _workTimer?.cancel();
    final taskSeconds = _elapsed;

    final monster = context.read<MonsterState>();
    await monster.evolve();
    if (!mounted) return;

    analytics.logEvent('evolution', <String, Object>{
      'stage': monster.currentStage,
      'prestige_count': monster.prestigeCount,
      'task_seconds': taskSeconds,
      'is_prestige': monster.lastWasPrestige ? 1 : 0,
    });

    setState(() {
      _phase = _Phase.evolving;
      _triggerCount++;
      _cheerMessage = _pick(_evolveCheers);
    });
    unawaited(HapticFeedback.heavyImpact());
    unawaited(_playSound());

    _evolveTimer?.cancel();
    _evolveTimer = Timer(const Duration(seconds: _evolveSeconds), () {
      if (!mounted) return;
      unawaited(_setWakelock(false));
      setState(() {
        _phase = _Phase.idle;
        _cheerMessage = _pick(_idleCheers);
      });
    });
  }

  /// The cheerful 5-minute nudge: chime + buzz + an upbeat "wrap it up"
  /// message, prompting the user to finish and hit READY.
  void _fireWrapUpAlarm() {
    _cheerMessage = "Time's up — hit READY! 🎉";
    unawaited(HapticFeedback.mediumImpact());
    unawaited(_playAlarm());
  }

  Future<void> _playAlarm() async {
    try {
      await _alarmPlayer.stop();
      await _alarmPlayer.play(AssetSource('audio/alarm.wav'));
    } catch (_) {
      // Sound is non-critical; never let an audio failure break the flow.
    }
  }

  Future<void> _playSound() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('audio/evolve.wav'));
    } catch (_) {
      // Sound is non-critical; never let an audio failure break the flow.
    }
  }

  /// Keep the screen awake during a task so the timer + 5-minute nudge stay
  /// visible. Non-critical: a failure (e.g. a browser without Wake Lock
  /// support) must never break the flow.
  Future<void> _setWakelock(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (_) {}
  }

  Future<void> _confirmReset() async {
    final monster = context.read<MonsterState>();
    final hasPrestige = monster.prestigeCount > 0;

    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset progress?'),
        content: Text(
          hasPrestige
              ? 'Send your monster back to Stage 1. Keep your '
                    'Prestige ×${monster.prestigeCount}, or wipe everything?'
              : 'Send your monster back to Stage 1?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'cancel'),
            child: const Text('Cancel'),
          ),
          if (hasPrestige)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'wipe'),
              child: const Text('Reset everything'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'keep'),
            child: Text(hasPrestige ? 'Keep prestige' : 'Reset'),
          ),
        ],
      ),
    );

    if (!mounted || choice == null || choice == 'cancel') return;
    analytics.logEvent('reset', <String, Object>{
      'keep_prestige': choice == 'keep' ? 1 : 0,
    });
    await monster.reset(keepPrestige: choice == 'keep');
    if (!mounted) return;
    _returnToIdle();
  }

  /// Cancel any in-progress task and return the loop to Idle. Shared by reset
  /// and profile switching so a fresh user (or a fresh run) starts clean.
  void _returnToIdle() {
    _workTimer?.cancel();
    _evolveTimer?.cancel();
    unawaited(_setWakelock(false));
    setState(() {
      _phase = _Phase.idle;
      _elapsed = 0;
      _alarmFired = false;
      _cheerMessage = _pick(_idleCheers);
    });
  }

  /// The user switcher: pick a profile, add a new one, or edit/delete.
  Future<void> _openProfileSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          // Scrollable so many profiles + the parent-lock row never overflow
          // the sheet's height budget.
          child: SingleChildScrollView(
            child: Consumer<MonsterState>(
              builder: (context, monster, _) {
                final profiles = monster.profiles;
                final activeId = monster.activeProfile.id;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Users',
                          style: Theme.of(sheetContext).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    for (final p in profiles)
                      ListTile(
                        leading: Text(
                          p.animal,
                          style: const TextStyle(fontSize: 28),
                        ),
                        title: Text(p.name),
                        selected: p.id == activeId,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (p.id == activeId)
                              Icon(Icons.check_circle, color: scheme.primary),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Edit',
                              onPressed: () => _openProfileEditor(existing: p),
                            ),
                            if (profiles.length > 1)
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete',
                                onPressed: () => _confirmDeleteProfile(p),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _selectProfile(p.id);
                        },
                      ),
                    const Divider(height: 8),
                    ListTile(
                      leading: const Icon(Icons.add),
                      title: const Text('Add user'),
                      onTap: () => _openProfileEditor(),
                    ),
                    const SizedBox(height: 8),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  static const String _supportEmail = 'hello@darumatic.com';
  static const String _buyMeACoffeeUrl = 'https://buymeacoffee.com/darumatic';
  static const String _darumaticUrl = 'https://darumatic.com';

  /// Donation links are not allowed in the iOS build (App Store Review
  /// guidelines), so the "Buy me a coffee" entry is Android/web only.
  static bool get _donationsAllowed =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.iOS;

  /// The little info menu behind the header's kebab button: About, Support,
  /// Buy me a coffee (except on iOS), and Credits.
  Future<void> _openInfoMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;

        Widget leadingIcon(IconData icon) => Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 20, color: scheme.primary),
        );

        return SafeArea(
          // Scrollable so the rows never overflow the sheet's height budget
          // on short screens.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: leadingIcon(Icons.info_outline_rounded),
                  title: const Text('About Task Monster'),
                  subtitle: const Text('What this app is all about'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showAboutDialog();
                  },
                ),
                ListTile(
                  leading: leadingIcon(Icons.mail_outline_rounded),
                  title: const Text('Support'),
                  subtitle: const Text(_supportEmail),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showSupportDialog();
                  },
                ),
                if (_donationsAllowed)
                  ListTile(
                    leading: leadingIcon(Icons.local_cafe_outlined),
                    title: const Text('Buy me a coffee'),
                    subtitle: const Text('Shout the dev a coffee'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showCoffeeDialog();
                    },
                  ),
                ListTile(
                  leading: leadingIcon(Icons.favorite_outline_rounded),
                  title: const Text('Credits'),
                  subtitle: const Text('Who made this'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showCreditsDialog();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Off-app links pass through the [AdultGate] (Play Families policy: a
  /// child must not be able to casually leave the app).
  Future<void> _openGatedLink(String url) async {
    if (!await AdultGate.requestApproval(context)) return;
    openExternalUrl(url);
  }

  Future<void> _showAboutDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('About Task Monster 🐾'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Task Monster turns everyday tasks into an adventure! '
              'Eating dinner, brushing teeth, studying, tidying up — every '
              'task a kid completes feeds their monster and helps it grow '
              'into something amazing.\n\n'
              'Little wins, big monsters! 🎉',
            ),
            const SizedBox(height: 12),
            Text(
              'Version v$kAppVersion',
              style: Theme.of(dialogContext).textTheme.labelSmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSupportDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Support'),
        content: const Text(
          'Questions, ideas, or something not working? '
          "We'd love to hear from you:\n\n"
          '$_supportEmail',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: _supportEmail));
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(content: Text('Email address copied!')),
              );
              Navigator.pop(dialogContext);
            },
            child: const Text('Copy email'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCoffeeDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Keep Task Monster rolling ☕'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'Task Monster is free and ad-free. If it helps your family '
              'get things done, you can shout the dev a coffee!',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  // Official Buy Me a Coffee brand colours.
                  backgroundColor: const Color(0xFFFFDD00),
                  foregroundColor: const Color(0xFF0D0C22),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: const StadiumBorder(),
                ),
                icon: const Icon(Icons.local_cafe, size: 20),
                label: const Text(
                  'Buy me a coffee',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                onPressed: () => _openGatedLink(_buyMeACoffeeUrl),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Donations keep the servers running — the app stays free '
              'for everyone.',
              textAlign: TextAlign.center,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreditsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;

        TextStyle kickerStyle() => TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          color: scheme.onSurfaceVariant,
        );

        return AlertDialog(
          title: const Text('Credits'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('CREATED BY', style: kickerStyle()),
              const SizedBox(height: 4),
              const Text(
                'Adrian Deccico',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              Text('TECHNOLOGY PARTNER', style: kickerStyle()),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Darumatic',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () => _openGatedLink(_darumaticUrl),
                          child: Text(
                            'darumatic.com',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ClipOval(
                    child: Image.asset(
                      'assets/images/darumatic-logo.png',
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  /// Enable (choose a PIN) or disable (verify the PIN) the parental lock.
  Future<void> _toggleParentLock(bool on) async {
    final lock = context.read<ParentLockState>();
    if (on == lock.enabled) return;
    if (on) {
      final setup = await showPinSetupDialog(context);
      if (!mounted || setup == null) return;
      await lock.enable(setup.pin, allowBiometric: setup.allowBiometric);
      analytics.logEvent('parent_lock_enabled', const <String, Object>{});
    } else {
      final pin = await showPinVerifyDialog(context);
      if (!mounted || pin == null) return;
      // Empty string = the dialog approved via fingerprint, no PIN to check.
      if (pin.isEmpty) {
        await lock.disableApproved();
      } else {
        await lock.disable(pin);
      }
      analytics.logEvent('parent_lock_disabled', const <String, Object>{});
    }
  }

  Future<void> _selectProfile(String id) async {
    final monster = context.read<MonsterState>();
    if (id == monster.activeProfile.id) return;
    await monster.switchProfile(id);
    if (!mounted) return;
    analytics.logEvent('profile_switched', <String, Object>{
      'profile_count': monster.profiles.length,
    });
    _returnToIdle();
  }

  /// Create a new user or edit an existing one: a name field + an animal picker.
  Future<void> _openProfileEditor({Profile? existing}) async {
    final isEdit = existing != null;
    final result = await showDialog<_ProfileEditorResult>(
      context: context,
      builder: (_) => _ProfileEditorDialog(existing: existing),
    );
    if (!mounted || result == null) return;

    final monster = context.read<MonsterState>();
    if (isEdit) {
      final name = result.name.isEmpty ? existing.name : result.name;
      await monster.updateProfile(
        existing.id,
        name: name,
        animal: result.animal,
      );
    } else {
      final name = result.name.isEmpty
          ? 'Player ${monster.profiles.length + 1}'
          : result.name;
      await monster.addProfile(name, result.animal);
      if (!mounted) return;
      analytics.logEvent('profile_created', <String, Object>{
        'profile_count': monster.profiles.length,
      });
      _returnToIdle();
    }
  }

  Future<void> _confirmDeleteProfile(Profile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete user?'),
        content: Text(
          'Delete ${profile.name} and their monster progress? '
          'This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;
    final monster = context.read<MonsterState>();
    final wasActive = profile.id == monster.activeProfile.id;
    final ok = await monster.deleteProfile(profile.id);
    if (!mounted || !ok) return;
    analytics.logEvent('profile_deleted', <String, Object>{
      'profile_count': monster.profiles.length,
    });
    if (wasActive) _returnToIdle();
  }

  @override
  Widget build(BuildContext context) {
    final monster = context.watch<MonsterState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        // Taller than the 56px default so the logo can render at 80px
        // without cropping.
        toolbarHeight: 96,
        // Explicit foreground so the title + actions stay high-contrast on the
        // dark surface (the default icon colour was blending in).
        foregroundColor: scheme.onSurface,
        title: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Image.asset(
            'assets/images/task-monster.png',
            height: 80,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            semanticLabel: 'Task Monster',
          ),
        ),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              icon: Text(
                monster.activeProfile.animal,
                style: const TextStyle(fontSize: 20),
              ),
              label: Text(
                monster.activeProfile.name,
                overflow: TextOverflow.ellipsis,
              ),
              onPressed: _openProfileSheet,
              style: TextButton.styleFrom(
                foregroundColor: scheme.primary,
                // Keep long names from pushing Reset off the bar.
                maximumSize: const Size(140, double.infinity),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt),
            color: scheme.primary,
            tooltip: 'Reset',
            visualDensity: VisualDensity.compact,
            onPressed: _confirmReset,
          ),
          Consumer<ParentLockState>(
            builder: (context, lock, _) => IconButton(
              icon: Icon(lock.enabled ? Icons.lock : Icons.lock_open_outlined),
              color: scheme.primary,
              tooltip: lock.enabled
                  ? 'Parent lock is on'
                  : 'Set up parent lock',
              visualDensity: VisualDensity.compact,
              onPressed: () => _toggleParentLock(!lock.enabled),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: IconButton(
              icon: const Icon(Icons.more_vert),
              color: scheme.primary,
              tooltip: 'Menu',
              visualDensity: VisualDensity.compact,
              onPressed: _openInfoMenu,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Spacer(),
                      MonsterDisplay(
                        emoji: emojiForStage(
                          monster.currentStage,
                          monster.lineIndex,
                        ),
                        triggerCount: _triggerCount,
                        isFinal: monster.lastWasPrestige,
                      ),
                      const SizedBox(height: 16),
                      StageTracker(
                        stage: monster.currentStage,
                        prestigeCount: monster.prestigeCount,
                        lineIndex: monster.lineIndex,
                      ),
                      const Spacer(),
                      _buildPhaseArea(context),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 4,
              child: Text(
                'v$kAppVersion',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                  fontSize: 10,
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 16,
              right: 16,
              child: Center(child: _buildUpdateBanner(context)),
            ),
          ],
        ),
      ),
    );
  }

  /// A friendly pill prompting a reload once a newer deploy is detected.
  Widget _buildUpdateBanner(BuildContext context) {
    return Consumer<UpdateChecker>(
      builder: (context, checker, _) {
        if (!checker.updateAvailable) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(24),
          elevation: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    '✨ A new version is ready!',
                    style: TextStyle(color: scheme.onPrimaryContainer),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: checker.applyUpdate,
                  child: const Text('Update'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhaseArea(BuildContext context) {
    final theme = Theme.of(context);

    switch (_phase) {
      case _Phase.idle:
        return Column(
          key: const ValueKey<String>('idle'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CheerCharacter(emoji: '📣', message: _cheerMessage),
            const SizedBox(height: 20),
            Text(
              'Are you ready to start your task?',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            _actionButton(
              label: 'START',
              icon: Icons.play_arrow_rounded,
              onPressed: _onStart,
            ),
          ],
        );

      case _Phase.working:
        final remaining = (_minTaskSeconds - _elapsed).clamp(
          0,
          _minTaskSeconds,
        );
        return Column(
          key: const ValueKey<String>('working'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CheerCharacter(
              emoji: _alarmFired ? '⏰' : '💪',
              message: _cheerMessage,
            ),
            const SizedBox(height: 20),
            Text(
              _formatTime(_elapsed),
              style: theme.textTheme.displaySmall?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                fontWeight: FontWeight.bold,
                color: _alarmFired ? Colors.amber.shade700 : null,
              ),
            ),
            Text(
              _alarmFired ? 'Time to wrap up! 🎉' : 'Task in progress',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _alarmFired
                    ? Colors.amber.shade700
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: _alarmFired ? FontWeight.bold : null,
              ),
            ),
            const SizedBox(height: 16),
            _actionButton(
              label: _ready ? "I'M READY!" : 'Ready in ${remaining}s',
              icon: _ready ? Icons.check_circle_rounded : Icons.hourglass_top,
              onPressed: _ready ? _onReady : null,
            ),
          ],
        );

      case _Phase.evolving:
        return Column(
          key: const ValueKey<String>('evolving'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CheerCharacter(emoji: '🎉', message: _cheerMessage),
            const SizedBox(height: 20),
            Text(
                  'Evolving…',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                )
                .animate(onPlay: (c) => c.repeat())
                .shimmer(duration: 1200.ms, color: Colors.amber),
          ],
        );
    }
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 260,
      height: 64,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }

  String _formatTime(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// The name + trimmed value returned by [_ProfileEditorDialog].
class _ProfileEditorResult {
  const _ProfileEditorResult(this.name, this.animal);
  final String name;
  final String animal;
}

/// Add/edit-user dialog. Owns its [TextEditingController] so it is disposed
/// safely with the dialog (avoiding a use-after-dispose during the close
/// animation).
class _ProfileEditorDialog extends StatefulWidget {
  const _ProfileEditorDialog({this.existing});

  final Profile? existing;

  @override
  State<_ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<_ProfileEditorDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _animal = widget.existing?.animal ?? defaultAnimal;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(isEdit ? 'Edit user' : 'New user'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 20),
            const Text('Choose an animal'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final animal in animalIcons)
                  GestureDetector(
                    onTap: () => setState(() => _animal = animal),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: animal == _animal
                            ? scheme.primaryContainer
                            : null,
                        border: Border.all(
                          width: 2,
                          color: animal == _animal
                              ? scheme.primary
                              : Colors.transparent,
                        ),
                      ),
                      child: Text(animal, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _ProfileEditorResult(_controller.text.trim(), _animal),
          ),
          child: Text(isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
