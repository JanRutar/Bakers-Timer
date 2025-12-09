import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:assets_audio_player/assets_audio_player.dart';
import 'package:google_fonts/google_fonts.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait to avoid rotation-related overflow issues on small screens.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ProviderScope(child: BakersTimerApp()));
}

// Models

class TimerStep {
  final String name;
  final int durationSeconds;

  TimerStep({required this.name, required this.durationSeconds});

  TimerStep copyWith({String? name, int? durationSeconds}) {
    return TimerStep(
      name: name ?? this.name,
      durationSeconds: durationSeconds ?? this.durationSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'durationSeconds': durationSeconds,
      };

  static TimerStep fromJson(Map<String, dynamic> j) => TimerStep(
        name: j['name'] as String? ?? 'Step',
        durationSeconds: (j['durationSeconds'] as int?) ?? 0,
      );
}

class TimerSequence {
  final String title;
  final List<TimerStep> steps;
  final String note;

  TimerSequence({required this.title, required this.steps, this.note = ''});

  TimerSequence copyWith(
      {String? title, List<TimerStep>? steps, String? note}) {
    return TimerSequence(
      title: title ?? this.title,
      steps: steps ?? this.steps,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'steps': steps.map((s) => s.toJson()).toList(),
        'note': note,
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

// Editor state for a single sequence
class SequenceEditorNotifier extends StateNotifier<TimerSequence> {
  SequenceEditorNotifier()
      : super(TimerSequence(title: 'New Sequence', steps: []));

  void setSequence(TimerSequence seq) => state = seq;

  void setTitle(String title) => state = state.copyWith(title: title);

  void setNote(String note) => state = state.copyWith(note: note);

  void addStep(TimerStep step) =>
      state = state.copyWith(steps: [...state.steps, step]);

  void updateStep(int index, TimerStep step) {
    final list = List<TimerStep>.from(state.steps);
    if (index < 0 || index >= list.length) return;
    list[index] = step;
    state = state.copyWith(steps: list);
  }

  void removeStep(int index) {
    final list = List<TimerStep>.from(state.steps);
    if (index < 0 || index >= list.length) return;
    list.removeAt(index);
    state = state.copyWith(steps: list);
  }
}

final sequenceEditorProvider =
    StateNotifierProvider<SequenceEditorNotifier, TimerSequence>((ref) {
  return SequenceEditorNotifier();
});

// Persistent storage for saved sequences
const _kKey = 'bakers_sequences_v1';

class SequenceStorageNotifier extends StateNotifier<List<TimerSequence>> {
  SequenceStorageNotifier() : super([]) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kKey) ?? [];
    final list = raw.map((r) {
      try {
        final j = jsonDecode(r) as Map<String, dynamic>;
        return TimerSequence.fromJson(j);
      } catch (_) {
        return TimerSequence(title: 'Sequence', steps: []);
      }
    }).toList();
    state = list;
  }

  Future<void> saveSequence(TimerSequence seq, {int? index}) async {
    final list = List<TimerSequence>.from(state);
    if (index == null) {
      list.add(seq);
    } else if (index >= 0 && index < list.length) {
      list[index] = seq;
    } else {
      list.add(seq);
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

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = state.map((s) => jsonEncode(s.toJson())).toList();
    await prefs.setStringList(_kKey, raw);
  }
}

final sequenceStorageProvider =
    StateNotifierProvider<SequenceStorageNotifier, List<TimerSequence>>((ref) {
  return SequenceStorageNotifier();
});

// Runner State + Notifier
class RunnerState {
  final TimerSequence? sequence;
  final int currentIndex;
  final int remainingSeconds;
  final bool isRunning;
  final bool isPaused;
  final bool isAlarmed;
  final bool isRinging;

  RunnerState({
    this.sequence,
    this.currentIndex = 0,
    this.remainingSeconds = 0,
    this.isRunning = false,
    this.isPaused = false,
    this.isAlarmed = false,
    this.isRinging = false,
  });

  RunnerState copyWith({
    TimerSequence? sequence,
    int? currentIndex,
    int? remainingSeconds,
    bool? isRunning,
    bool? isPaused,
    bool? isAlarmed,
    bool? isRinging,
  }) {
    return RunnerState(
      sequence: sequence ?? this.sequence,
      currentIndex: currentIndex ?? this.currentIndex,
      remainingSeconds: remainingSeconds ?? this.remainingSeconds,
      isRunning: isRunning ?? this.isRunning,
      isPaused: isPaused ?? this.isPaused,
      isAlarmed: isAlarmed ?? this.isAlarmed,
      isRinging: isRinging ?? this.isRinging,
    );
  }
}

class RunnerNotifier extends StateNotifier<RunnerState> {
  RunnerNotifier() : super(RunnerState());

  Timer? _ticker;
  AssetsAudioPlayer? _assetsAudioPlayer;

  void startSequence(TimerSequence seq) {
    _cancelTicker();
    if (seq.steps.isEmpty) return;
    state = RunnerState(
        sequence: seq,
        currentIndex: 0,
        remainingSeconds: seq.steps[0].durationSeconds,
        isRunning: false,
        isPaused: false,
        isAlarmed: false);
    // Immediately start the first step
    startCurrentStep();
  }

  void startCurrentStep() {
    if (state.sequence == null) return;
    final steps = state.sequence!.steps;
    if (state.currentIndex < 0 || state.currentIndex >= steps.length) return;
    final seconds = steps[state.currentIndex].durationSeconds;
    state = state.copyWith(
        remainingSeconds: seconds,
        isRunning: true,
        isPaused: false,
        isAlarmed: false);
    _startTicker();
  }

  void pauseOrResume() {
    if (state.isRunning && !state.isPaused) {
      // pause
      _cancelTicker();
      state = state.copyWith(isPaused: true, isRunning: false);
    } else if (state.isPaused) {
      // resume
      state = state.copyWith(isPaused: false, isRunning: true);
      _startTicker();
    }
  }

  void startNextStep() {
    if (state.sequence == null) return;
    final nextIndex = state.currentIndex + 1;
    if (nextIndex >= state.sequence!.steps.length) {
      // sequence complete
      state = state.copyWith(
          isRunning: false,
          isPaused: false,
          isAlarmed: false,
          isRinging: false);
      _cancelTicker();
      return;
    }
    // only allow starting the next step after user has stopped the alarm
    if (state.isAlarmed && state.isRinging) return;
    state = state.copyWith(
        currentIndex: nextIndex, isAlarmed: false, isRinging: false);
    startCurrentStep();
  }

  void stop() {
    _cancelTicker();
    try {
      _assetsAudioPlayer?.stop();
      _assetsAudioPlayer?.dispose();
      _assetsAudioPlayer = null;
    } catch (_) {}
    state = RunnerState();
  }

  void _startTicker() {
    _cancelTicker();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final rem = state.remainingSeconds - 1;
      if (rem <= 0) {
        _cancelTicker();
        state = state.copyWith(
            remainingSeconds: 0,
            isRunning: false,
            isPaused: false,
            isAlarmed: true,
            isRinging: true);
        _playAlarm();
      } else {
        state = state.copyWith(remainingSeconds: rem);
      }
    });
  }

