import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    show YoutubeExplode, Video, StreamContainer, AudioOnlyStreamInfo;

enum JobState { queued, downloading, converting, done, failed, canceled }

class _Canceled implements Exception {}

class Job {
  Job(this.video, this.kbps);
  final Video video;
  final int kbps;
  JobState state = JobState.queued;
  double progress = 0;
  String note = '';
  bool cancelRequested = false;
  int attempts = 0;
  int? sessionId;
  bool get active =>
      state == JobState.queued ||
      state == JobState.downloading ||
      state == JobState.converting;
}

String errText(Object e) {
  final s = e.toString();
  if (e is TimeoutException ||
      s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('host lookup')) {
    return 'Koneksi terputus atau lambat. Coba lagi.';
  }
  return s.replaceAll('Exception: ', '').split('\n').first;
}

class Ctl extends ChangeNotifier {
  final yt = YoutubeExplode();
  final jobs = <Job>[];
  bool _running = false, _asked = false;
  SharedPreferences? _p;
  int kbps = 128, nameFmt = 1;
  bool addKbps = true, ascii = true;

  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      _p = p;
      kbps = p.getInt('kbps') ?? 128;
      nameFmt = p.getInt('nameFmt') ?? 1;
      addKbps = p.getBool('addKbps') ?? true;
      ascii = p.getBool('ascii') ?? true;
    } catch (_) {}
    notifyListeners();
  }

  void saveSettings() {
    final p = _p;
    if (p != null) {
      p.setInt('kbps', kbps);
      p.setInt('nameFmt', nameFmt);
      p.setBool('addKbps', addKbps);
      p.setBool('ascii', ascii);
    }
    notifyListeners();
  }

  // ---------- nama file ----------
  String _clean(String s) {
    var t = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ');
    if (ascii) t = t.replaceAll(RegExp(r'[^\x20-\x7E]'), '');
    return t
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[\s.\-]+|[\s.\-]+$'), '');
  }

  String buildName(String title, String author, int k) {
    final t = _clean(title);
    final a = _clean(author.replaceAll(RegExp(r' - Topic$'), ''));
    var n = (nameFmt == 0 || a.isEmpty || t.isEmpty)
        ? (t.isEmpty ? a : t)
        : (nameFmt == 1 ? '$a - $t' : '$t - $a');
    if (n.length > 70) n = _clean(n.substring(0, 70));
    if (n.isEmpty) n = 'lagu';
    return '$n${addKbps ? '_${k}k' : ''}.mp3';
  }

  String _unique(String dir, String name) {
    final base = name.substring(0, name.length - 4);
    var p = '$dir/$name';
    for (var i = 2; File(p).existsSync() && i < 1000; i++) {
      p = '$dir/$base ($i).mp3';
    }
    return p;
  }

  Future<List<Directory>> _outDirs() async {
    final r = <Directory>[];
    try {
      final d = Directory('/storage/emulated/0/Music/YTMP3');
      await d.create(recursive: true);
      r.add(d);
    } catch (_) {}
    try {
      final base = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}/YTMP3');
      await d.create(recursive: true);
      r.add(d);
    } catch (_) {}
    return r;
  }

  Future<void> _del(String p) async {
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ---------- stream ----------
  Future<AudioOnlyStreamInfo> pick(Video v) async {
    final m = await yt.videos.streamsClient
        .getManifest(v.id)
        .timeout(const Duration(seconds: 30));
    if (m.audioOnly.isEmpty) throw 'Audio tidak tersedia untuk video ini';
    final mp4 = m.audioOnly.where((s) => s.container == StreamContainer.mp4);
    final l = (mp4.isNotEmpty ? mp4 : m.audioOnly).toList();
    l.sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    return l.first;
  }

  // ---------- antrean ----------
  Future<bool> enqueue(Video v) async {
    if (jobs.any((j) => j.video.id.value == v.id.value && j.active)) {
      return false;
    }
    jobs.add(Job(v, kbps));
    notifyListeners();
    if (!_asked) {
      _asked = true;
      try {
        await [Permission.audio, Permission.storage, Permission.notification]
            .request();
      } catch (_) {}
    }
    unawaited(_pump());
    return true;
  }

  Future<void> cancel(Job j) async {
    if (j.state == JobState.queued) {
      j.state = JobState.canceled;
    } else if (j.state == JobState.downloading ||
        j.state == JobState.converting) {
      j.cancelRequested = true;
      if (j.state == JobState.converting) {
        try {
          await FFmpegKit.cancel(j.sessionId);
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  void cancelAll() {
    for (final j in List<Job>.from(jobs)) {
      if (j.active) unawaited(cancel(j));
    }
  }

  void clearFinished() {
    jobs.removeWhere((j) => !j.active);
    notifyListeners();
  }

  void retry(Job j) {
    if (j.active) return;
    j.state = JobState.queued;
    j.cancelRequested = false;
    j.attempts = 0;
    j.progress = 0;
    j.note = '';
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> _svc(bool on) async {
    try {
      if (on) {
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: 'MusicGrab MP3',
          notificationText: 'Memproses antrean...',
        );
      } else {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
  }

  void _notif(String t) {
    try {
      unawaited(FlutterForegroundTask.updateService(notificationText: t)
          .then((_) {}, onError: (_) {}));
    } catch (_) {}
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      await _svc(true);
      while (true) {
        final i = jobs.indexWhere((j) => j.state == JobState.queued);
        if (i < 0) break;
        final j = jobs[i];
        await _run(j);
        if (j.state == JobState.failed && j.attempts < 2) {
          await Future.delayed(const Duration(seconds: 3));
          if (j.state == JobState.failed) {
            j.state = JobState.queued;
            notifyListeners();
          }
        }
      }
    } catch (_) {
    } finally {
      await _svc(false);
      _running = false;
    }
    if (jobs.any((j) => j.state == JobState.queued)) unawaited(_pump());
  }

  Future<ReturnCode?> _ffmpeg(Job j, String inp, String out) async {
    final done = Completer<ReturnCode?>();
    final s = await FFmpegKit.executeWithArgumentsAsync([
      '-y', '-i', inp, '-vn', '-map_metadata', '-1',
      '-c:a', 'libmp3lame', '-b:a', '${j.kbps}k', // CBR
      '-ar', '44100', '-ac', '2',
      '-write_xing', '0', '-id3v2_version', '0',
      out,
    ], (ss) async {
      final rc = await ss.getReturnCode();
      if (!done.isCompleted) done.complete(rc);
    });
    j.sessionId = s.getSessionId();
    if (j.cancelRequested) await FFmpegKit.cancel(j.sessionId);
    return done.future.timeout(const Duration(minutes: 10), onTimeout: () {
      FFmpegKit.cancel(j.sessionId);
      return null;
    });
  }

  Future<void> _run(Job j) async {
    File? tmp;
    String? out;
    j.attempts++;
    j.note = '';
    j.progress = 0;
    j.state = JobState.downloading;
    notifyListeners();
    try {
      _notif(j.video.title);
      final s = await pick(j.video);
      if (j.cancelRequested) throw _Canceled();
      final f = File(
          '${(await getTemporaryDirectory()).path}/${j.video.id.value}.src');
      tmp = f;
      if (await f.exists()) await f.delete();
      final sink = f.openWrite();
      final total = s.size.totalBytes;
      var got = 0, last = -1;
      try {
        await for (final c in yt.videos.streamsClient
            .get(s)
            .timeout(const Duration(seconds: 25))) {
          if (j.cancelRequested) break;
          sink.add(c);
          got += c.length;
          if (total > 0) {
            j.progress = math.min(1.0, got / total);
            final pc = (j.progress * 100).floor();
            if (pc != last) {
              last = pc;
              notifyListeners();
              if (pc % 10 == 0) _notif('${j.video.title} - $pc%');
            }
          }
        }
      } finally {
        await sink.close();
      }
      if (j.cancelRequested) throw _Canceled();
      if (got == 0 || (total > 0 && got < total * 0.98)) {
        throw 'Unduhan tidak lengkap';
      }

      j.state = JobState.converting;
      notifyListeners();
      var ok = false;
      for (final d in await _outDirs()) {
        final path =
            _unique(d.path, buildName(j.video.title, j.video.author, j.kbps));
        out = path;
        final rc = await _ffmpeg(j, f.path, path);
        if (j.cancelRequested || ReturnCode.isCancel(rc)) throw _Canceled();
        if (ReturnCode.isSuccess(rc) &&
            File(path).existsSync() &&
            File(path).lengthSync() > 1024) {
          ok = true;
          break;
        }
        await _del(path);
      }
      if (!ok) throw 'Konversi gagal atau folder tidak bisa ditulis';
      j.note = out ?? '';
      j.state = JobState.done;
    } on _Canceled {
      j.state = JobState.canceled;
    } catch (e) {
      j.state = JobState.failed;
      j.note = errText(e);
    } finally {
      try {
        await tmp?.delete();
      } catch (_) {}
      final o = out;
      if (o != null && j.state != JobState.done) await _del(o);
      j.sessionId = null;
      notifyListeners();
    }
  }
}

// ======================= UI =======================

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'dl',
          channelName: 'Unduhan MP3',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
    } catch (_) {}
    final ctl = Ctl();
    await ctl.init();
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Home(ctl: ctl),
    ));
  }, (e, s) => debugPrint('Error: $e'));
}

