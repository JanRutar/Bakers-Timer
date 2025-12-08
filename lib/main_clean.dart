import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

const _ringtoneChannel = MethodChannel('bakers_timers/ringtone');

Future<String?> _pickPlatformRingtone({String? existing}) async {
  try {
    return await _ringtoneChannel
        .invokeMethod<String>('pickRingtone', {'existingUri': existing});
  } on PlatformException {
    return null;
  }
}

Future<String?> _copyContentUriToCache(String uri) async {
  try {
    return await _ringtoneChannel
        .invokeMethod<String>('copyRingtoneToCache', {'uri': uri});
  } catch (_) {
    return null;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ProviderScope(child: BakersTimerApp()));
}

// Models
class TimerStep {
  final String name;
  final int durationSeconds;
  TimerStep({required this.name, required this.durationSeconds});
  Map<String, dynamic> toJson() =>
      {'name': name, 'durationSeconds': durationSeconds};
  static TimerStep fromJson(Map<String, dynamic> j) => TimerStep(
      name: j['name'] as String? ?? 'Step',
      durationSeconds: (j['durationSeconds'] as int?) ?? 0);
}

class TimerSequence {
  final String title;
  final List<TimerStep> steps;
  final String note;
  TimerSequence({required this.title, required this.steps, this.note = ''});
  TimerSequence copyWith(
          {String? title, List<TimerStep>? steps, String? note}) =>
      TimerSequence(
          title: title ?? this.title,
          steps: steps ?? this.steps,
          note: note ?? this.note);
  Map<String, dynamic> toJson() => {
        'title': title,
        'steps': steps.map((s) => s.toJson()).toList(),
        'note': note
      };
  static TimerSequence fromJson(Map<String, dynamic> j) => TimerSequence(
        title: j['title'] as String? ?? 'Sequence',
        steps: (j['steps'] as List<dynamic>?)
                ?.map((e) => TimerStep.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            [],
        note: j['note'] as String? ?? '',
      );
}

// Providers (minimal)
final sequenceEditorProvider =
    StateNotifierProvider<SequenceEditorNotifier, TimerSequence>(
        (ref) => SequenceEditorNotifier());
final sequenceStorageProvider =
    StateNotifierProvider<SequenceStorageNotifier, List<TimerSequence>>(
        (ref) => SequenceStorageNotifier());
final settingsProvider = StateNotifierProvider<SettingsNotifier, String?>(
    (ref) => SettingsNotifier());
final runnerProvider = StateNotifierProvider<RunnerNotifier, RunnerState>(
    (ref) => RunnerNotifier(ref));

class SequenceEditorNotifier extends StateNotifier<TimerSequence> {
  SequenceEditorNotifier()
      : super(TimerSequence(title: 'New Sequence', steps: []));
  void setSequence(TimerSequence s) => state = s;
  void setTitle(String t) => state = state.copyWith(title: t);
  void setNote(String n) => state = state.copyWith(note: n);
  void addStep(TimerStep st) =>
      state = state.copyWith(steps: [...state.steps, st]);
  void updateStep(int idx, TimerStep st) {
    final list = List<TimerStep>.from(state.steps);
    if (idx < 0 || idx >= list.length) return;
    list[idx] = st;
    state = state.copyWith(steps: list);
  }

  void removeStep(int idx) {
    final list = List<TimerStep>.from(state.steps);
    if (idx < 0 || idx >= list.length) return;
    list.removeAt(idx);
    state = state.copyWith(steps: list);
  }
}

class SequenceStorageNotifier extends StateNotifier<List<TimerSequence>> {
  SequenceStorageNotifier() : super([]) {
    _load();
  }
  static const _kKey = 'saved_sequences_v1';
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kKey);
    if (raw == null) return;
    try {
      final data = json.decode(raw) as List<dynamic>;
      state = data
          .map((e) => TimerSequence.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {}
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kKey, json.encode(state.map((s) => s.toJson()).toList()));
  }

  Future<void> saveSequence(TimerSequence seq, {int? index}) async {
    final list = List<TimerSequence>.from(state);
    if (index == null)
      list.add(seq);
    else {
      if (index < 0 || index >= list.length) return;
      list[index] = seq;
    }
    state = list;
    await _persist();
  }

  Future<void> deleteSequence(int index) async {
    final list = List<TimerSequence>.from(state);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    state = list;
    await _persist();
  }
}

