/// 应用控制器：启动编排、状态机、控制台宿主实现与退出。
///
/// 规则来源：桌面文档 §4、§5、§9、§11。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../adapters/transport.dart';
import '../console/server.dart';
import '../core/classify.dart';
import '../core/config.dart';
import '../core/router_engine.dart';
import '../http/gateway_server.dart';
import '../core/telemetry.dart';
import '../desktop/browser_launcher.dart';
import '../observe/observability.dart';
import '../quota/quota.dart';
import '../secrets/dpapi.dart';
import '../secrets/vault.dart';
import 'app_env.dart';

class AppOptions {
  const AppOptions({
    this.minimized = false,
    this.console = false,
    this.dataDirOverride,
    this.versionOut,
    this.versionOnly = false,
    this.openWindow = true,
  });

  final bool minimized;
  final bool console;
  final String? dataDirOverride;
  final String? versionOut;
  final bool versionOnly;
  final bool openWindow;
}

class AppController implements ConsoleHost {
  AppController({required this.version, this.buildCommit = 'dev'});

  @override
  final String version;
  final String buildCommit;

  late DataDir dataDir;
  late ConfigStore configStore;
  late Redactor redactor;
  late Logger logger;
  late RequestLog requestLog;
  late EventBus bus;
  late SecretVault vault;
  late QuotaManager quota;
  late DartIoTransport transport;
  late RouterEngine engine;
  late GatewayServer gateway;
  late ConsoleServer console;
  late BrowserLauncher browser;
  late RouterConfig config;

  SingleInstance? _instance;
  bool _configError = false;
  bool _portError = false;
  bool _degraded = false;
  bool _stopping = false;
  String? _configErrorMessage;
  String? _portErrorMessage;
  UpstreamCheck? _lastCheck;
  final Map<String, Map<String, Object?>> _inflight = {};
  final Map<String, Map<String, Object?>> _lastSeen = {};
  final Completer<int> _exitCode = Completer<int>();
  String _ipcNonce = '';

  Future<int> get exitCode => _exitCode.future;

  // ---------------------------------------------------------------- 启动

