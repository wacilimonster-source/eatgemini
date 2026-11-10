/// 检查更新：GitHub Releases 最新发布 + update.json 回退源。
///
/// 隐私边界：只有用户手动点「检查更新」或开启自动检查时才会联网，
/// 请求只发往 GitHub，不携带任何 Key、令牌、对话或用量数据。
/// 界面只走本机控制台 API，服务端返回的下载地址不会注入页面 DOM。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String kUpdateOwner = 'wacilimonster-source';
const String kUpdateRepo = 'eatgemini';
const String kReleasesApiUrl =
    'https://api.github.com/repos/$kUpdateOwner/$kUpdateRepo/releases/latest';
const String kReleasePageUrl =
    'https://github.com/$kUpdateOwner/$kUpdateRepo/releases/latest';
const String kUpdateManifestUrl =
    'https://raw.githubusercontent.com/$kUpdateOwner/$kUpdateRepo/main/update.json';

const Duration kAutoCheckInterval = Duration(hours: 24);
const int kMaxInstallerBytes = 60 * 1024 * 1024;

/// 宽松的语义版本：支持 v 前缀、-pre、+build、缺位补 0。
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, {this.pre = ''});

  final int major;
  final int minor;
  final int patch;
  final String pre;

  static SemVer? tryParse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    final buildAt = text.indexOf('+');
    if (buildAt >= 0) text = text.substring(0, buildAt);
    var pre = '';
    final dashAt = text.indexOf('-');
    if (dashAt >= 0) {
      pre = text.substring(dashAt + 1);
      text = text.substring(0, dashAt);
    }
    final parts = text.split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final nums = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0) return null;
      nums.add(n);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return SemVer(nums[0], nums[1], nums[2], pre: pre);
  }

  @override
  int compareTo(SemVer other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (pair.$1 != pair.$2) return pair.$1.compareTo(pair.$2);
    }
    if (pre == other.pre) return 0;
    if (pre.isEmpty) return 1; // 正式版高于预发布
    if (other.pre.isEmpty) return -1;
    return pre.compareTo(other.pre);
  }

  @override
  String toString() =>
      pre.isEmpty ? '$major.$minor.$patch' : '$major.$minor.$patch-$pre';
}