class SettingsNotifier extends StateNotifier<String?> {
  SettingsNotifier() : super(null) {
    _load();
  }
  static const _kAlarmKey = 'selected_alarm_uri';
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_kAlarmKey);
  }

  Future<void> setAlarmUri(String? uri) async {
    final prefs = await SharedPreferences.getInstance();
    if (uri == null)
      await prefs.remove(_kAlarmKey);
    else
      await prefs.setString(_kAlarmKey, uri);
    state = uri;
  }
}

class RunnerState {
  final TimerSequence? sequence;
  final int currentIndex;
  final int remainingSeconds;
  final bool isRinging;
  RunnerState(
      {this.sequence,
      this.currentIndex = 0,
      this.remainingSeconds = 0,
      this.isRinging = false});
  RunnerState copyWith(
          {TimerSequence? sequence,
          int? currentIndex,
          int? remainingSeconds,
          bool? isRinging}) =>
      RunnerState(
          sequence: sequence ?? this.sequence,
          currentIndex: currentIndex ?? this.currentIndex,
          remainingSeconds: remainingSeconds ?? this.remainingSeconds,
          isRinging: isRinging ?? this.isRinging);
}

class RunnerNotifier extends StateNotifier<RunnerState> {
  final Ref ref;
  RunnerNotifier(this.ref) : super(RunnerState());
  Timer? _ticker;
  AudioPlayer? _player;
  void startSequence(TimerSequence seq) {
    stop();
    state = RunnerState(
        sequence: seq,
        currentIndex: 0,
        remainingSeconds:
            seq.steps.isNotEmpty ? seq.steps.first.durationSeconds : 0);
    _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = state;
      if (s.sequence == null) return;
      if (s.remainingSeconds <= 0) return;
      final next = s.remainingSeconds - 1;
      state = s.copyWith(remainingSeconds: next);
      if (next == 0) _onStepComplete();
    });
  }

  void _onStepComplete() async {
    state = state.copyWith(isRinging: true);
    await _playAlarm();
  }

  Future<void> startNext() async {
    final s = state;
    if (s.sequence == null) return;
    final nextIndex = s.currentIndex + 1;
    if (nextIndex >= s.sequence!.steps.length) {
      stop();
      return;
    }
    state = s.copyWith(
        currentIndex: nextIndex,
        remainingSeconds: s.sequence!.steps[nextIndex].durationSeconds,
        isRinging: false);
    _player?.stop();
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
    _player?.stop();
    _player = null;
    state = RunnerState();
  }

  void stopAlarm() {
    _player?.stop();
    state = state.copyWith(isRinging: false);
  }

  Future<void> _playAlarm() async {
    _player ??= AudioPlayer();
    final selected = ref.read(settingsProvider);
    if (selected != null) {
      try {
        String? pathToPlay;
        if (selected.startsWith('content://'))
          pathToPlay = await _copyContentUriToCache(selected);
        else if (selected.startsWith('file://'))
          pathToPlay = Uri.parse(selected).toFilePath();
        else
          pathToPlay = selected;
        if (pathToPlay != null) {
          if (pathToPlay.startsWith('http'))
            await _player!.play(UrlSource(pathToPlay));
          else
            await _player!.play(DeviceFileSource(pathToPlay));
          return;
        }
      } catch (_) {}
    }
    try {
      final bytes =
          (await rootBundle.load('assets/alarm.wav')).buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/bakers_alarm.wav');
      await f.writeAsBytes(bytes, flush: true);
      await _player!.play(DeviceFileSource(f.path));
      return;
    } catch (_) {}
    try {
      final wav = _generateSineWavBytes(freq: 880, durationMs: 3000);
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/bakers_generated.wav');
      await f.writeAsBytes(wav, flush: true);
      await _player!.play(DeviceFileSource(f.path));
    } catch (_) {}
  }

  List<int> _intToBytes(int v, int bytes) {
    final out = <int>[];
    for (var i = 0; i < bytes; i++) out.add((v >> (8 * i)) & 0xFF);
    return out;
  }

  List<int> _generateSineWavBytes(
      {int freq = 880, int durationMs = 1000, int sampleRate = 22050}) {
    final samples = (sampleRate * durationMs / 1000).round();
    final bytesPerSample = 2;
    final data = <int>[];
    for (var i = 0; i < samples; i++) {
      final t = i / sampleRate;
      final s = (math.sin(2 * math.pi * freq * t) * 0.6 * 32767).round();
      data.addAll(_intToBytes(s, bytesPerSample));
    }
    final header = <int>[];
    header.addAll(utf8.encode('RIFF'));
    header.addAll(_intToBytes(36 + data.length, 4));
    header.addAll(utf8.encode('WAVE'));
    header.addAll(utf8.encode('fmt '));
    header.addAll(_intToBytes(16, 4));
    header.addAll(_intToBytes(1, 2));
    header.addAll(_intToBytes(1, 2));
    header.addAll(_intToBytes(sampleRate, 4));
    header.addAll(_intToBytes(sampleRate * bytesPerSample, 4));
    header.addAll(_intToBytes(bytesPerSample, 2));
    header.addAll(_intToBytes(16, 2));
    header.addAll(utf8.encode('data'));
    header.addAll(_intToBytes(data.length, 4));
    return [...header, ...data];
  }
}