  Future<int> start(AppOptions options) async {
    dataDir = DataDir.resolve(
      override: options.dataDirOverride,
      executablePath: Platform.resolvedExecutable,
    );
    dataDir.ensure();

    _instance = SingleInstance.acquire(dataDir);
    if (_instance == null) {
      await SingleInstance.notifyExisting(dataDir);
      return 2;
    }

    redactor = Redactor();
    bus = EventBus();
    logger = Logger(
      directory: dataDir.logs,
      redactor: redactor,
      debugEnabled: options.console,
      onLog: (level, line) {
        // INFO 及以上推给控制台（诊断页实时刷新用）；debug 只落盘。
        if (level.index >= LogLevel.info.index) {
          bus.emit('log', {
            'level': level.name,
            'message': line,
            'at': DateTime.now().toUtc().toIso8601String(),
          });
        }
      },
    );
    await logger.init();
    bus = EventBus();
    vault = SecretVault(
      directory: dataDir.root,
      dpapi: defaultDpapi(),
      clientIds: const ['sillytavern', 'pockettavern'],
      redactor: redactor,
    );

    final vaultResult = await vault.load();
    if (!vaultResult.ok) {
      logger.warn(vaultResult.message ?? '密钥库不可用', tag: 'vault');
    }

    configStore = ConfigStore(dataDir);
    try {
      config = configStore.load();
    } on ConfigException catch (e) {
      _configError = true;
      _configErrorMessage = e.messages.join('；');
      final recovered = configStore.tryRecover();
      if (recovered != null) {
        config = recovered;
        logger.warn('配置无效，已用备份继续：$_configErrorMessage', tag: 'config');
      } else {
        config = defaultConfig();
        logger.error('配置无效且没有备份，使用默认配置：$_configErrorMessage',
            tag: 'config');
      }
    } catch (e) {
      _configError = true;
      _configErrorMessage = e.toString();
      config = defaultConfig();
    }

    requestLog = RequestLog(
      directory: dataDir.logs,
      capacity: config.console.requestLogMemory,
      redactor: redactor,
      retentionDays: config.logging.retentionDays,
    );

    quota = QuotaManager(config: () => config, store: _FileStateStore(dataDir));
    await quota.load();

    _rebuildCore();

    // ---- 控制台服务（只绑回环，随机端口）----
    console = ConsoleServer(host: this, backendLimitList: const []);
    _ipcNonce = _randomHex(32);
    console.ipcNonce = _ipcNonce;
    await console.start();

    // ---- 网关服务 ----
    gateway = GatewayServer(
      config: () => config,
      engine: () => engine,
      quota: quota,
      tokens: _VaultTokenDirectory(vault),
      appStatus: appStatus,
      upstreamConfigured: () => vault.hasUpstreamKey,
      onSummary: _onSummary,
      onEvent: _onEvent,
      onAttempt: _onAttempt,
      onAccess: (status, code, detail) {
        logger.info('$code $status $detail', tag: 'gateway-access');
        bus.emit('log', {
          'level': 'info',
          'message': 'gateway-access: $code $status $detail',
          'at': DateTime.now().toUtc().toIso8601String(),
        });
      },
      appVersion: version,
    );
    await _startGateway();

    SingleInstance.writeInstance(
      dataDir,
      InstanceInfo(
        pid: pid,
        consolePort: console.port,
        ipcNonce: _ipcNonce,
        startedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );

    browser = BrowserLauncher(
      userDataDir: dataDir.webview,
      preferred: config.desktop.browser,
    );

    // 后台连通性检查（不生成）。
    if (vault.hasUpstreamKey) {
      unawaited(_backgroundCheck());
    }

    if (options.openWindow && config.desktop.openWindowOnStart) {
      unawaited(openWindow());
    }

    final proxySpec = effectiveProxySpec(config.upstream.proxy);
    logger.info(
      'eatgemini $version 已启动 · 网关 ${gatewayBaseUrl} · 控制台 127.0.0.1:${console.port} · '
      '代理 ${proxySpec == null ? '直连' : proxySpec}',
      tag: 'app',
    );
    bus.emit('app.state', {'state': appStatus().state, 'reason': appStatus().reason});

    return _exitCode.future;
  }

  Future<void> _startGateway() async {
    try {
      await gatewayStart();
      _portError = false;
      _portErrorMessage = null;
    } on SocketException catch (e) {
      _portError = true;
      _portErrorMessage =
          '端口 ${config.listen.port} 被占用或无法监听（${e.osError?.message ?? e.message}），'
          '请在「接入」页换一个端口';
      logger.error(_portErrorMessage!, tag: 'gateway');
    }
  }

  Future<void> gatewayStart() async {
    await gateway.stop();
    await gateway.start(config.listen);
  }

  void _rebuildCore() {
    transport = DartIoTransport(
      config: () => config,
      egress: AllowlistEgress(allowedHosts: {_upstreamUri().host.toLowerCase()}),
    );
    engine = RouterEngine(
      config: () => config,
      transport: transport,
      quota: quota,
      upstreamApiKey: () => vault.upstreamKey?.value ?? '',
    );
    // GatewayServer 只在 start() 创建一次：它的引用全是 getter，
    // 热加载只换 transport/engine。重建它会导致旧 HttpServer 泄漏
    // （实测：改端口后 8787/8789 同时监听）。
  }

  Uri _upstreamUri() => Uri.parse(config.upstream.baseUrl);

  Future<void> _backgroundCheck() async {
    final result = await _checkUpstream(silent: true);
    _degraded = !result.ok;
    bus.emit('app.state', {'state': appStatus().state, 'reason': appStatus().reason});
  }

  String _randomHex(int bytes) {
    final r = Random.secure();
    return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // ---------------------------------------------------------------- 状态

  AppStatus appStatus() {
    if (_stopping) return const AppStatus('stopping');
    if (_configError) return AppStatus('config_error', _configErrorMessage);
    if (_portError) return AppStatus('port_conflict', _portErrorMessage);
    if (quota.persistError != null) {
      return AppStatus('persist_error', quota.persistError);
    }
    if (!vault.hasUpstreamKey) {
      return const AppStatus('needs_key', '还没有配置 Google API Key');
    }
    if (_degraded) {
      return const AppStatus('degraded', '最近一次上游连通性检查失败');
    }
    return const AppStatus('ready');
  }

  @override
  Map<String, Object?> snapshot() {
    final now = DateTime.now().toUtc();
    final quotaSnap = quota.snapshot(now);
    final profiles = <Map<String, Object?>>[];
    for (final entry in config.profiles.entries) {
      profiles.add(_profileSnapshot(entry.key, entry.value, now));
    }
    final models = _modelsSnapshot(now);
    return {
      'app': {
        'state': appStatus().state,
        'reason': appStatus().reason,
        'version': version,
        'startedAt': now.toIso8601String(),
      },
      'gateway': {
        'listenMode': config.listen.mode.name,
        'addresses': _gatewayAddresses(),
        'port': config.listen.port,
      },
      'upstream': {
        'configured': vault.hasUpstreamKey,
        if (_lastCheck != null) 'lastCheck': _lastCheck!.toJson(),
      },
      'quotaDay': {
        'day': quotaSnap['quotaDay'],
        'nextResetAt': quotaSnap['nextResetAt'],
        'timezone': config.resetTimezone,
      },
      'today': _todayStats(),
      'profiles': profiles,
      'inFlight': _inflight.values.toList(),
      'recentRequests': requestLog.entries.take(10).toList(),
      'models': models['models'],
    };
  }

  Map<String, Object?> _todayStats() {
    final items = requestLog.entries;
    var succeeded = 0;
    var failed = 0;
    var attempts = 0;
    for (final r in items) {
      switch (r['outcome']) {
        case 'succeeded':
          succeeded++;
        case 'failed_before_commit' || 'failed_after_commit':
          failed++;
      }
      attempts += (r['attempts'] as num?)?.toInt() ?? 0;
    }
    return {
      'requests': items.length,
      'succeeded': succeeded,
      'failed': failed,
      'upstreamAttempts': attempts,
      'fellBack': items.where((r) => r['fellBack'] == true).length,
      'uncertainAttempts': 0,
    };
  }

  Map<String, Object?> _profileSnapshot(
    String id,
    List<String> modelIds,
    DateTime now,
  ) {
    int? retryAtMs;
    var available = 0;
    String? next;
    for (final modelId in modelIds) {
      final skip = quota.check(modelId, 0, now);
      if (skip == null) {
        available++;
        next ??= modelId;
      } else if (skip.blockedUntilMs != null) {
        final until = skip.blockedUntilMs!;
        if (retryAtMs == null || until < retryAtMs) retryAtMs = until;
      }
    }
    final state = !vault.hasUpstreamKey
        ? 'unavailable'
        : available > 0
            ? 'available'
            : 'limited';
    return {
      'id': id,
      'state': state,
      'nextModel': next,
      'availableModels': available,
      'totalModels': modelIds.length,
      'retryAt': retryAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(retryAtMs, isUtc: true)
              .toIso8601String(),
    };
  }

  Map<String, Object?> _modelsSnapshot(DateTime now) {
    final quotaSnap = quota.snapshot(now);
    final buckets = (quotaSnap['buckets'] as Map).cast<String, Object?>();
    final rows = <Map<String, Object?>>[];
    for (final entry in config.models.entries) {
      final id = entry.key;
      final spec = entry.value;
      final rpdGroup = spec.quotaGroups[QuotaDimension.rpd];
      final rpmGroup = spec.quotaGroups[QuotaDimension.rpm];
      final bucket = rpdGroup == null ? null : buckets['$rpdGroup:rpd'];
      final rpmBucket = rpmGroup == null ? null : buckets['$rpmGroup:rpm'];
      final bucketMap = bucket is Map
          ? bucket.cast<String, Object?>()
          : const <String, Object?>{};
      final rpmMap = rpmBucket is Map
          ? rpmBucket.cast<String, Object?>()
          : const <String, Object?>{};
      final skip = quota.check(id, 0, now);
      final profiles = <String>[
        for (final p in config.profiles.entries)
          if (p.value.contains(id)) p.key,
      ];
      final blockedUntil = bucketMap['blockedUntil'];
      final confirmed = bucketMap['confirmed'] == true;
      rows.add({
        'id': id,
        'enabled': spec.enabled,
        'profiles': profiles,
        'inputTokenLimit': spec.inputTokenLimit,
        'outputTokenLimit': spec.outputTokenLimit,
        'state': skip == null
            ? (spec.enabled ? 'available' : 'blocked')
            : switch (skip.reason) {
                'daily_suspected' || 'confirmed_blocked' => 'exhausted',
                'quota_unavailable' => 'unavailable',
                'model_blocked' || 'model_disabled' => 'blocked',
                _ => 'cooldown',
              },
        'blockedUntil': blockedUntil,
        'confirmed': confirmed,
        'bucketId': rpdGroup == null ? '' : '$rpdGroup:rpd',
        'rpd': {
          'used': bucketMap['localAttempts'] ?? 0,
          'limit': rpdGroup == null ? null : config.quotaGroups[rpdGroup]?.rpd,
        },
        'rpmUsed': rpmMap['minuteUsed'] ?? 0,
        'rpmLimit': rpmGroup == null ? null : config.quotaGroups[rpmGroup]?.rpm,
        'notes': skip?.detail,
      });
    }
    return {'models': rows, 'quota': quotaSnap};
  }

  @override
  Map<String, Object?> modelsState() => _modelsSnapshot(DateTime.now().toUtc());

  /// 配置端口为 0（测试用随机端口）时显示实际绑定端口。
  int get _effectivePort {
    try {
      return gateway.boundPort ?? config.listen.port;
    } catch (_) {
      return config.listen.port;
    }
  }

  List<String> _gatewayAddresses() {
    final port = _effectivePort;
    if (config.listen.mode == ListenMode.loopback) {
      return ['http://127.0.0.1:$port/v1'];
    }
    final addresses = <String>['http://127.0.0.1:$port/v1'];
    for (final ip in lanAddresses) {
      addresses.add('http://$ip:$port/v1');
    }
    return addresses;
  }

  @override
  String get gatewayBaseUrl => _gatewayAddresses().first;

  @override
  bool get isLanMode => config.listen.mode == ListenMode.lan;

  @override
  List<String> get lanAddresses {
    // 同步接口：启动时刷新一次，配置切换时再刷新。
    return _lanCache;
  }

  List<String> _lanCache = const [];

  Future<void> refreshLanAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.address.startsWith('169.254.')) continue;
          addresses.add(addr.address);
        }
      }
      _lanCache = addresses;
    } catch (_) {
      _lanCache = const [];
    }
  }

  // ---------------------------------------------------------------- 事件

  void _onEvent(String event, Map<String, Object?> data) {
    switch (event) {
      case 'request.started':
        _inflight[data['requestId'].toString()] = {
          'requestId': data['requestId'],
          'client': data['client'],
          'profile': null,
          'model': null,
          'phase': 'sending',
          'startedAt': data['startedAt'],
          'elapsedMs': 0,
        };
      case 'request.finished':
        _inflight.remove(data['requestId'].toString());
      case 'log':
        break;
      default:
        break;
    }
    bus.emit(event, data);
  }

  void _onAttempt(AttemptEvent event) {
    final entry = _inflight[event.requestId];
    if (entry != null) {
      entry['model'] = event.model;
      entry['phase'] = event.phase;
      final startedAt =
          DateTime.tryParse(entry['startedAt']?.toString() ?? '');
      if (startedAt != null) {
        entry['elapsedMs'] =
            DateTime.now().toUtc().difference(startedAt).inMilliseconds;
      }
    }
    final data = event.toJson();
    requestLog.noteAttempt(event.requestId, data);
    bus.emit('request.attempt', data);
  }

  void _onSummary(RequestSummary summary) {
    requestLog.add(summary);
    final client = summary.clientId;
    _lastSeen[client] = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'ip': summary.remoteIp ?? '',
    };
    logger.info(
      '${summary.requestId} ${summary.clientId} ${summary.requestedModel} '
      '→ ${summary.servedModel ?? '-'} ${summary.outcome} '
      '${summary.httpStatus} attempts=${summary.upstreamAttempts} '
      '${summary.totalMs}ms',
      tag: 'gateway',
    );
  }

  // ---------------------------------------------------------------- 控制台：查询

  @override
  Stream<(String, Map<String, Object?>)> events() => bus.stream;

  @override
  Map<String, Object?> requests({
    String? client,
    String? outcome,
    String? model,
    int limit = 100,
    int? beforeMs,
  }) {
    var items = requestLog.entries;
    if (client != null && client.isNotEmpty) {
      items = items.where((r) => r['client'] == client).toList();
    }
    if (outcome != null && outcome.isNotEmpty) {
      items = items.where((r) => r['outcome'] == outcome).toList();
    }
    if (model != null && model.isNotEmpty) {
      items = items
          .where((r) => r['servedModel'] == model || r['requestedModel'] == model)
          .toList();
    }
    if (beforeMs != null) {
      items = items
          .where((r) => DateTime.tryParse(r['startedAt'].toString())
                      ?.millisecondsSinceEpoch !=
                  null &&
              DateTime.parse(r['startedAt'].toString())
                      .millisecondsSinceEpoch <
                  beforeMs)
          .toList();
    }
    return {
      'items': items.take(limit).toList(),
      'total': items.length,
    };
  }

  @override
  Map<String, Object?>? requestById(String requestId) =>
      requestLog.byId(requestId);

  @override
  Map<String, Object?> connectInfo() {
    final st = vault.tokenFor('sillytavern');
    final pt = vault.tokenFor('pockettavern');
    final port = _effectivePort;
    final urls = <String>[
      if (config.listen.mode == ListenMode.lan)
        for (final ip in lanAddresses) 'http://$ip:$port/v1',
      'http://10.0.2.2:$port/v1',
    ];
    return {
      'listenMode': config.listen.mode.name,
      'port': port,
      'sillytavern': {
        'endpoint': 'http://127.0.0.1:$port/v1',
        'tokenMasked': st?.masked ?? '—',
      },
      'pockettavern': {
        'urls': urls,
        'tokenMasked': pt?.masked ?? '—',
      },
      'lastSeen': _lastSeen,
    };
  }

  @override
  String revealToken(String clientId) => vault.tokenFor(clientId)?.value ?? '';

  @override
  Future<Map<String, Object?>> rotateToken(String clientId) async {
    final token = await vault.rotateToken(clientId);
    _rebuildCore();
    bus.emit('secrets.changed', {'rotatedClient': clientId});
    return {'ok': true, 'masked': token.masked};
  }

  @override
  String pockettavernConnectCode() {
    final token = vault.tokenFor('pockettavern');
    final port = _effectivePort;
    final urls = <String>[
      if (config.listen.mode == ListenMode.lan)
        for (final ip in lanAddresses) 'http://$ip:$port/v1',
      'http://10.0.2.2:$port/v1',
    ];
    final payload = {
      'v': 1,
      'name': 'GEMINI网关',
      'urls': urls,
      'token': token?.value ?? '',
      'model': 'router:chat',
    };
    return 'egw1:${base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}';
  }

  @override
  Map<String, Object?> secretsInfo() => vault.describe();

  @override
  Future<Map<String, Object?>> verifyUpstreamKey(String key) async {
    if (key.trim().isEmpty) {
      return {'ok': false, 'message': '请先填写 Key'};
    }
    final result = await _callModels(key.trim());
    return {
      'ok': result.ok,
      'fatal': result.fatal,
      'message': result.message,
      if (result.models != null) 'models': result.models,
    };
  }

  @override
  Future<Map<String, Object?>> saveUpstreamKey(
    String key, {
    required bool sameProject,
    String? projectRef,
  }) async {
    final verify = await _callModels(key.trim());
    if (verify.fatal) {
      throw StateError(verify.message);
    }
    if (!sameProject && projectRef != null && projectRef.trim().isNotEmpty) {
      config = config.copyWith(projectRef: projectRef.trim());
      configStore.write(config);
      await quarantineStateForNewProject();
    }
    await vault.setUpstreamKey(
      key.trim(),
      verifyResult: verify.ok ? 'ok' : 'unverified',
    );
    _degraded = !verify.ok;
    _rebuildCore();
    bus.emit('secrets.changed', {'upstreamConfigured': true});
    bus.emit('app.state', {
      'state': appStatus().state,
      'reason': appStatus().reason,
    });
    return {
      'ok': true,
      'message': verify.ok ? '验证通过，已保存' : '${verify.message}；已保存',
    };
  }

  Future<void> quarantineStateForNewProject() async {
    try {
      final stateFile = File(
        '${dataDir.state.path}${Platform.pathSeparator}router-state.json',
      );
      if (stateFile.existsSync()) {
        stateFile.renameSync(
          '${stateFile.path}.old-${DateTime.now().millisecondsSinceEpoch}',
        );
      }
      await quota.load();
    } catch (_) {}
  }

  @override
  Future<void> deleteUpstreamKey() async {
    await vault.deleteUpstreamKey();
    _rebuildCore();
    bus.emit('secrets.changed', {'upstreamConfigured': false});
    bus.emit('app.state', {
      'state': appStatus().state,
      'reason': appStatus().reason,
    });
  }

  @override
  Map<String, Object?> readConfig() => {
        'revision': configStore.revision,
        'config': config.toJson(),
      };

  @override
  Future<Map<String, Object?>> writeConfig(
    int revision,
    Map<String, Object?> json,
  ) async {
    if (revision != 0 && revision != configStore.revision) {
      throw StateError('配置已在其他窗口修改，请刷新后重试');
    }
    final previousListen = config.listen;
    final next = decodeConfig(json);
    configStore.write(next);
    config = next;
    _rebuildCore();
    if (previousListen.mode != next.listen.mode ||
        previousListen.port != next.listen.port ||
        previousListen.bindAddress != next.listen.bindAddress) {
      await _startGateway();
    }
    bus.emit('config.changed', {'revision': configStore.revision});
    bus.emit('app.state', {
      'state': appStatus().state,
      'reason': appStatus().reason,
    });
    return {'ok': true, 'revision': configStore.revision, 'config': next.toJson()};
  }

  @override
  Future<Map<String, Object?>> reloadConfig() async {
    final next = configStore.load();
    config = next;
    _configError = false;
    _rebuildCore();
    await _startGateway();
    bus.emit('config.changed', {'revision': configStore.revision});
    return {'ok': true, 'revision': configStore.revision};
  }

  @override
  Future<void> resetConfig() async {
    configStore.restoreDefaults();
    config = configStore.load();
    _configError = false;
    _rebuildCore();
    await _startGateway();
    bus.emit('config.changed', {'revision': configStore.revision});
  }

  @override
  Future<void> setModelEnabled(String modelId, bool enabled) async {
    final spec = config.models[modelId];
    if (spec == null) throw StateError('未知模型 $modelId');
    final models = Map<String, ModelSpec>.from(config.models);
    models[modelId] = ModelSpec(
      enabled: enabled,
      quotaGroups: spec.quotaGroups,
      inputTokenLimit: spec.inputTokenLimit,
      outputTokenLimit: spec.outputTokenLimit,
      capabilities: spec.capabilities,
      stripParams: spec.stripParams,
      reasoningEfforts: spec.reasoningEfforts,
    );
    final next = config.copyWith(models: models);
    configStore.write(next);
    config = next;
    _rebuildCore();
    bus.emit('config.changed', {'revision': configStore.revision});
  }

  @override
  bool clearLocalEstimate(String bucketId) {
    final ok = quota.clearLocalEstimate(bucketId);
    if (ok) bus.emit('bucket.changed', {'bucketId': bucketId});
    return ok;
  }

  @override
  Future<Map<String, Object?>> refreshModels() async {
    final key = vault.upstreamKey;
    if (key == null) {
      throw StateError('还没有配置 Google API Key');
    }
    final result = await _callModels(key.value);
    if (!result.ok || result.models == null) {
      return {'ok': false, 'summary': result.message};
    }
    final upstream = result.models!.toSet();
    final configured = config.models.keys.toSet();
    final added = upstream.difference(configured);
    final missing = configured.difference(upstream);
    final parts = <String>[];
    if (added.isNotEmpty) parts.add('上游新增 ${added.join('、')}（未自动启用）');
    if (missing.isNotEmpty) parts.add('配置里有但上游未列出 ${missing.join('、')}');
    return {
      'ok': true,
      'summary': parts.isEmpty ? '与配置一致（${upstream.length} 个模型）' : parts.join('；'),
      'upstream': upstream.toList(),
      'added': added.toList(),
      'missing': missing.toList(),
    };
  }

  @override
  Future<Map<String, Object?>> checkUpstream() async {
    final result = await _checkUpstream(silent: false);
    return result.toJson();
  }

  Future<UpstreamCheck> _checkUpstream({required bool silent}) async {
    final key = vault.upstreamKey;
    final started = DateTime.now();
    if (key == null) {
      final check = UpstreamCheck(
        ok: false,
        message: '还没有配置 Google API Key',
        stage: 'key',
        latencyMs: 0,
        at: DateTime.now().toUtc(),
      );
      _lastCheck = check;
      return check;
    }
    final result = await _callModels(key.value);
    final check = UpstreamCheck(
      ok: result.ok,
      message: result.message,
      stage: result.stage,
      latencyMs: DateTime.now().difference(started).inMilliseconds,
      at: DateTime.now().toUtc(),
    );
    _lastCheck = check;
    _degraded = !check.ok && !result.fatal;
    if (!silent) {
      bus.emit('upstream.check', check.toJson());
    }
    return check;
  }

  @override
  Map<String, Object?> diagnostics() => {
        'info': {
          '版本': version,
          '构建': buildCommit,
          '系统': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
          '数据目录': dataDir.root.path,
          '配置版本': config.version,
          '项目标签': config.projectRef,
          '监听': '${config.listen.host}:${config.listen.port}',
          '代理': effectiveProxySpec(config.upstream.proxy) == null
              ? '直连'
              : '${config.upstream.proxy.mode.name} → ${effectiveProxySpec(config.upstream.proxy)}',
          '上游': config.upstream.baseUrl,
          '应用状态': appStatus().state,
          '额度日': quota.snapshot(DateTime.now().toUtc())['quotaDay'],
          '下次重置': quota.snapshot(DateTime.now().toUtc())['nextResetAt'],
          '持久化错误': quota.persistError ?? '无',
        },
        'logs': logger.recent.toList().reversed.take(200).toList(),
        'lastCheck': _lastCheck?.toJson(),
      };

  @override
  Future<String> exportDiagnostics() async {
    if (!dataDir.exports.existsSync()) dataDir.exports.createSync(recursive: true);
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('-', '')
        .split('.')
        .first;
    final file =
        File('${dataDir.exports.path}${Platform.pathSeparator}eatgemini-diag-$stamp.json');
    final data = {
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'diagnostics': diagnostics(),
      'config': config.toJson(),
      'quota': quota.snapshot(DateTime.now().toUtc()),
      'requests': requestLog.entries.take(200).toList(),
    };
    file.writeAsStringSync(redactor.redact(const JsonEncoder.withIndent('  ').convert(data)));
    return file.path;
  }

  @override
  Future<void> openDataDir() async {
    try {
      await Process.start(
        'explorer.exe',
        [dataDir.root.path],
        mode: ProcessStartMode.detached,
      );
    } catch (e) {
      logger.warn('打开数据目录失败：$e', tag: 'app');
    }
  }

  // ---------------------------------------------------------------- 窗口与退出

  @override
  Future<Map<String, Object?>> setListen({String? mode, int? port}) async {
    final nextListen = ListenConfig(
      mode: mode == 'lan' ? ListenMode.lan : (mode == 'loopback' ? ListenMode.loopback : config.listen.mode),
      bindAddress: config.listen.bindAddress,
      port: port ?? config.listen.port,
    );
    final next = config.copyWith(listen: nextListen);
    configStore.write(next);
    config = next;
    _rebuildCore();
    await _startGateway();
    await refreshLanAddresses();
    bus.emit('config.changed', {'revision': configStore.revision});
    return {
      'ok': !_portError,
      'port': config.listen.port,
      'mode': config.listen.mode.name,
      if (_portErrorMessage != null) 'message': _portErrorMessage,
    };
  }

  @override
  Future<void> openWindow() async {
    final result = await browser.open(console.launchUri());
    if (result.message != null) {
      logger.warn(result.message!, tag: 'window');
    }
    logger.info('打开监控窗口（${result.mode}）', tag: 'window');
  }

  @override
  Future<void> requestExit() async {
    await shutdown();
  }

  Future<void> shutdown() async {
    if (_stopping) return;
    _stopping = true;
    bus.emit('app.stopping', {});
    logger.info('正在退出…', tag: 'app');

    // 等待在途请求最多 10 秒。
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (_inflight.isNotEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    await gateway.stop();
    await console.stop();
    await quota.flushNow();
    await logger.close();
    await transport.close();
    SingleInstance.clearInstance(dataDir);
    _instance?.dispose();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

  // ---------------------------------------------------------------- 上游调用

  Future<_ModelsCall> _callModels(String key) async {
    final uri = Uri.parse('${config.upstream.baseUrl}models');
    final client = HttpClient()
      ..connectionTimeout =
          Duration(milliseconds: config.upstream.connectTimeoutMs)
      ..findProxy = _proxyResolver();
    try {
      final req = await client.getUrl(uri);
      req.headers.set('authorization', 'Bearer $key');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decoder
          .bind(resp)
          .join()
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final ids = <String>[];
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map && decoded['data'] is List) {
            for (final item in decoded['data'] as List) {
              if (item is Map && item['id'] != null) {
                ids.add(item['id'].toString());
              }
            }
          }
        } catch (_) {}
        return _ModelsCall(
          ok: true,
          stage: 'ok',
          message: '验证通过（${ids.length} 个模型）',
          models: ids,
        );
      }
      final failure = classifyUpstreamError(
        status: resp.statusCode,
        headers: {
          for (final e in resp.headers.toString().split('\n'))
            if (e.contains(':'))
              e.split(':').first.trim().toLowerCase(): e.substring(e.indexOf(':') + 1).trim()
        },
        body: body,
      );
      final fatal = failure.kind == FailureKind.upstreamAccessError &&
          resp.statusCode == 401;
      return _ModelsCall(
        ok: false,
        fatal: fatal,
        stage: 'http',
        message: switch (resp.statusCode) {
          401 || 400 => 'Key 无效或不可用：${_clip(failure.message)}',
          403 => 'Key 有效但无权限（地区/项目/API 未启用）：${_clip(failure.message)}',
          _ => 'HTTP ${resp.statusCode}：${_clip(failure.message)}',
        },
      );
    } on TimeoutException {
      return const _ModelsCall(
        ok: false,
        stage: 'timeout',
        message: '连不上 Google（超时）。请检查代理设置和网络',
      );
    } on SocketException catch (e) {
      return _ModelsCall(
        ok: false,
        stage: 'connect',
        message: '连不上 Google（${e.message}）。请检查代理设置和网络',
      );
    } on HandshakeException catch (e) {
      return _ModelsCall(
        ok: false,
        stage: 'tls',
        message: 'TLS 握手失败（${e.message}）。如果使用代理，请确认代理支持 HTTPS',
      );
    } catch (e) {
      return _ModelsCall(
        ok: false,
        stage: 'unknown',
        message: '请求上游失败：${_clip(e.toString())}',
      );
    } finally {
      client.close(force: true);
    }
  }

  String Function(Uri) _proxyResolver() =>
      findProxyResolver(config.upstream.proxy);

  static String _clip(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 160 ? '${t.substring(0, 160)}…' : t;
  }

}