class Home extends StatefulWidget {
  const Home({super.key, required this.ctl});
  final Ctl ctl;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) {
    final c = widget.ctl;
    return Scaffold(
      appBar: AppBar(title: const Text('MusicGrab MP3')),
      body: IndexedStack(index: _tab, children: [
        SearchTab(ctl: c),
        QueueTab(ctl: c),
        SettingsTab(ctl: c),
      ]),
      bottomNavigationBar: ListenableBuilder(
        listenable: c,
        builder: (_, __) {
          final n = c.jobs.where((j) => j.active).length;
          return NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.search), label: 'Cari'),
              NavigationDestination(
                  icon: Badge(
                      isLabelVisible: n > 0,
                      label: Text('$n'),
                      child: const Icon(Icons.queue_music)),
                  label: 'Antrean'),
              const NavigationDestination(
                  icon: Icon(Icons.settings), label: 'Pengaturan'),
            ],
          );
        },
      ),
    );
  }
}

class SearchTab extends StatefulWidget {
  const SearchTab({super.key, required this.ctl});
  final Ctl ctl;
  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _q = TextEditingController();
  final _player = AudioPlayer();
  List<Video> _items = [];
  bool _loading = false, _prep = false;
  String? _playing;
  int _seq = 0, _ptok = 0;
  StreamSubscription<PlayerState>? _s1;
  StreamSubscription<PlaybackEvent>? _s2;

