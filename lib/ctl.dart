import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    show YoutubeExplode, Video;

enum JobState { queued, downloading, converting, done, failed, canceled }

class _Canceled implements Exception {}

class Src {
  Src(this.url, this.headers);
  final String url;
  final Map<String, String> headers;
}

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
  Completer<void> abort = Completer<void>();
  bool get active =>
      state == JobState.queued ||
      state == JobState.downloading ||
      state == JobState.converting;
}

String errText(Object e) {
  final s = e is PlatformException ? (e.message ?? e.code) : e.toString();
  if (e is TimeoutException ||
      s.contains('SocketException') ||
      s.contains('ClientException') ||
      s.contains('host lookup')) {
    return 'Koneksi terputus atau lambat. Coba lagi.';
  }
  final lines = s
      .replaceAll('Exception: ', '')
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();
  final t = lines.isEmpty ? 'Kesalahan tidak diketahui' : lines.last.trim();
  return t.length > 160 ? t.substring(0, 160) : t;
}

/// Jembatan ke yt-dlp (Kotlin, lihat build.yml)
class Ytdlp {
  static const _c = MethodChannel('musicgrab/ytdlp');
  static final _cb = <String, void Function(double)>{};
  static bool _hooked = false;

  static void _hook() {
    if (_hooked) return;
    _hooked = true;
    _c.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final m = Map<String, dynamic>.from(call.arguments as Map);
        _cb[m['id'] as String]?.call((m['p'] as num).toDouble());
      }
      return null;
    });
  }

  static String _url(String id) => 'https://www.youtube.com/watch?v=$id';

  static Future<Map<String, dynamic>> info(String id) async {
    final s = await _c.invokeMethod<String>('info', {'url': _url(id)});
    final l = (s ?? '')
        .trim()
        .split('\n')
        .where((x) => x.trim().startsWith('{'))
        .toList();
    if (l.isEmpty) throw 'Info video tidak ditemukan';
    return jsonDecode(l.last) as Map<String, dynamic>;
  }

  static Future<void> download(
      String id, String out, void Function(double) onP) async {
    _hook();
    _cb[id] = onP;
    try {
      await _c.invokeMethod(
          'download', {'url': _url(id), 'id': id, 'out': out});
    } finally {
      _cb.remove(id);
    }
  }

  static Future<void> cancel(String id) async {
    await _c.invokeMethod('cancel', {'id': id});
  }

  static Future<String> update() async =>
      (await _c.invokeMethod<String>('update')) ?? '';
}

class Ctl extends ChangeNotifier {
  final yt = YoutubeExplode();
  final jobs = <Job>[];
  bool _running = false, _asked = false;
  SharedPreferences? _p;
  Future<void> _engine = Future.value();
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
    _engine = Ytdlp.update().then((_) {}, onError: (_) {});
    notifyListeners();
  }

  Future<void> _engineReady() async {
    try {
      await _engine.timeout(const Duration(seconds: 60));
    } catch (_) {}
  }

  Future<String> updateEngine() async {
    try {
      final r = await Ytdlp.update().timeout(const Duration(seconds: 90));
      return 'Mesin yt-dlp diperbarui ($r)';
    } catch (e) {
      return 'Gagal memperbarui: ${errText(e)}';
    }
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

  // ---------- sumber preview ----------
  Future<Src> previewSrc(Video v) async {
    await _engineReady();
    final m = await Ytdlp.info(v.id.value).timeout(const Duration(seconds: 90));
    final url = m['url'] as String?;
    if (url == null || url.isEmpty) throw 'Sumber audio tidak ditemukan';
    final h = <String, String>{};
    (m['http_headers'] as Map?)?.forEach((k, val) => h['$k'] = '$val');
    return Src(url, h);
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
      if (!j.abort.isCompleted) j.abort.complete();
      unawaited(Ytdlp.cancel(j.video.id.value).then((_) {}, onError: (_) {}));
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
    j.abort = Completer<void>();
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

  Future<T> _race<T>(Job j, Future<T> f) =>
      Future.any<T>([f, j.abort.future.then<T>((_) => throw _Canceled())]);

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
    final id = j.video.id.value;
    j.attempts++;
    j.note = '';
    j.progress = 0;
    j.state = JobState.downloading;
    notifyListeners();
    try {
      _notif(j.video.title);
      await _race(j, _engineReady());
      final f = File('${(await getTemporaryDirectory()).path}/$id.src');
      tmp = f;
      if (await f.exists()) await f.delete();
      var last = -1;
      await _race(
          j,
          Ytdlp.download(id, f.path, (p) {
            final pc = p.floor().clamp(0, 100).toInt();
            if (pc != last) {
              last = pc;
              j.progress = pc / 100;
              notifyListeners();
              if (pc % 10 == 0) _notif('${j.video.title} - $pc%');
            }
          }).timeout(const Duration(minutes: 15), onTimeout: () {
            unawaited(Ytdlp.cancel(id).then((_) {}, onError: (_) {}));
            throw TimeoutException('Waktu habis');
          }));
      if (j.cancelRequested) throw _Canceled();
      if (!await f.exists() || await f.length() < 1024) {
        throw 'Unduhan gagal (file kosong)';
      }

      j.state = JobState.converting;
      notifyListeners();
      var ok = false;
      for (final d in await _outDirs()) {
        final path =
            _unique(d.path, buildName(j.video.title, j.video.author, j.kbps));
        out = path;
        final rc = await _race(j, _ffmpeg(j, f.path, path));
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