class _ModelsCall {
  const _ModelsCall({
    required this.ok,
    required this.message,
    required this.stage,
    this.fatal = false,
    this.models,
  });

  final bool ok;
  final String message;
  final String stage;
  final bool fatal;
  final List<String>? models;
}

class UpstreamCheck {
  const UpstreamCheck({
    required this.ok,
    required this.message,
    required this.stage,
    required this.latencyMs,
    required this.at,
  });

  final bool ok;
  final String message;
  final String stage;
  final int latencyMs;
  final DateTime at;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'message': message,
        'stage': stage,
        'latencyMs': latencyMs,
        'at': at.toUtc().toIso8601String(),
      };
}

class _VaultTokenDirectory implements TokenDirectory {
  _VaultTokenDirectory(this.vault);

  final SecretVault vault;

  @override
  String? clientIdForToken(String token) {
    String? matched;
    for (final entry in vault.tokens.entries) {
      final expected = entry.value.value;
      var diff = expected.length ^ token.length;
      final len = max(expected.length, token.length);
      for (var i = 0; i < len; i++) {
        final a = i < expected.length ? expected.codeUnitAt(i) : 0;
        final b = i < token.length ? token.codeUnitAt(i) : 0;
        diff |= a ^ b;
      }
      if (diff == 0) matched = entry.key;
    }
    return matched;
  }
}

class _FileStateStore implements StateStore {
  _FileStateStore(this.dataDir);

  final DataDir dataDir;

  File get _file =>
      File('${dataDir.state.path}${Platform.pathSeparator}router-state.json');

  @override
  Future<Map<String, Object?>?> read() async {
    if (!_file.existsSync()) return null;
    try {
      return decodeStateOrNull(await _file.readAsString());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(Map<String, Object?> data) async {
    if (!dataDir.state.existsSync()) {
      dataDir.state.createSync(recursive: true);
    }
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(data), flush: true);
    if (_file.existsSync()) {
      try {
        await _file.rename('${_file.path}.bak');
      } catch (_) {}
    }
    try {
      await tmp.rename(_file.path);
    } catch (_) {
      if (_file.existsSync()) _file.deleteSync();
      await tmp.rename(_file.path);
    }
  }
}