  @override
  void initState() {
    super.initState();
    _s1 = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() => _playing = null);
      }
    });
    _s2 = _player.playbackEventStream.listen((_) {}, onError: (Object e) {
      if (mounted) {
        setState(() {
          _playing = null;
          _prep = false;
        });
        _toast('Preview gagal diputar.');
      }
    });
  }

  @override
  void dispose() {
    _s1?.cancel();
    _s2?.cancel();
    _player.dispose();
    _q.dispose();
    super.dispose();
  }

  void _toast(String s) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.clearSnackBars();
    m.showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    final my = ++_seq;
    setState(() => _loading = true);
    try {
      final r = await widget.ctl.yt.search
          .search(q)
          .timeout(const Duration(seconds: 20));
      if (!mounted || my != _seq) return;
      setState(() => _items = r.take(30).toList());
      if (_items.isEmpty) _toast('Tidak ada hasil.');
    } catch (e) {
      if (mounted && my == _seq) _toast(errText(e));
    } finally {
      if (mounted && my == _seq) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(Video v) async {
    final id = v.id.value;
    final tok = ++_ptok;
    try {
      if (_playing == id) {
        await _player.stop();
        if (mounted) {
          setState(() {
            _playing = null;
            _prep = false;
          });
        }
        return;
      }
      await _player.stop();
      if (!mounted) return;
      setState(() {
        _playing = id;
        _prep = true;
      });
      final s = await widget.ctl.pick(v);
      if (tok != _ptok || !mounted) return;
      await _player.setUrl(s.url.toString());
      if (tok != _ptok || !mounted) return;
      setState(() => _prep = false);
      unawaited(_player.play());
    } catch (e) {
      if (tok == _ptok && mounted) {
        setState(() {
          _playing = null;
          _prep = false;
        });
        _toast(errText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.ctl;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: const InputDecoration(
                  hintText: 'Cari lagu...', border: OutlineInputBorder()),
            ),
          ),
          IconButton(onPressed: _search, icon: const Icon(Icons.search)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListenableBuilder(
          listenable: c,
          builder: (_, __) => Row(children: [
            const Text('Kualitas: '),
            DropdownButton<int>(
              value: c.kbps,
              items: const [
                DropdownMenuItem(value: 128, child: Text('Standar (128 kbps)')),
                DropdownMenuItem(value: 192, child: Text('192 kbps')),
                DropdownMenuItem(value: 256, child: Text('256 kbps')),
                DropdownMenuItem(value: 320, child: Text('Tinggi (320 kbps)')),
              ],
              onChanged: (v) {
                c.kbps = v ?? 128;
                c.saveSettings();
              },
            ),
          ]),
        ),
      ),
      if (_loading) const LinearProgressIndicator(),
      Expanded(
        child: _items.isEmpty
            ? const Center(child: Text('Ketik judul lagu lalu tekan cari'))
            : ListenableBuilder(
                listenable: c,
                builder: (_, __) => ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final v = _items[i];
                    final id = v.id.value;
                    final queued = c.jobs
                        .any((j) => j.video.id.value == id && j.active);
                    final done = c.jobs.any((j) =>
                        j.video.id.value == id && j.state == JobState.done);
                    final dur =
                        v.duration?.toString().split('.').first ?? '';
                    return ListTile(
                      leading: Image.network(v.thumbnails.mediumResUrl,
                          width: 56,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.music_note)),
                      title: Text(v.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${v.author} • $dur'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        (_playing == id && _prep)
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)))
                            : IconButton(
                                icon: Icon(_playing == id
                                    ? Icons.stop
                                    : Icons.play_arrow),
                                onPressed: () => _toggle(v)),
                        IconButton(
                          icon: Icon(queued
                              ? Icons.hourglass_top
                              : (done ? Icons.check_circle : Icons.download)),
                          onPressed: queued
                              ? null
                              : () async {
                                  final ok = await c.enqueue(v);
                                  _toast(ok
                                      ? 'Ditambahkan ke antrean'
                                      : 'Sudah ada di antrean');
                                },
                        ),
                      ]),
                    );
                  },
                ),
              ),
      ),
    ]);
  }
}

