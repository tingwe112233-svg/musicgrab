import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' show Video;
import 'ctl.dart';

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
  static const _cats = <String, String>{
    'Terpopuler': 'lagu terpopuler Indonesia 2026',
    'Pop': 'lagu pop Indonesia terbaru',
    'Dangdut': 'dangdut terbaru 2026',
    'DJ Remix': 'dj remix terbaru 2026',
    'Rock': 'lagu rock Indonesia',
    'Religi': 'sholawat religi terbaru',
    'Barat': 'top english songs 2026',
  };

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search(_cats.values.first);
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

  Future<void> _search([String? preset]) async {
    final q = (preset ?? _q.text).trim();
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
      final s = await widget.ctl.previewSrc(v);
      if (tok != _ptok || !mounted) return;
      await _player.setUrl(s.url, headers: s.headers);
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
      SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (final e in _cats.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  label: Text(e.key),
                  onPressed: () {
                    _q.clear();
                    _search(e.value);
                  },
                ),
              ),
          ],
        ),
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
            ? Center(
                child: Text(_loading
                    ? 'Memuat...'
                    : 'Ketik judul lagu lalu tekan cari'))
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
    if (j.cancelRequested && j.active) return 'Membatalkan...';
    switch (j.state) {
      case JobState.queued:
        return 'Menunggu antrean';
      case JobState.downloading:
        return j.progress == 0
            ? 'Menghubungi YouTube...'
            : 'Mengunduh ${(j.progress * 100).floor()}%';
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
                            maxLines: 3, overflow: TextOverflow.ellipsis),
                        if (busy)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: LinearProgressIndicator(
                                value: (j.state == JobState.downloading &&
                                        j.progress > 0)
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
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update),
            title: const Text('Perbarui mesin yt-dlp'),
            subtitle: const Text(
                'Tap kalau unduhan gagal karena YouTube berubah (butuh internet)'),
            onTap: () async {
              final m = ScaffoldMessenger.of(context);
              m.showSnackBar(
                  const SnackBar(content: Text('Memperbarui, mohon tunggu...')));
              final r = await ctl.updateEngine();
              m.clearSnackBars();
              m.showSnackBar(SnackBar(content: Text(r)));
            },
          ),
        ],
      ),
    );
  }
}