  void _playAlarm() {
    _ensureAlarmFileAndPlay();
  }

  Future<void> _ensureAlarmFileAndPlay() async {
    try {
      _assetsAudioPlayer ??= AssetsAudioPlayer();
      await _assetsAudioPlayer!.open(
        Audio('assets/alarm.wav'),
        autoStart: true,
        loopMode: LoopMode.single,
        showNotification: false,
      );
    } catch (_) {
      // ignore
    }
  }

  // Generate a mono 16-bit PCM WAV with a sine wave
  Uint8List _generateSineWavBytes(
      {int freq = 880, int durationMs = 500, int sampleRate = 22050}) {
    final samples = (sampleRate * durationMs / 1000).round();
    const bytesPerSample = 2; // 16-bit
    final dataLen = samples * bytesPerSample;
    final byteRate = sampleRate * bytesPerSample;
    final header = BytesBuilder();

    // RIFF header
    header.add(ascii.encode('RIFF'));
    header.add(_intToBytes(36 + dataLen, 4)); // file size - 8
    header.add(ascii.encode('WAVE'));

    // fmt chunk
    header.add(ascii.encode('fmt '));
    header.add(_intToBytes(16, 4)); // subchunk1 size
    header.add(_intToBytes(1, 2)); // PCM
    header.add(_intToBytes(1, 2)); // channels
    header.add(_intToBytes(sampleRate, 4));
    header.add(_intToBytes(byteRate, 4));
    header.add(_intToBytes(bytesPerSample, 2)); // block align
    header.add(_intToBytes(16, 2)); // bits per sample

    // data chunk header
    header.add(ascii.encode('data'));
    header.add(_intToBytes(dataLen, 4));

    // samples
    final data = BytesBuilder();
    for (int i = 0; i < samples; i++) {
      final t = i / sampleRate;
      final v = (32767 * 0.6 * math.sin(2 * math.pi * freq * t)).round();
      final low = v & 0xFF;
      final high = (v >> 8) & 0xFF;
      data.addByte(low);
      data.addByte(high);
    }

    final out = BytesBuilder();
    out.add(header.toBytes());
    out.add(data.toBytes());
    return out.toBytes();
  }