class QueueTab extends StatelessWidget {
  const QueueTab({super.key, required this.ctl});
  final Ctl ctl;

  String _label(Job j) {
    switch (j.state) {
      case JobState.queued:
        return 'Menunggu antrean';
      case JobState.downloading:
        return 'Mengunduh ${(j.progress * 100).floor()}%';
      case JobState.converting:
        return 'Konversi ke MP3 ${j.kbps} kbps...';
      case JobState.done:
        return 'Selesai: ${j.note}';
      case JobState.failed:
        return 'Gagal: ${j.note}';
            case JobState.canceled:
        return 'Dibatalkan';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final jobs = ctl.jobs;
        if (jobs.isEmpty) {
          return const Center(child: Text('Antrean kosong'));
        }
        return Column(children: [
          Row(children: [
            TextButton.icon(
                onPressed: ctl.cancelAll,
                icon: const Icon(Icons.cancel),
                label: const Text('Batalkan semua')),
            TextButton.icon(
                onPressed: ctl.clearFinished,
                icon: const Icon(Icons.cleaning_services),
                label: const Text('Bersihkan selesai')),
          ]),
          Expanded(
            child: ListView.separated(
              itemCount: jobs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final j = jobs[i];
                final busy = j.state == JobState.downloading ||
                    j.state == JobState.converting;
                return ListTile(
                  title: Text(j.video.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_label(j),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (busy)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: LinearProgressIndicator(
                                value: j.state == JobState.downloading
                                    ? j.progress
                                    : null),
                          ),
                      ]),
                  trailing: j.active
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Batal',
                          onPressed: () => ctl.cancel(j))
                      : (j.state == JobState.done
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : IconButton(
                              icon: const Icon(Icons.refresh),
                              tooltip: 'Coba lagi',
                              onPressed: () => ctl.retry(j))),
                );
              },
            ),
          ),
        ]);
      },
    );
  }
}

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key, required this.ctl});
  final Ctl ctl;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Format nama file'),
          DropdownButton<int>(
            isExpanded: true,
            value: ctl.nameFmt,
            items: const [
              DropdownMenuItem(value: 0, child: Text('Judul')),
              DropdownMenuItem(value: 1, child: Text('Artis - Judul')),
              DropdownMenuItem(value: 2, child: Text('Judul - Artis')),
            ],
            onChanged: (v) {
              ctl.nameFmt = v ?? 1;
              ctl.saveSettings();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Tambah bitrate di nama (_128k)'),
            value: ctl.addKbps,
            onChanged: (v) {
              ctl.addKbps = v;
              ctl.saveSettings();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hanya karakter ASCII'),
            subtitle: const Text('Aman untuk tape/head unit jadul'),
            value: ctl.ascii,
            onChanged: (v) {
              ctl.ascii = v;
              ctl.saveSettings();
            },
          ),
          const SizedBox(height: 12),
          Text('Contoh: ${ctl.buildName('Judul Lagu', 'Nama Artis', ctl.kbps)}'),
          const SizedBox(height: 8),
          const Text('Folder: Music/YTMP3\nFormat: MP3 CBR, 44100 Hz, stereo'),
        ],
      ),
    );
  }
}
