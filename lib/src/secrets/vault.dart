/// 密钥库：DPAPI 加密的 secrets.dat，客户端令牌生成与轮换。
///
/// 规则来源：桌面文档 §6。
/// 文件只在本机当前 Windows 用户下可解；不存在任何上传路径。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../observe/observability.dart';
import 'dpapi.dart';

class VaultLoadResult {
  const VaultLoadResult({
    required this.ok,
    this.renamedTo,
    this.message,
  });

  final bool ok;
  final String? renamedTo;
  final String? message;
}

class ApiKey {
  ApiKey(this.value);

  final String value;

  String get masked => maskSecret(value);

  @override
  String toString() => masked;
}

class ClientToken {
  ClientToken({
    required this.clientId,
    required this.value,
    this.createdAt,
  });

  final String clientId;
  final String value;
  final DateTime? createdAt;

  String get masked => maskSecret(value);

  @override
  String toString() => masked;
}

String maskSecret(String value) {
  if (value.length <= 8) return '••••';
  return '${value.substring(0, 4)}…${value.substring(value.length - 4)}';
}

class SecretVault {
  SecretVault({
    required this.directory,
    required this.dpapi,
    required this.clientIds,
    Redactor? redactor,
  }) : redactor = redactor ?? Redactor();

  final Directory directory;
  final Dpapi dpapi;
  final List<String> clientIds;
  final Redactor redactor;

  static const _format = 'eatgemini-secrets';
  static const _version = 1;
  static const _entropyPrefix = 'eatgemini/secrets/v1';

  Uint8List? _salt;
  ApiKey? _upstreamKey;
  DateTime? _addedAt;
  DateTime? _lastVerifiedAt;
  String? _lastVerifyResult;
  final Map<String, ClientToken> _tokens = {};
  ApiKey? _envKey;

  ApiKey? get upstreamKey => _upstreamKey ?? _envKey;

  String? get upstreamSource => _upstreamKey != null
      ? 'vault'
      : (_envKey != null ? 'env' : null);

  bool get hasUpstreamKey => upstreamKey != null;

  String? get addedAt => _addedAt?.toUtc().toIso8601String();
  String? get lastVerifiedAt => _lastVerifiedAt?.toUtc().toIso8601String();
  String? get lastVerifyResult => _lastVerifyResult;

  Map<String, ClientToken> get tokens => Map.unmodifiable(_tokens);

  ClientToken? tokenFor(String clientId) => _tokens[clientId];

  File get _file =>
      File('${directory.path}${Platform.pathSeparator}secrets.dat');
  File get _backup =>
      File('${directory.path}${Platform.pathSeparator}secrets.dat.bak');

  Future<VaultLoadResult> load() async {
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final envKey = Platform.environment['GEMINI_API_KEY'];
    if (envKey != null && envKey.trim().isNotEmpty) {
      _envKey = ApiKey(envKey.trim());
    }

    Map<String, Object?>? envelope;
    String? failure;
    for (final file in [_file, _backup]) {
      if (!file.existsSync()) continue;
      try {
        envelope = jsonDecode(await file.readAsString()) as Map<String, Object?>;
        failure = null;
        break;
      } catch (e) {
        failure = e.toString();
      }
    }

    if (envelope == null) {
      if (failure != null) {
        final renamed = await _quarantine();
        await _bootstrapTokens();
        return VaultLoadResult(
          ok: false,
          renamedTo: renamed,
          message: '密钥文件损坏，已改名保留并重新生成访问令牌',
        );
      }
      await _bootstrapTokens();
      return const VaultLoadResult(ok: true);
    }

    try {
      if (envelope['format'] != _format) {
        throw DpapiException('未知的文件格式');
      }
      final saltRaw = envelope['salt'];
      final blobRaw = envelope['blob'];
      if (saltRaw is! String || blobRaw is! String) {
        throw DpapiException('密钥文件缺少字段');
      }
      final salt = base64Url.decode(base64Url.normalize(saltRaw));
      final blob = base64Url.decode(base64Url.normalize(blobRaw));
      _salt = salt;
      final plain = dpapi.unprotect(blob, _entropy(salt));
      final data = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
      _applyPlain(data);
      _registerSecrets();
      if (_tokens.isEmpty) await _bootstrapTokens();
      return const VaultLoadResult(ok: true);
    } on DpapiException catch (e) {
      final renamed = await _quarantine();
      _resetSecretState();
      await _bootstrapTokens();
      return VaultLoadResult(
        ok: false,
        renamedTo: renamed,
        message: '本机无法解开之前保存的密钥（${e.message}），已改名保留并重新生成访问令牌',
      );
    } catch (e) {
      final renamed = await _quarantine();
      _resetSecretState();
      await _bootstrapTokens();
      return VaultLoadResult(
        ok: false,
        renamedTo: renamed,
        message: '密钥文件不可用（$e），已改名保留并重新生成访问令牌',
      );
    }
  }