  List<int> _intToBytes(int value, int byteCount) {
    final b = <int>[];
    for (int i = 0; i < byteCount; i++) {
      b.add(value & 0xFF);
      value = value >> 8;
    }
    return b;
  }

  void stopAlarm() {
    try {
    } catch (_) {}
    state = state.copyWith(isRinging: false);
  }

  void _cancelTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _cancelTicker();
    super.dispose();
  }
}

final runnerProvider =
    StateNotifierProvider<RunnerNotifier, RunnerState>((ref) {
  return RunnerNotifier();
});

// App
class BakersTimerApp extends ConsumerWidget {
  const BakersTimerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Bakers Timer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFFC857)),
        useMaterial3: true,
        textTheme: GoogleFonts.montserratTextTheme(),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFB8860B)),
      ),
      home: const MainMenuScreen(),
    );
  }
}

// Main menu screen showing saved sequences (animated header)
class MainMenuScreen extends ConsumerStatefulWidget {
  const MainMenuScreen({super.key});

  @override
  ConsumerState<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends ConsumerState<MainMenuScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(sequenceStorageProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bakers Timer'),
        centerTitle: true,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              // Decorative header with pulsing emoji
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                      colors: [Color(0xFFFFF3D1), Color(0xFFFFD27D)]),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 88,
                      height: 88,
                      child: AnimatedBuilder(
                        animation: _animController,
                        builder: (context, child) => CustomPaint(
                          painter:
                              _DoughPainter(progress: _animController.value),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Welcome to Bakers Timer',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 6),
                          Text('Pick a saved sequence or create a new one',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    )
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: saved.isEmpty
                    ? Center(
                        child: Text('No saved sequences yet.',
                            style: Theme.of(context).textTheme.bodyLarge))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: saved.length,
                        itemBuilder: (context, i) {
                          final s = saved[i];
                          return Card(
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  isThreeLine: true,
                                  title: Row(
                                    children: [
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: const Icon(Icons.book, size: 20),
                                        onPressed: () {
                                          ref.read(sequenceEditorProvider.notifier).setSequence(s);
                                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorScreen(savedIndex: i)));
                                        },
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(child: Text(s.title)),
                                    ],
                                  ),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('${s.steps.length} steps'),
                                      if ((s.note).isNotEmpty)
                                        Text(
                                          s.note,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.bodySmall,
                                        ),
                                    ],
                                  ),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                    IconButton(
                                      icon: const Icon(Icons.play_arrow),
                                      onPressed: () {
                                        ref
                                            .read(runnerProvider.notifier)
                                            .startSequence(s);
                                        Navigator.of(context).push(
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    const RunScreen()));
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit),
                                      onPressed: () {
                                        // load into editor and navigate
                                        ref
                                            .read(
                                                sequenceEditorProvider.notifier)
                                            .setSequence(s);
                                        Navigator.of(context).push(
                                            MaterialPageRoute(
                                                builder: (_) => EditorScreen(
                                                    savedIndex: i)));
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete),
                                      onPressed: () async {
                                        await ref
                                            .read(sequenceStorageProvider
                                                .notifier)
                                            .deleteSequence(i);
                                      },
                                    ),
                                  ]),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ), // Column
        ), // ConstrainedBox
      ), // Center
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // start with a fresh sequence
          ref
              .read(sequenceEditorProvider.notifier)
              .setSequence(TimerSequence(title: 'New Sequence', steps: []));
          Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const EditorScreen()));
        },
        icon: const Icon(Icons.add),
        label: const Text('New Sequence'),
      ),
    );
  }
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late final TextEditingController _titleController;
  late final FocusNode _titleFocusNode;
  bool _clearedTitleOnFocus = false;

  @override
  void initState() {
    super.initState();
    final seq = ref.read(sequenceEditorProvider);
    _titleController = TextEditingController(text: seq.title);
    _titleFocusNode = FocusNode();

    _titleFocusNode.addListener(() {
      if (_titleFocusNode.hasFocus && !_clearedTitleOnFocus) {
        if (_titleController.text.isEmpty ||
            _titleController.text == 'New Sequence') {
          _titleController.clear();
        }
        _clearedTitleOnFocus = true;
      }
    });

    // Do not call ref.listen in initState (not allowed). We'll sync
    // the controller inside build() when appropriate.
  }

  @override
  void dispose() {
    _titleController.dispose();
    _titleFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seq = ref.watch(sequenceEditorProvider);
    // Keep controller in sync when provider changes, but avoid overwriting
    // while the user is editing (has focus).
    if (!_titleFocusNode.hasFocus && _titleController.text != seq.title) {
      _titleController.text = seq.title;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bakers Timer'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Run Sequence',
            onPressed: seq.steps.isEmpty
                ? null
                : () {
                    ref.read(runnerProvider.notifier).startSequence(seq);
                    Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const RunScreen()));
                  },
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Sequence Title'),
              controller: _titleController,
              focusNode: _titleFocusNode,
              onChanged: (v) =>
                  ref.read(sequenceEditorProvider.notifier).setTitle(v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: seq.steps.isEmpty
                  ? Center(
                      child: Text('No steps yet — add one with the button.',
                          style: Theme.of(context).textTheme.bodyLarge))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 120),
                      itemCount: seq.steps.length,
                      itemBuilder: (context, i) {
                        final step = seq.steps[i];
                        return Card(
                          child: ListTile(
                            title: Text(step.name),
                            subtitle: Text(
                                _formatDurationSeconds(step.durationSeconds)),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _showAddEditDialog(
                                    context, ref,
                                    editIndex: i, initial: step),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () => ref
                                    .read(sequenceEditorProvider.notifier)
                                    .removeStep(i),
                              ),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add Step'),
      ),
    );
  }

  Future<void> _showAddEditDialog(BuildContext context, WidgetRef ref,
      {int? editIndex, TimerStep? initial}) async {
    final nameCtrl = TextEditingController(text: initial?.name ?? '');
    final minutesCtrl = TextEditingController(
        text:
            initial != null ? (initial.durationSeconds ~/ 60).toString() : '5');

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(editIndex == null ? 'Add Step' : 'Edit Step'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Step Name')),
            TextField(
              controller: minutesCtrl,
              decoration:
                  const InputDecoration(labelText: 'Duration (minutes)'),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final mins = int.tryParse(minutesCtrl.text.trim()) ?? 0;
              final seconds = (mins.clamp(0, 9999)) * 60;
              if (name.isEmpty || seconds <= 0) return;
              final step = TimerStep(name: name, durationSeconds: seconds);
              if (editIndex == null) {
                ref.read(sequenceEditorProvider.notifier).addStep(step);
              } else {
                ref
                    .read(sequenceEditorProvider.notifier)
                    .updateStep(editIndex, step);
              }
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          )
        ],
      ),
    );
  }

  String _formatDurationSeconds(int s) {
    final d = Duration(seconds: s);
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

// Editor screen extracted from previous HomeScreen
class EditorScreen extends ConsumerStatefulWidget {
  final int? savedIndex;
  const EditorScreen({super.key, this.savedIndex});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  late final TextEditingController _titleController;
  late final FocusNode _titleFocusNode;
  late final TextEditingController _notesController;
  late final FocusNode _notesFocusNode;
  bool _clearedTitleOnFocus = false;
  bool _clearedNotesOnFocus = false;

  @override
  void initState() {
    super.initState();
    final seq = ref.read(sequenceEditorProvider);
    _titleController = TextEditingController(text: seq.title);
    _titleFocusNode = FocusNode();
    _notesController = TextEditingController(text: seq.note);
    _notesFocusNode = FocusNode();

    _titleFocusNode.addListener(() {
      if (_titleFocusNode.hasFocus && !_clearedTitleOnFocus) {
        if (_titleController.text.isEmpty ||
            _titleController.text == 'New Sequence') {
          _titleController.clear();
        }
        _clearedTitleOnFocus = true;
      }
    });
    _notesFocusNode.addListener(() {
      if (_notesFocusNode.hasFocus && !_clearedNotesOnFocus) {
        if (_notesController.text.isEmpty || _notesController.text == 'Add notes...') {
          _notesController.clear();
        }
        _clearedNotesOnFocus = true;
      }
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _titleFocusNode.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seq = ref.watch(sequenceEditorProvider);
    if (!_titleFocusNode.hasFocus && _titleController.text != seq.title) {
      _titleController.text = seq.title;
    }
    if (!_notesFocusNode.hasFocus && _notesController.text != seq.note) {
      _notesController.text = seq.note;
    }

    return Scaffold(
      appBar: AppBar(
        title:
            Text(widget.savedIndex == null ? 'New Sequence' : 'Edit Sequence'),
        actions: [
          TextButton(
            onPressed: seq.steps.isEmpty
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final nav = Navigator.of(context);
                    await ref
                        .read(sequenceStorageProvider.notifier)
                        .saveSequence(seq, index: widget.savedIndex);
                    messenger
                        .showSnackBar(const SnackBar(content: Text('Saved')));
                    nav.pop();
                  },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Sequence Title'),
              controller: _titleController,
              focusNode: _titleFocusNode,
              onChanged: (v) =>
                  ref.read(sequenceEditorProvider.notifier).setTitle(v),
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'e.g. preheat temp, rack position'),
              controller: _notesController,
              focusNode: _notesFocusNode,
              maxLines: 3,
              onChanged: (v) =>
                  ref.read(sequenceEditorProvider.notifier).setNote(v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: seq.steps.isEmpty
                  ? Center(
                      child: Text('No steps yet — add one with the button.',
                          style: Theme.of(context).textTheme.bodyLarge))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 120),
                      itemCount: seq.steps.length,
                      itemBuilder: (context, i) {
                        final step = seq.steps[i];
                        return Card(
                          child: ListTile(
                            title: Text(step.name),
                            subtitle: Text(
                                _formatDurationSeconds(step.durationSeconds)),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _showAddEditDialog(
                                    context, ref,
                                    editIndex: i, initial: step),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () => ref
                                    .read(sequenceEditorProvider.notifier)
                                    .removeStep(i),
                              ),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add Step'),
      ),
    );
  }

  Future<void> _showAddEditDialog(BuildContext context, WidgetRef ref,
      {int? editIndex, TimerStep? initial}) async {
    final nameCtrl = TextEditingController(text: initial?.name ?? '');
    final minutesCtrl = TextEditingController(
        text:
            initial != null ? (initial.durationSeconds ~/ 60).toString() : '5');

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(editIndex == null ? 'Add Step' : 'Edit Step'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Step Name')),
            TextField(
                controller: minutesCtrl,
                decoration:
                    const InputDecoration(labelText: 'Duration (minutes)'),
                keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final mins = int.tryParse(minutesCtrl.text.trim()) ?? 0;
              final seconds = (mins.clamp(0, 9999)) * 60;
              if (name.isEmpty || seconds <= 0) return;
              final step = TimerStep(name: name, durationSeconds: seconds);
              if (editIndex == null) {
                ref.read(sequenceEditorProvider.notifier).addStep(step);
              } else {
                ref
                    .read(sequenceEditorProvider.notifier)
                    .updateStep(editIndex, step);
              }
              Navigator.of(context).pop();
            },
            child: const Text('Save'),
          )
        ],
      ),
    );
  }

  String _formatDurationSeconds(int s) {
    final d = Duration(seconds: s);
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

class RunScreen extends ConsumerWidget {
  const RunScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runner = ref.watch(runnerProvider);
    final notifier = ref.read(runnerProvider.notifier);

    final seq = runner.sequence;
    if (seq == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Run')),
        body: const Center(child: Text('No sequence loaded.')),
      );
    }

    final currentIndex = runner.currentIndex;
    final currentStep = seq.steps[currentIndex];
    final total = currentStep.durationSeconds;
    final remaining = runner.remainingSeconds;
    final progress = total > 0 ? (remaining / total) : 0.0;

    final postFrameMessenger = ScaffoldMessenger.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (runner.isAlarmed) {
        HapticFeedback.heavyImpact();
        postFrameMessenger.showSnackBar(SnackBar(
            content: Text("Time's up: ${currentStep.name}"),
            duration: const Duration(seconds: 2)));
      }
    });

    final nextStepName = (currentIndex + 1 < seq.steps.length)
        ? seq.steps[currentIndex + 1].name
        : '—';

    return Scaffold(
      appBar: AppBar(
        title: Text(seq.title),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            notifier.stop();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(18.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(currentStep.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontSize: 28)),
                const SizedBox(height: 12),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pinned-width timer text above the wheel to avoid shifting
                    SizedBox(
                      width: 180,
                      child: Center(
                        child: Text(
                          _formatMmSs(remaining),
                          style: GoogleFonts.robotoMono(
                            textStyle: Theme.of(context)
                                .textTheme
                                .displaySmall
                                ?.copyWith(
                                    fontSize: 48, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 260,
                      height: 260,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 14,
                        backgroundColor: Colors.brown.shade100,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('${(progress * 100).toStringAsFixed(0)}%',
                        style: Theme.of(context).textTheme.bodyLarge),
                  ],
                ),
                const SizedBox(height: 18),
                Text('Next: $nextStepName',
                    style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 24),
                // Controls: use Wrap so buttons won't overflow on narrow screens.
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      icon: Icon(
                          runner.isRunning ? Icons.pause : Icons.play_arrow),
                      label: Text(runner.isRunning
                          ? 'Pause'
                          : (runner.isPaused ? 'Resume' : 'Pause/Resume')),
                      onPressed: runner.isAlarmed || runner.sequence == null
                          ? null
                          : () => notifier.pauseOrResume(),
                    ),

                    if (runner.isAlarmed)
                      ElevatedButton.icon(
                        icon: const Icon(Icons.skip_next),
                        label: const Text('Start Next Step'),
                        onPressed: (runner.isRinging ||
                                (runner.currentIndex + 1 >= seq.steps.length))
                            ? null
                            : () => notifier.startNextStep(),
                      ),

                    if (runner.isAlarmed && runner.isRinging)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red),
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop Alarm'),
                        onPressed: () => notifier.stopAlarm(),
                      ),

                    if (runner.isAlarmed &&
                        runner.currentIndex + 1 >= seq.steps.length)
                      ElevatedButton.icon(
                        icon: const Icon(Icons.check),
                        label: const Text('Complete'),
                        onPressed: () {
                          notifier.stop();
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Sequence complete')));
                          Navigator.of(context).pop();
                        },
                      ),

                    // Small hint when alarm is still ringing
                    if (runner.isAlarmed && runner.isRinging)
                      Padding(
                        padding: const EdgeInsets.only(top: 6.0),
                        child: Text(
                            'Stop the alarm to enable "Start Next Step"',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.red)),
                      ),
                  ],
                ), // Wrap
              ],
            ), // Column
          ), // Padding
        ), // ConstrainedBox
      ), // Center
    );
  }

  String _formatMmSs(int seconds) {
    final d = Duration(seconds: seconds);
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

// Animated dough painter used in main menu header
class _DoughPainter extends CustomPainter {
  final double progress; // 0..1

  _DoughPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..isAntiAlias = true;
    final center = Offset(size.width / 2, size.height / 2);

    // Background circle (plate)
    final platePaint = Paint()
      ..color = const Color(0xFFFFF7E6)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
        center, math.min(size.width, size.height) / 2, platePaint);

    // Dough body: rising effect using progress
    final doughRadius = math.min(size.width, size.height) * 0.36;
    final rise = (progress * 8) - 4; // -4..4 vertical wobble
    final doughCenter = center.translate(0, -rise);

    final doughRect = Rect.fromCircle(center: doughCenter, radius: doughRadius);
    final doughRRect =
        RRect.fromRectAndRadius(doughRect, Radius.circular(doughRadius * 0.6));

    const doughGradient =
        RadialGradient(colors: [Color(0xFFFFE3B3), Color(0xFFFFC857)]);
    paint.shader = doughGradient.createShader(doughRect);
    canvas.drawRRect(doughRRect, paint);

    // Small bubbled highlights
    final bubblePaint = Paint()..color = Colors.white.withOpacity(0.35);
    final rnd = math.Random(1234);
    for (int i = 0; i < 4; i++) {
      final angle = (i / 4) * math.pi * 2 + progress * math.pi * 2;
      final r = doughRadius * (0.3 + (i * 0.08));
      final pos = Offset(doughCenter.dx + math.cos(angle) * r,
          doughCenter.dy + math.sin(angle) * r * 0.6);
      canvas.drawCircle(pos,
          doughRadius * 0.08 * (0.8 + rnd.nextDouble() * 0.4), bubblePaint);
    }

    // Outline
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.brown.shade700.withOpacity(0.6);
    canvas.drawRRect(doughRRect, outline);
  }

  @override
  bool shouldRepaint(covariant _DoughPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