class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.releaseUrl,
    this.notes = '',
    this.publishedAt = '',
    this.installerUrl = '',
    this.portableUrl = '',
    this.installerSize = 0,
  });

  final String version;
  final String releaseUrl;
  final String notes;
  final String publishedAt;
  final String installerUrl;
  final String portableUrl;
  final int installerSize;

  static UpdateRelease? fromGitHub(Map<String, Object?> json) {
    final parsed = SemVer.tryParse((json['tag_name'] ?? '').toString());
    if (parsed == null) return null;
    var installerUrl = '';
    var portableUrl = '';
    var installerSize = 0;
    final assets = json['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = (asset['name'] ?? '').toString();
        final url = (asset['browser_download_url'] ?? '').toString();
        final size = (asset['size'] as num?)?.toInt() ?? 0;
        if (!url.startsWith('https://')) continue;
        if (name.startsWith('eatgemini-setup-') && name.endsWith('.exe')) {
          if (installerUrl.isEmpty || size > installerSize) {
            installerUrl = url;
            installerSize = size;
          }
        } else if (name.startsWith('eatgemini-v') &&
            name.endsWith('.exe') &&
            portableUrl.isEmpty) {
          portableUrl = url;
        }
      }
    }
    return UpdateRelease(
      version: parsed.toString(),
      releaseUrl: (json['html_url'] ?? kReleasePageUrl).toString(),
      notes: (json['body'] ?? '').toString().trim(),
      publishedAt: (json['published_at'] ?? '').toString(),
      installerUrl: installerUrl,
      portableUrl: portableUrl,
      installerSize: installerSize,
    );
  }

  /// 仓库根目录 update.json（API 被限流/不可达时的回退源）。
  static UpdateRelease? fromManifest(Map<String, Object?> json) {
    final parsed = SemVer.tryParse((json['version'] ?? '').toString());
    if (parsed == null) return null;
    return UpdateRelease(
      version: parsed.toString(),
      releaseUrl: (json['releaseUrl'] ?? kReleasePageUrl).toString(),
      notes: (json['notes'] ?? '').toString().trim(),
      publishedAt: (json['publishedAt'] ?? '').toString(),
      installerUrl: (json['installerUrl'] ?? '').toString(),
      portableUrl: (json['portableUrl'] ?? '').toString(),
      installerSize: (json['installerSize'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 落盘的检查结果与下载状态（数据目录 updates/update-state.json）。
class UpdateState {
  UpdateState();

  String? lastCheckedAt;
  String? latestVersion;
  String? publishedAt;
  String? notes;
  String? releaseUrl;
  String? installerUrl;
  String? portableUrl;
  int installerSize = 0;
  String? skippedVersion;
  String? downloadedPath;
  String? lastError;
  String? source;

  factory UpdateState.fromJson(Map<String, Object?> json) => UpdateState()
    ..lastCheckedAt = json['lastCheckedAt']?.toString()
    ..latestVersion = json['latestVersion']?.toString()
    ..publishedAt = json['publishedAt']?.toString()
    ..notes = json['notes']?.toString()
    ..releaseUrl = json['releaseUrl']?.toString()
    ..installerUrl = json['installerUrl']?.toString()
    ..portableUrl = json['portableUrl']?.toString()
    ..installerSize = (json['installerSize'] as num?)?.toInt() ?? 0
    ..skippedVersion = json['skippedVersion']?.toString()
    ..downloadedPath = json['downloadedPath']?.toString()
    ..lastError = json['lastError']?.toString()
    ..source = json['source']?.toString();

  Map<String, Object?> toJson() => {
        if (lastCheckedAt != null) 'lastCheckedAt': lastCheckedAt,
        if (latestVersion != null) 'latestVersion': latestVersion,
        if (publishedAt != null) 'publishedAt': publishedAt,
        if (notes != null) 'notes': notes,
        if (releaseUrl != null) 'releaseUrl': releaseUrl,
        if (installerUrl != null) 'installerUrl': installerUrl,
        if (portableUrl != null) 'portableUrl': portableUrl,
        'installerSize': installerSize,
        if (skippedVersion != null) 'skippedVersion': skippedVersion,
        if (downloadedPath != null) 'downloadedPath': downloadedPath,
        if (lastError != null) 'lastError': lastError,
        if (source != null) 'source': source,
      };

  bool hasUpdate(String currentVersion) {
    final latest = SemVer.tryParse(latestVersion ?? '');
    final current = SemVer.tryParse(currentVersion);
    if (latest == null || current == null) return false;
    if (latest.compareTo(current) <= 0) return false;
    return skippedVersion != latest.toString();
  }

  bool installerReady() =>
      downloadedPath != null && File(downloadedPath!).existsSync();
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.ok,
    required this.fromCache,
    required this.state,
    this.error,
    this.busy = false,
  });

  final bool ok;
  final bool fromCache;
  final bool busy;
  final String? error;
  final UpdateState state;
}

typedef UrlFetcher = Future<String> Function(
  String url, {
  Map<String, String> headers,
});

UrlFetcher _defaultFetcher(void Function(HttpClient)? configureClient) {
  return (url, {headers = const <String, String>{}}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    configureClient?.call(client);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('user-agent', 'eatgemini-update-check');
      req.headers.set('accept', 'application/json');
      for (final entry in headers.entries) {
        req.headers.set(entry.key, entry.value);
      }
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final body = await utf8.decoder
          .bind(resp)
          .join()
          .timeout(const Duration(seconds: 15));
      if (body.length > 2 << 20) throw StateError('更新响应过大');
      return body;
    } finally {
      client.close(force: true);
    }
  };
}

class UpdateChecker {
  UpdateChecker({
    required this.currentVersion,
    required this.updatesDir,
    UrlFetcher? fetcher,
    void Function(HttpClient)? configureClient,
    DateTime Function()? now,
  })  : _fetcher = fetcher ?? _defaultFetcher(configureClient),
        _now = now ?? DateTime.now,
        _configureClient = configureClient;

  final String currentVersion;
  final Directory updatesDir;
  final UrlFetcher _fetcher;
  final DateTime Function() _now;
  final void Function(HttpClient)? _configureClient;

  UpdateState _state = UpdateState();
  bool _loaded = false;
  bool _checking = false;

  bool get checking => _checking;
  UpdateState get state => _state;

  File get stateFile => File(
      '${updatesDir.path}${Platform.pathSeparator}update-state.json');

  Future<UpdateState> load() async {
    if (_loaded) return _state;
    try {
      if (await stateFile.exists()) {
        final decoded = jsonDecode(await stateFile.readAsString());
        if (decoded is Map) {
          _state = UpdateState.fromJson(decoded.cast<String, Object?>());
        }
      }
    } catch (_) {}
    if (_state.downloadedPath != null &&
        !File(_state.downloadedPath!).existsSync()) {
      _state.downloadedPath = null;
    }
    _loaded = true;
    return _state;
  }

  Future<void> _save() async {
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }
    final tmp = File('${stateFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(_state.toJson()), flush: true);
    if (await stateFile.exists()) await stateFile.delete();
    await tmp.rename(stateFile.path);
  }

  /// [force] 为 true（手动点击）忽略 24 小时节流；自动检查走节流。
  Future<UpdateCheckResult> check({bool force = false}) async {
    await load();
    if (_checking) {
      return UpdateCheckResult(
          ok: true, fromCache: true, state: _state, busy: true);
    }
    if (!force) {
      final last = DateTime.tryParse(_state.lastCheckedAt ?? '');
      if (last != null &&
          _now().toUtc().difference(last.toUtc()) < kAutoCheckInterval) {
        return UpdateCheckResult(
          ok: _state.lastError == null,
          fromCache: true,
          state: _state,
          error: _state.lastError,
        );
      }
    }
    _checking = true;
    try {
      UpdateRelease? release;
      String? error;
      String source = 'releases';
      try {
        final raw = await _fetcher(kReleasesApiUrl,
            headers: const {'accept': 'application/vnd.github+json'});
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          release = UpdateRelease.fromGitHub(decoded.cast<String, Object?>());
        }
      } catch (e) {
        error = 'Releases 接口不可用：$e';
      }
      if (release == null) {
        try {
          final raw = await _fetcher(kUpdateManifestUrl);
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            release =
                UpdateRelease.fromManifest(decoded.cast<String, Object?>());
          }
          if (release != null) {
            error = null;
            source = 'manifest';
          }
        } catch (e) {
          error ??= '更新源不可用：$e';
        }
      }
      _state.lastCheckedAt = _now().toUtc().toIso8601String();
      if (release == null) {
        _state.lastError = error ?? '未解析到有效发布信息';
        await _save();
        return UpdateCheckResult(
          ok: false,
          fromCache: false,
          state: _state,
          error: _state.lastError,
        );
      }
      _state
        ..lastError = null
        ..latestVersion = release.version
        ..publishedAt = release.publishedAt
        ..notes = release.notes
        ..releaseUrl = release.releaseUrl
        ..installerUrl = release.installerUrl
        ..portableUrl = release.portableUrl
        ..installerSize = release.installerSize
        ..source = source;
      if (_state.downloadedPath != null &&
          !_state.downloadedPath!.contains('v${release.version}')) {
        _state.downloadedPath = null;
      }
      await _save();
      return UpdateCheckResult(
          ok: true, fromCache: false, state: _state);
    } finally {
      _checking = false;
    }
  }

  Future<void> skipVersion(String version) async {
    await load();
    _state.skippedVersion = version.trim();
    await _save();
  }

  Future<void> clearSkip() async {
    await load();
    _state.skippedVersion = null;
    await _save();
  }

  String releasePageUrl() {
    final saved = _state.releaseUrl;
    return (saved != null && saved.startsWith('https://github.com/'))
        ? saved
        : kReleasePageUrl;
  }

  /// 下载安装版到数据目录 updates/；已完成且大小匹配时直接复用。
  Future<String> downloadInstaller({
    void Function(int received, int? total)? onProgress,
  }) async {
    await load();
    final url = (_state.installerUrl ?? '').trim();
    if (url.isEmpty) {
      throw StateError('当前发布没有提供安装版下载地址，请前往发布页手动下载');
    }
    final uri = Uri.parse(url);
    if (!uri.isScheme('https') ||
        !(uri.host == 'github.com' ||
            uri.host == 'raw.githubusercontent.com' ||
            uri.host.endsWith('.githubusercontent.com'))) {
      throw StateError('下载地址不在允许的 GitHub 域名内');
    }
    if (!await updatesDir.exists()) {
      await updatesDir.create(recursive: true);
    }
    final version = _state.latestVersion ?? currentVersion;
    final target = File(
        '${updatesDir.path}${Platform.pathSeparator}eatgemini-setup-v$version.exe');
    if (await target.exists() &&
        (_state.installerSize <= 0 ||
            await target.length() == _state.installerSize)) {
      _state.downloadedPath = target.path;
      await _save();
      return target.path;
    }
    final tmp = File('${target.path}.part');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _configureClient?.call(client);
    try {
      final req = await client.getUrl(uri);
      req.headers.set('user-agent', 'eatgemini-update-check');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength >= 0 ? resp.contentLength : null;
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp) {
          received += chunk.length;
          if (received > kMaxInstallerBytes) {
            throw StateError('安装包超过 60 MB，已中止下载');
          }
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      if (await tmp.length() == 0) throw StateError('下载内容为空');
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      _state.downloadedPath = target.path;
      await _save();
      return target.path;
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 启动已下载的安装器（安装器会请求旧实例退出后再覆盖）。
  Future<void> runInstaller() async {
    await load();
    final path = _state.downloadedPath;
    if (path == null || !File(path).existsSync()) {
      throw StateError('还没有下载安装版');
    }
    await Process.start(
      path,
      const ['--from-update'],
      mode: ProcessStartMode.detached,
    );
  }

  /// 前端展示用状态（不含任何可直接导航的外链地址）。
  Map<String, Object?> describe({required bool autoCheck}) => {
        'currentVersion': currentVersion,
        'autoCheck': autoCheck,
        'checking': _checking,
        'hasUpdate': _state.hasUpdate(currentVersion),
        'latestVersion': _state.latestVersion,
        'publishedAt': _state.publishedAt,
        'notes': _state.notes,
        'skippedVersion': _state.skippedVersion,
        'lastCheckedAt': _state.lastCheckedAt,
        'lastError': _state.lastError,
        'source': _state.source,
        'installerAvailable': (_state.installerUrl ?? '').isNotEmpty,
        'installerSize': _state.installerSize,
        'installerReady': _state.installerReady(),
        'installerPath': _state.downloadedPath,
      };
}