  void _applyPlain(Map<String, Object?> data) {
    final upstream = data['upstream'];
    if (upstream is Map) {
      final key = upstream['apiKey'];
      if (key is String && key.isNotEmpty) {
        _upstreamKey = ApiKey(key);
      }
      _addedAt = DateTime.tryParse((upstream['addedAt'] ?? '').toString());
      _lastVerifiedAt =
          DateTime.tryParse((upstream['lastVerifiedAt'] ?? '').toString());
      _lastVerifyResult = upstream['lastVerifyResult']?.toString();
    }
    final clients = data['clients'];
    if (clients is Map) {
      for (final e in clients.entries) {
        final v = e.value;
        if (v is Map && v['token'] is String) {
          _tokens[e.key.toString()] = ClientToken(
            clientId: e.key.toString(),
            value: v['token'] as String,
            createdAt: DateTime.tryParse((v['createdAt'] ?? '').toString()),
          );
        }
      }
    }
  }

  void _resetSecretState() {
    _upstreamKey = null;
    _addedAt = null;
    _lastVerifiedAt = null;
    _lastVerifyResult = null;
    _tokens.clear();
  }

  Future<String> _quarantine() async {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final names = <String>[];
    for (final file in [_file, _backup]) {
      if (!file.existsSync()) continue;
      final target =
          '${file.path}.unreadable-$stamp';
      try {
        file.renameSync(target);
        names.add(target);
      } catch (_) {}
    }
    return names.join(', ');
  }

  Future<void> _bootstrapTokens() async {
    for (final id in clientIds) {
      _tokens.putIfAbsent(
        id,
        () => ClientToken(
          clientId: id,
          value: generateClientToken(id),
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }
    await save();
  }

  /// 令牌前缀用于辨认与日志脱敏，不参与鉴权。
  static String generateClientToken(String clientId) {
    final prefix = switch (clientId) {
      'sillytavern' => 'egw_st_',
      'pockettavern' => 'egw_pt_',
      _ => 'egw_x_',
    };
    return '$prefix${randomToken()}';
  }

  static String randomToken({int bytes = 32}) {
    final r = Random.secure();
    final data = List<int>.generate(bytes, (_) => r.nextInt(256));
    return base64Url.encode(data).replaceAll('=', '');
  }

  Future<void> setUpstreamKey(String key, {required String verifyResult}) async {
    _upstreamKey = ApiKey(key.trim());
    _addedAt = DateTime.now().toUtc();
    _lastVerifiedAt = DateTime.now().toUtc();
    _lastVerifyResult = verifyResult;
    _registerSecrets();
    await save();
  }

  Future<void> deleteUpstreamKey() async {
    _upstreamKey = null;
    _addedAt = null;
    _lastVerifiedAt = null;
    _lastVerifyResult = null;
    await save();
  }

  Future<ClientToken> rotateToken(String clientId) async {
    final token = ClientToken(
      clientId: clientId,
      value: generateClientToken(clientId),
      createdAt: DateTime.now().toUtc(),
    );
    _tokens[clientId] = token;
    _registerSecrets();
    await save();
    return token;
  }

  void _registerSecrets() {
    redactor.clear();
    final key = _upstreamKey;
    if (key != null) redactor.register(key.value, 'REDACTED:upstream_key');
    for (final t in _tokens.values) {
      redactor.register(t.value, 'REDACTED:client_token');
    }
  }

  Uint8List _entropy(Uint8List salt) {
    final prefix = utf8.encode(_entropyPrefix);
    final out = Uint8List(prefix.length + salt.length);
    out.setAll(0, prefix);
    out.setAll(prefix.length, salt);
    return out;
  }

  Future<void> save() async {
    if (!directory.existsSync()) directory.createSync(recursive: true);
    _salt ??= Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    final salt = _salt!;
    final plain = utf8.encode(jsonEncode({
      'upstream': {
        'apiKey': _upstreamKey?.value,
        'addedAt': _addedAt?.toUtc().toIso8601String(),
        'lastVerifiedAt': _lastVerifiedAt?.toUtc().toIso8601String(),
        'lastVerifyResult': _lastVerifyResult,
      },
      'clients': {
        for (final e in _tokens.entries)
          e.key: {
            'token': e.value.value,
            'createdAt': e.value.createdAt?.toUtc().toIso8601String(),
          },
      },
    }));
    final blob = dpapi.protect(Uint8List.fromList(plain), _entropy(salt));
    final envelope = jsonEncode({
      'format': _format,
      'version': _version,
      'protection': 'dpapi-user',
      'salt': base64Url.encode(salt).replaceAll('=', ''),
      'blob': base64Url.encode(blob).replaceAll('=', ''),
    });

    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(envelope, flush: true);
    if (_file.existsSync()) {
      try {
        if (_backup.existsSync()) _backup.deleteSync();
        _file.renameSync(_backup.path);
      } catch (_) {
        try {
          _file.deleteSync();
        } catch (_) {}
      }
    }
    try {
      tmp.renameSync(_file.path);
    } catch (_) {
      if (_file.existsSync()) _file.deleteSync();
      tmp.renameSync(_file.path);
    }
  }

  /// 界面与诊断用：绝不返回明文。
  Map<String, Object?> describe() => {
        'configured': upstreamKey != null,
        'source': upstreamSource,
        'masked': upstreamKey?.masked,
        'addedAt': addedAt,
        'lastVerifiedAt': lastVerifiedAt,
        'lastVerifyResult': lastVerifyResult,
        'clients': {
          for (final e in _tokens.entries)
            e.key: {
              'masked': e.value.masked,
              'createdAt': e.value.createdAt?.toUtc().toIso8601String(),
            },
        },
      };
}