// UI
class BakersTimerApp extends ConsumerWidget {
  const BakersTimerApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
        title: 'Bakers Timer',
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFFFFC857),
            textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme)),
        home: const MainMenuScreen());
  }
}

extension AppLayoutScale on BuildContext {
  double get layoutScale {
    final w = MediaQuery.of(this).size.width;
    return (w / 720.0).clamp(0.7, 1.3);
  }
}

class MainMenuScreen extends ConsumerStatefulWidget {
  const MainMenuScreen({super.key});
  @override
  ConsumerState<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends ConsumerState<MainMenuScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sequences = ref.watch(sequenceStorageProvider);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bakers Timer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.music_note),
            tooltip: 'Choose alarm',
            onPressed: () async {
              final picked = await _pickPlatformRingtone(existing: settings);
              if (picked != null) {
                await ref.read(settingsProvider.notifier).setAlarmUri(picked);
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Alarm selected')));
              }
            },
          )
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              SizedBox(
                height: 160 * context.layoutScale,
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (ctx, ch) => CustomPaint(
                    painter: _DoughPainter(progress: _anim.value),
                    child: Center(
                        child: Text('Bakers Timer',
                            style: Theme.of(context).textTheme.headlineSmall)),
                  ),
                ),
              ),
              Expanded(
                child: sequences.isEmpty
                    ? const Center(child: Text('No saved sequences'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: sequences.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, i) {
                          final s = sequences[i];
                          return ListTile(
                            leading: IconButton(
                                icon: const Icon(Icons.note),
                                onPressed: () async {
                                  final newNote = await showDialog<String?>(
                                      context: context,
                                      builder: (_) {
                                        final ctrl =
                                            TextEditingController(text: s.note);
                                        return AlertDialog(
                                            title: const Text('Edit note'),
                                            content: TextField(
                                                controller: ctrl, maxLines: 4),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(context),
                                                  child: const Text('Cancel')),
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(
                                                          context, ctrl.text),
                                                  child: const Text('Save'))
                                            ]);
                                      });
                                  if (newNote != null) {
                                    final updated = s.copyWith(note: newNote);
                                    await ref
                                        .read(sequenceStorageProvider.notifier)
                                        .saveSequence(updated, index: i);
                                  }
                                }),
                            title: Text(s.title,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: s.steps.isNotEmpty
                                ? Text('${s.steps.length} steps')
                                : null,
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                  icon: const Icon(Icons.play_arrow),
                                  onPressed: () => ref
                                      .read(runnerProvider.notifier)
                                      .startSequence(s)),
                              IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () => ref
                                      .read(sequenceStorageProvider.notifier)
                                      .deleteSequence(i)),
                            ]),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () async {
          // quick-add a sample sequence for testing
          final sample = TimerSequence(
              title: 'Test Bake',
              steps: [
                TimerStep(name: 'Proof', durationSeconds: 5),
                TimerStep(name: 'Bake', durationSeconds: 8)
              ],
              note: 'Sample');
          await ref.read(sequenceStorageProvider.notifier).saveSequence(sample);
        },
      ),
    );
  }
}

class _DoughPainter extends CustomPainter {
  final double progress;
  _DoughPainter({required this.progress});
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFFFFC857);
    final r = size.width * 0.28;
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawCircle(Offset(cx, cy - (progress - 0.5) * 6), r, p);
  }

  @override
  bool shouldRepaint(covariant _DoughPainter old) => old.progress != progress;
}
