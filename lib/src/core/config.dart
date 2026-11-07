/// 路由器配置模型、解析与校验。
///
/// 对应文档：内核文档 §5、桌面文档 §8。
/// 校验规则集中在这里，启动与热加载都调用同一套，避免"界面能存但内核不认"。
library;

import 'dart:convert';
import 'dart:io' show Platform;

/// 配置无效（启动时直接失败；热加载时保留旧快照）。
class ConfigException implements Exception {
  ConfigException(this.messages);

  final List<String> messages;

  @override
  String toString() => messages.join('\n');
}

/// 上游配置。baseUrl 以 `/` 结尾，凭证由外部注入。
class UpstreamConfig {
  const UpstreamConfig({
    required this.baseUrl,
    this.proxy = const ProxyConfig.none(),
    this.connectTimeoutMs = 10000,
    this.firstEventTimeoutMs = 600000,
    this.streamIdleTimeoutMs = 300000,
  });

  final String baseUrl;
  final ProxyConfig proxy;
  final int connectTimeoutMs;
  final int firstEventTimeoutMs;
  final int streamIdleTimeoutMs;

  Map<String, Object?> toJson() => {
        'baseUrl': baseUrl,
        'proxy': proxy.toJson(),
        'connectTimeoutMs': connectTimeoutMs,
        'firstEventTimeoutMs': firstEventTimeoutMs,
        'streamIdleTimeoutMs': streamIdleTimeoutMs,
      };
}

enum ProxyMode { none, environment, manual, system }

class ProxyConfig {
  const ProxyConfig.none()
      : mode = ProxyMode.none,
        host = null,
        port = null;

  const ProxyConfig({
    required this.mode,
    this.host,
    this.port,
  });

  final ProxyMode mode;
  final String? host;
  final int? port;

  /// Dart 的 `findProxy` 接受 `host:port`，不接受 scheme。
  String? get dartProxySpec {
    if (mode != ProxyMode.manual || host == null || port == null) return null;
    return '$host:$port';
  }

  /// 只要填了 host/port 就能用的代理串（manual 之外的回落路径用）。
  String? get hostPortSpec =>
      (host == null || port == null) ? null : '$host:$port';

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
      };
}

enum ListenMode { loopback, lan }

class ListenConfig {
  const ListenConfig({
    this.mode = ListenMode.loopback,
    this.bindAddress,
    this.port = 8787,
  });

  final ListenMode mode;
  final String? bindAddress;
  final int port;

  String get host {
    if (mode == ListenMode.loopback) return '127.0.0.1';
    return bindAddress ?? '0.0.0.0';
  }

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        if (bindAddress != null) 'bindAddress': bindAddress,
        'port': port,
      };
}

class ClientSpec {
  const ClientSpec(
      {required this.compatibility, required this.allowedProfiles});

  final String compatibility;
  final List<String> allowedProfiles;

  Map<String, Object?> toJson() => {
        'compatibility': compatibility,
        'allowedProfiles': allowedProfiles,
      };
}

class AuthConfig {
  const AuthConfig({required this.clients});

  final Map<String, ClientSpec> clients;

  Map<String, Object?> toJson() => {
        'clients': {for (final e in clients.entries) e.key: e.value.toJson()},
      };
}

/// 配额维度。`unknown` 只用于错误分类的内部标记，不进入配置。
enum QuotaDimension { rpm, tpm, rpd }

class QuotaGroup {
  const QuotaGroup({this.rpm, this.tpm, this.rpd});

  /// null = 未知；0 = 无资格。
  final int? rpm;
  final int? tpm;
  final int? rpd;

  int? limitFor(QuotaDimension d) => switch (d) {
        QuotaDimension.rpm => rpm,
        QuotaDimension.tpm => tpm,
        QuotaDimension.rpd => rpd,
      };

  Map<String, Object?> toJson() => {
        if (rpm != null) 'rpm': rpm,
        if (tpm != null) 'tpm': tpm,
        if (rpd != null) 'rpd': rpd,
      };
}

class QuotaSnapshot {
  const QuotaSnapshot({
    required this.observedAt,
    required this.source,
    required this.verified,
  });

  final String observedAt;
  final String source;
  final bool verified;

  Map<String, Object?> toJson() => {
        'observedAt': observedAt,
        'source': source,
        'verified': verified,
      };
}

class ModelSpec {
  const ModelSpec({
    required this.enabled,
    required this.quotaGroups,
    this.inputTokenLimit,
    this.outputTokenLimit,
    this.capabilities = const ['text'],
    this.stripParams = const [],
    this.reasoningEfforts = const [],
  });

  final bool enabled;
  final Map<QuotaDimension, String> quotaGroups;
  final int? inputTokenLimit;
  final int? outputTokenLimit;
  final List<String> capabilities;
  final List<String> stripParams;

  /// 该模型已核验支持的 reasoning_effort 取值；空 = 未知，不发思考参数。
  final List<String> reasoningEfforts;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'quotaGroups': {
          for (final e in quotaGroups.entries) e.key.name: e.value,
        },
        if (inputTokenLimit != null) 'inputTokenLimit': inputTokenLimit,
        if (outputTokenLimit != null) 'outputTokenLimit': outputTokenLimit,
        'capabilities': capabilities,
        'stripParams': stripParams,
        if (reasoningEfforts.isNotEmpty) 'reasoningEfforts': reasoningEfforts,
      };
}

class PolicyConfig {
  const PolicyConfig({
    this.defaultProfile = 'chat',
    this.maxDistinctModels = 6,
    this.maxUpstreamRequests = 8,
    this.maxTransientRetriesPerRequest = 1,
    this.maxParamRepairsPerRequest = 1,
    this.routingDeadlineMs = 60000,
    this.requestDeadlineMs = 0,
    this.maxInFlight = 4,
    this.maxQueueLength = 8,
    this.maxQueueWaitMs = 2000,
    this.unknown429CooldownMs = 60000,
    this.quotaProbeIntervalMs = 300000,
    this.maxRequestBytes = 0,
    this.maxBufferedResponseBytes = 0,
    this.maxInFlightPerClient = 2,
    this.maxQueueLengthPerClient = 4,
  });

  final String defaultProfile;
  final int maxDistinctModels;
  final int maxUpstreamRequests;
  final int maxTransientRetriesPerRequest;
  final int maxParamRepairsPerRequest;
  final int routingDeadlineMs;

  /// 0 表示不限制总生成时长；首事件和流空闲超时仍独立生效。
  final int requestDeadlineMs;
  final int maxInFlight;
  final int maxQueueLength;
  final int maxQueueWaitMs;
  final int unknown429CooldownMs;
  final int quotaProbeIntervalMs;

  /// 字节上限为 0 时不限制大小，不裁剪正文。
  final int maxRequestBytes;
  final int maxBufferedResponseBytes;
  final int maxInFlightPerClient;
  final int maxQueueLengthPerClient;

  Map<String, Object?> toJson() => {
        'defaultProfile': defaultProfile,
        'maxDistinctModels': maxDistinctModels,
        'maxUpstreamRequests': maxUpstreamRequests,
        'maxTransientRetriesPerRequest': maxTransientRetriesPerRequest,
        'maxParamRepairsPerRequest': maxParamRepairsPerRequest,
        'routingDeadlineMs': routingDeadlineMs,
        'requestDeadlineMs': requestDeadlineMs,
        'maxInFlight': maxInFlight,
        'maxQueueLength': maxQueueLength,
        'maxQueueWaitMs': maxQueueWaitMs,
        'unknown429CooldownMs': unknown429CooldownMs,
        'quotaProbeIntervalMs': quotaProbeIntervalMs,
        'maxRequestBytes': maxRequestBytes,
        'maxBufferedResponseBytes': maxBufferedResponseBytes,
        'maxInFlightPerClient': maxInFlightPerClient,
        'maxQueueLengthPerClient': maxQueueLengthPerClient,
      };
}

class LoggingConfig {
  const LoggingConfig({
    this.rawBodies = false,
    this.maxFileBytes = 10485760,
    this.retentionDays = 7,
  });

  final bool rawBodies;
  final int maxFileBytes;
  final int retentionDays;

  Map<String, Object?> toJson() => {
        'rawBodies': rawBodies,
        'maxFileBytes': maxFileBytes,
        'retentionDays': retentionDays,
      };
}

class CompatibilityProfile {
  const CompatibilityProfile({
    this.unknownFields = 'reject',
    this.neutralFields = 'strip_unsupported',
    this.messageTransform = 'none',
    this.defaultMaxOutputTokens = 0,
    this.sseDataFormat = 'single_line_json',
    this.maxChoices = 1,
  });

  final String unknownFields;
  final String neutralFields;
  final String messageTransform;

  /// 0 使用目标模型最大输出额度；额度未知时交由上游默认。
  final int defaultMaxOutputTokens;
  final String sseDataFormat;
  final int maxChoices;

  Map<String, Object?> toJson() => {
        'unknownFields': unknownFields,
        'neutralFields': neutralFields,
        'messageTransform': messageTransform,
        'defaultMaxOutputTokens': defaultMaxOutputTokens,
        'sseDataFormat': sseDataFormat,
        'maxChoices': maxChoices,
      };
}

class DesktopConfig {
  const DesktopConfig({
    this.openWindowOnStart = true,
    this.browser = 'auto',
    this.closeHintShown = false,
    this.autostart = false,
    this.projectLabelWarned = false,
  });

  final bool openWindowOnStart;
  final String browser;
  final bool closeHintShown;
  final bool autostart;
  final bool projectLabelWarned;

  DesktopConfig copyWith({
    bool? openWindowOnStart,
    String? browser,
    bool? closeHintShown,
    bool? autostart,
    bool? projectLabelWarned,
  }) =>
      DesktopConfig(
        openWindowOnStart: openWindowOnStart ?? this.openWindowOnStart,
        browser: browser ?? this.browser,
        closeHintShown: closeHintShown ?? this.closeHintShown,
        autostart: autostart ?? this.autostart,
        projectLabelWarned: projectLabelWarned ?? this.projectLabelWarned,
      );

  Map<String, Object?> toJson() => {
        'openWindowOnStart': openWindowOnStart,
        'browser': browser,
        'closeHintShown': closeHintShown,
        'autostart': autostart,
        'projectLabelWarned': projectLabelWarned,
      };
}

class ConsoleConfig {
  const ConsoleConfig(
      {this.requestLogMemory = 500, this.eventThrottleMs = 250});

  final int requestLogMemory;
  final int eventThrottleMs;

  Map<String, Object?> toJson() => {
        'requestLogMemory': requestLogMemory,
        'eventThrottleMs': eventThrottleMs,
      };
}

/// 完整配置快照。不可变；热加载整体替换。
class RouterConfig {
  const RouterConfig({
    required this.version,
    required this.projectRef,
    required this.quotaSnapshot,
    required this.upstream,
    required this.listen,
    required this.auth,
    required this.profiles,
    required this.models,
    required this.quotaGroups,
    required this.policy,
    required this.logging,
    required this.compatibility,
    required this.desktop,
    required this.console,
    this.resetTimezone = 'America/Los_Angeles',
  });

  final int version;
  final String projectRef;
  final QuotaSnapshot quotaSnapshot;
  final UpstreamConfig upstream;
  final ListenConfig listen;
  final AuthConfig auth;
  final Map<String, List<String>> profiles;
  final Map<String, ModelSpec> models;
  final Map<String, QuotaGroup> quotaGroups;
  final PolicyConfig policy;
  final LoggingConfig logging;
  final Map<String, CompatibilityProfile> compatibility;
  final DesktopConfig desktop;
  final ConsoleConfig console;
  final String resetTimezone;

  RouterConfig copyWith({
    String? projectRef,
    UpstreamConfig? upstream,
    ListenConfig? listen,
    AuthConfig? auth,
    Map<String, List<String>>? profiles,
    Map<String, ModelSpec>? models,
    Map<String, QuotaGroup>? quotaGroups,
    PolicyConfig? policy,
    LoggingConfig? logging,
    Map<String, CompatibilityProfile>? compatibility,
    DesktopConfig? desktop,
    ConsoleConfig? console,
  }) =>
      RouterConfig(
        version: version,
        projectRef: projectRef ?? this.projectRef,
        quotaSnapshot: quotaSnapshot,
        upstream: upstream ?? this.upstream,
        listen: listen ?? this.listen,
        auth: auth ?? this.auth,
        profiles: profiles ?? this.profiles,
        models: models ?? this.models,
        quotaGroups: quotaGroups ?? this.quotaGroups,
        policy: policy ?? this.policy,
        logging: logging ?? this.logging,
        compatibility: compatibility ?? this.compatibility,
        desktop: desktop ?? this.desktop,
        console: console ?? this.console,
        resetTimezone: resetTimezone,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'projectRef': projectRef,
        'quotaSnapshot': quotaSnapshot.toJson(),
        'upstream': upstream.toJson(),
        'listen': listen.toJson(),
        'auth': auth.toJson(),
        'reset': {'timezone': resetTimezone},
        'profiles': profiles,
        'models': {for (final e in models.entries) e.key: e.value.toJson()},
        'quotaGroups': {
          for (final e in quotaGroups.entries) e.key: e.value.toJson(),
        },
        'policy': policy.toJson(),
        'logging': logging.toJson(),
        'compatibility': {
          for (final e in compatibility.entries) e.key: e.value.toJson(),
        },
        'desktop': desktop.toJson(),
        'console': console.toJson(),
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// API 契约版本：桌面文档 §10.1。
const int kApiVersion = 1;

/// 默认配置。六个模型与额度沿用内核文档 §2 的未核验快照。
RouterConfig defaultConfig() {
  const upstreamUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai/';

  const flashLimits = (rpm: 5, tpm: 250000, rpd: 20);
  const lite35 = (rpm: 15, tpm: 250000, rpd: 500);
  const lite31 = (rpm: 15, tpm: 250000, rpd: 500);
  const lite25 = (rpm: 10, tpm: 250000, rpd: 20);

  final models = <String, ModelSpec>{
    'gemini-3.8-flash': const ModelSpec(
      enabled: true,
      quotaGroups: {
        QuotaDimension.rpm: 'flash38',
        QuotaDimension.tpm: 'flash38',
        QuotaDimension.rpd: 'flash38',
      },
      inputTokenLimit: 1048576,
      outputTokenLimit: 65536,
      stripParams: ['temperature', 'top_p', 'top_k'],
      reasoningEfforts: ['low', 'medium', 'high'],
    ),
    'gemini-3.6-flash': const ModelSpec(
      enabled: true,
      quotaGroups: {
        QuotaDimension.rpm: 'flash36',
        QuotaDimension.tpm: 'flash36',
        QuotaDimension.rpd: 'flash36',
      },
      inputTokenLimit: 1048576,
      outputTokenLimit: 65536,
      stripParams: ['temperature', 'top_p', 'top_k'],
      reasoningEfforts: ['low', 'medium', 'high'],
    ),
    'gemini-3-flash-preview': const ModelSpec(
      enabled: true,
      quotaGroups: {
        QuotaDimension.rpm: 'flash3p',
        QuotaDimension.tpm: 'flash3p',
        QuotaDimension.rpd: 'flash3p',
      },
      inputTokenLimit: 1048576,
      outputTokenLimit: 65536,
      stripParams: ['temperature', 'top_p', 'top_k'],
      reasoningEfforts: ['low', 'medium', 'high'],
    ),
    'gemini-3.5-flash-lite': const ModelSpec(
      enabled: true,
      quotaGroups: {
        QuotaDimension.rpm: 'lite35',
        QuotaDimension.tpm: 'lite35',
        QuotaDimension.rpd: 'lite35',
      },
      inputTokenLimit: 1048576,
      outputTokenLimit: 65536,
      reasoningEfforts: ['low', 'high'],
    ),
    'gemini-3.1-flash-lite': const ModelSpec(
      enabled: true,
      quotaGroups: {
        QuotaDimension.rpm: 'lite31',
        QuotaDimension.tpm: 'lite31',
        QuotaDimension.rpd: 'lite31',
      },
      inputTokenLimit: 1048576,
      outputTokenLimit: 65536,
      reasoningEfforts: ['low', 'high'],
    ),
    'gemini-2.5-flash-lite': const ModelSpec(
      enabled: true,
      quotaGroups: {
        QuotaDimension.rpm: 'lite25',
        QuotaDimension.tpm: 'lite25',
        QuotaDimension.rpd: 'lite25',
      },
      inputTokenLimit: 1048576,
      outputTokenLimit: 65536,
      reasoningEfforts: ['low', 'high'],
    ),
  };

  return RouterConfig(
    version: 3,
    projectRef: 'default',
    quotaSnapshot: const QuotaSnapshot(
      observedAt: '2026-11-06',
      source: 'original-design',
      verified: false,
    ),
    upstream: const UpstreamConfig(baseUrl: upstreamUrl),
    listen: const ListenConfig(),
    auth: const AuthConfig(
      clients: {
        'sillytavern': ClientSpec(
          compatibility: 'tavern_text',
          allowedProfiles: ['chat', 'fast', 'quality'],
        ),
        'pockettavern': ClientSpec(
          compatibility: 'tavern_text',
          allowedProfiles: ['chat', 'fast', 'quality'],
        ),
      },
    ),
    profiles: const {
      'chat': [
        'gemini-3.8-flash',
        'gemini-3.6-flash',
        'gemini-3-flash-preview',
        'gemini-3.5-flash-lite',
        'gemini-3.1-flash-lite',
        'gemini-2.5-flash-lite',
      ],
      'fast': [
        'gemini-3.5-flash-lite',
        'gemini-3.1-flash-lite',
        'gemini-2.5-flash-lite',
        'gemini-3.8-flash',
      ],
      'quality': [
        'gemini-3.8-flash',
        'gemini-3.6-flash',
        'gemini-3-flash-preview',
      ],
    },
    models: models,
    quotaGroups: {
      'flash38': QuotaGroup(
        rpm: flashLimits.rpm,
        tpm: flashLimits.tpm,
        rpd: flashLimits.rpd,
      ),
      'flash36': QuotaGroup(
        rpm: flashLimits.rpm,
        tpm: flashLimits.tpm,
        rpd: flashLimits.rpd,
      ),
      'flash3p': QuotaGroup(
        rpm: flashLimits.rpm,
        tpm: flashLimits.tpm,
        rpd: flashLimits.rpd,
      ),
      'lite35': QuotaGroup(rpm: lite35.rpm, tpm: lite35.tpm, rpd: lite35.rpd),
      'lite31': QuotaGroup(rpm: lite31.rpm, tpm: lite31.tpm, rpd: lite31.rpd),
      'lite25': QuotaGroup(rpm: lite25.rpm, tpm: lite25.tpm, rpd: lite25.rpd),
    },
    policy: const PolicyConfig(),
    logging: const LoggingConfig(),
    compatibility: const {
      'tavern_text': CompatibilityProfile(),
    },
    desktop: const DesktopConfig(),
    console: const ConsoleConfig(),
  );
}

/// 从 JSON 解码并校验。
///
/// [strict] 为 true（启动）时任何错误都抛 [ConfigException]；
/// 为 false（界面预览）时仍抛，但调用方可以捕获展示。
RouterConfig parseConfig(String source) {
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    throw ConfigException(['配置文件不是合法 JSON：${e.message}']);
  }
  if (decoded is! Map) {
    throw ConfigException(['配置文件顶层必须是对象']);
  }
  return decodeConfig(decoded.cast<String, Object?>());
}

RouterConfig decodeConfig(Map<String, Object?> json) {
  final errors = <String>[];
  final version = _int(json['version'], 'version', errors, fallback: 3);
  if (version == 2) {
    errors.add('这是 v2 配置（环境变量取密钥）。桌面版需要 v3，请点「恢复默认配置」后重新填写 Key');
  } else if (version != 3) {
    errors.add('不支持的配置版本 $version（需要 3）');
  }

  final projectRef =
      _string(json['projectRef'], 'projectRef', errors, fallback: 'default');

  final snapshot = <String, Object?>{};
  if (json['quotaSnapshot'] is Map) {
    snapshot.addAll((json['quotaSnapshot'] as Map).cast<String, Object?>());
  }
  final quotaSnapshot = QuotaSnapshot(
    observedAt: _string(
        snapshot['observedAt'], 'quotaSnapshot.observedAt', errors,
        fallback: 'unknown'),
    source: _string(snapshot['source'], 'quotaSnapshot.source', errors,
        fallback: 'unknown'),
    verified: snapshot['verified'] == true,
  );

  final upstream = _upstream(json['upstream'], errors);
  final listen = _listen(json['listen'], errors);
  final auth = _auth(json['auth'], errors);

  final profiles = <String, List<String>>{};
  final profilesRaw = json['profiles'];
  if (profilesRaw is Map) {
    for (final e in profilesRaw.entries) {
      final id = e.key.toString();
      final v = e.value;
      if (v is! List || v.isEmpty) {
        errors.add('profiles.$id 必须是非空数组');
        continue;
      }
      profiles[id] =
          v.map((x) => x.toString()).where((s) => s.isNotEmpty).toList();
    }
  } else {
    errors.add('profiles 缺失或不是对象');
  }

  final models = <String, ModelSpec>{};
  final modelsRaw = json['models'];
  if (modelsRaw is Map) {
    for (final e in modelsRaw.entries) {
      final id = e.key.toString();
      if (e.value is! Map) {
        errors.add('models.$id 必须是对象');
        continue;
      }
      final m = (e.value as Map).cast<String, Object?>();
      final groups = <QuotaDimension, String>{};
      final groupsRaw = m['quotaGroups'];
      if (groupsRaw is Map) {
        for (final dim in QuotaDimension.values) {
          final g = groupsRaw[dim.name];
          if (g != null && g.toString().isNotEmpty) {
            groups[dim] = g.toString();
          }
        }
      }
      if (groups.isEmpty) {
        errors.add('models.$id.quotaGroups 至少映射一个维度');
      }
      models[id] = ModelSpec(
        enabled: m['enabled'] != false,
        quotaGroups: groups,
        inputTokenLimit: _nullableInt(m['inputTokenLimit']),
        outputTokenLimit: _nullableInt(m['outputTokenLimit']),
        capabilities: (m['capabilities'] is List)
            ? (m['capabilities'] as List).map((x) => x.toString()).toList()
            : const ['text'],
        stripParams: (m['stripParams'] is List)
            ? (m['stripParams'] as List).map((x) => x.toString()).toList()
            : const [],
        reasoningEfforts: (m['reasoningEfforts'] is List)
            ? (m['reasoningEfforts'] as List).map((x) => x.toString()).toList()
            : const [],
      );
    }
  } else {
    errors.add('models 缺失或不是对象');
  }

  final quotaGroups = <String, QuotaGroup>{};
  final groupsRaw = json['quotaGroups'];
  if (groupsRaw is Map) {
    for (final e in groupsRaw.entries) {
      final id = e.key.toString();
      if (e.value is! Map) {
        errors.add('quotaGroups.$id 必须是对象');
        continue;
      }
      final g = (e.value as Map).cast<String, Object?>();
      final rpm = _nullableInt(g['rpm']);
      final tpm = _nullableInt(g['tpm']);
      final rpd = _nullableInt(g['rpd']);
      for (final pair in [
        ('rpm', rpm),
        ('tpm', tpm),
        ('rpd', rpd),
      ]) {
        if (pair.$2 != null && pair.$2! < 0) {
          errors.add('quotaGroups.$id.${pair.$1} 不能为负数');
        }
      }
      quotaGroups[id] = QuotaGroup(rpm: rpm, tpm: tpm, rpd: rpd);
    }
  } else {
    errors.add('quotaGroups 缺失或不是对象');
  }

  final policy = _policy(json['policy'], errors);
  final logging = _logging(json['logging'], errors);
  final compatibility = <String, CompatibilityProfile>{};
  final compatRaw = json['compatibility'];
  if (compatRaw is Map) {
    for (final e in compatRaw.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final c = v.cast<String, Object?>();
      compatibility[e.key.toString()] = CompatibilityProfile(
        unknownFields: (c['unknownFields'] ?? 'reject').toString(),
        neutralFields: (c['neutralFields'] ?? 'strip_unsupported').toString(),
        messageTransform: (c['messageTransform'] ?? 'none').toString(),
        defaultMaxOutputTokens: _int(
            c['defaultMaxOutputTokens'], 'compatibility.x', errors,
            fallback: 0),
        sseDataFormat: (c['sseDataFormat'] ?? 'single_line_json').toString(),
        maxChoices:
            _int(c['maxChoices'], 'compatibility.x', errors, fallback: 1),
      );
      if (compatibility[e.key]!.defaultMaxOutputTokens < 0) {
        errors.add('compatibility.${e.key}.defaultMaxOutputTokens 不能为负数');
      }
    }
  }
  if (compatibility.isEmpty) {
    compatibility['tavern_text'] = const CompatibilityProfile();
  }

  final desktopR = (json['desktop'] is Map)
      ? (json['desktop'] as Map).cast<String, Object?>()
      : <String, Object?>{};
  final desktop = DesktopConfig(
    openWindowOnStart: desktopR['openWindowOnStart'] != false,
    browser: (desktopR['browser'] ?? 'auto').toString(),
    closeHintShown: desktopR['closeHintShown'] == true,
    autostart: desktopR['autostart'] == true,
    projectLabelWarned: desktopR['projectLabelWarned'] == true,
  );

  final consoleR = (json['console'] is Map)
      ? (json['console'] as Map).cast<String, Object?>()
      : <String, Object?>{};
  final console = ConsoleConfig(
    requestLogMemory: _int(
        consoleR['requestLogMemory'], 'console.requestLogMemory', errors,
        fallback: 500),
    eventThrottleMs: _int(
        consoleR['eventThrottleMs'], 'console.eventThrottleMs', errors,
        fallback: 250),
  );

  final reset = (json['reset'] is Map)
      ? (json['reset'] as Map).cast<String, Object?>()
      : <String, Object?>{};
  final timezone = (reset['timezone'] ?? 'America/Los_Angeles').toString();
  if (timezone != 'America/Los_Angeles') {
    errors.add('reset.timezone 目前只支持 America/Los_Angeles');
  }

  // ---- 交叉校验 ----
  for (final e in profiles.entries) {
    if (e.value.isEmpty) errors.add('profiles.${e.key} 不能为空');
    final seen = <String>{};
    for (final id in e.value) {
      if (!models.containsKey(id)) {
        errors.add('profiles.${e.key} 引用了不存在的模型 $id');
      }
      if (!seen.add(id)) {
        errors.add('profiles.${e.key} 中 $id 重复');
      }
    }
  }
  for (final e in models.entries) {
    for (final g in e.value.quotaGroups.values) {
      if (!quotaGroups.containsKey(g)) {
        errors.add('models.${e.key} 引用了不存在的配额组 $g');
      }
    }
  }
  if (!profiles.containsKey(policy.defaultProfile)) {
    errors.add('policy.defaultProfile 引用了不存在的档位 '
        '${policy.defaultProfile}');
  }
  for (final e in auth.clients.entries) {
    if (!compatibility.containsKey(e.value.compatibility)) {
      errors.add('auth.clients.${e.key}.compatibility 引用了不存在的配置 '
          '${e.value.compatibility}');
    }
    for (final p in e.value.allowedProfiles) {
      if (!profiles.containsKey(p)) {
        errors.add('auth.clients.${e.key}.allowedProfiles 引用了不存在的档位 $p');
      }
    }
    if (e.value.allowedProfiles.isEmpty) {
      errors.add('auth.clients.${e.key}.allowedProfiles 不能为空');
    }
  }
  if (auth.clients.isEmpty) errors.add('auth.clients 至少需要一个客户端');

  if (policy.requestDeadlineMs > 0 &&
      policy.routingDeadlineMs > policy.requestDeadlineMs) {
    errors.add('policy.routingDeadlineMs 不能大于 requestDeadlineMs');
  }
  if (upstream.baseUrl.isEmpty) {
    errors.add('upstream.baseUrl 不能为空');
  } else {
    final uri = Uri.tryParse(upstream.baseUrl);
    final loopback = uri != null &&
        const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host);
    if (uri == null || uri.host.isEmpty) {
      errors.add('upstream.baseUrl 必须是完整地址');
    } else if (!uri.isScheme('https') && !loopback) {
      // 只允许本机回环用 http（调试/本地代理）；其他主机必须 https。
      errors.add('upstream.baseUrl 必须是 https 地址（本机回环除外）');
    } else if (!upstream.baseUrl.endsWith('/')) {
      errors.add('upstream.baseUrl 必须以 / 结尾');
    }
  }
  // 0 = 由系统分配随机端口（测试/冒烟用；界面不提供该选项）。
  if (listen.port < 0 || listen.port > 65535) {
    errors.add('listen.port 必须是 0–65535（0 表示随机端口）');
  }
  if (models.isEmpty) errors.add('models 不能为空');

  final enabledModels =
      models.entries.where((e) => e.value.enabled).map((e) => e.key).toSet();
  if (enabledModels.isEmpty) {
    errors.add('至少需要一个启用的模型');
  } else if (!profiles.values.any((ids) => ids.any(enabledModels.contains))) {
    errors.add('没有档位包含任何启用的模型');
  }

  if (errors.isNotEmpty) throw ConfigException(errors);

  return RouterConfig(
    version: version,
    projectRef: projectRef,
    quotaSnapshot: quotaSnapshot,
    upstream: upstream,
    listen: listen,
    auth: auth,
    profiles: profiles,
    models: models,
    quotaGroups: quotaGroups,
    policy: policy,
    logging: logging,
    compatibility: compatibility,
    desktop: desktop,
    console: console,
    resetTimezone: timezone,
  );
}

UpstreamConfig _upstream(Object? raw, List<String> errors) {
  if (raw is! Map) {
    errors.add('upstream 缺失');
    return const UpstreamConfig(
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/',
    );
  }
  final m = raw.cast<String, Object?>();
  final proxyRaw = m['proxy'];
  ProxyConfig proxy = const ProxyConfig.none();
  if (proxyRaw is Map) {
    final p = proxyRaw.cast<String, Object?>();
    final mode = ProxyMode.values.firstWhere(
      (x) => x.name == p['mode'],
      orElse: () => ProxyMode.none,
    );
    proxy = ProxyConfig(
      mode: mode,
      host: p['host']?.toString(),
      port: _nullableInt(p['port']),
    );
    if (mode == ProxyMode.manual &&
        (proxy.host == null || proxy.port == null)) {
      errors.add('upstream.proxy 手动模式必须填写 host 和 port');
    }
  } else if (proxyRaw is String) {
    // v2 兼容：字符串只允许 environment / none
    proxy = ProxyConfig(
      mode: proxyRaw == 'environment' ? ProxyMode.environment : ProxyMode.none,
    );
  }
  return UpstreamConfig(
    baseUrl: (m['baseUrl'] ?? '').toString(),
    proxy: proxy,
    connectTimeoutMs: _int(
        m['connectTimeoutMs'], 'upstream.connectTimeoutMs', errors,
        fallback: 10000),
    firstEventTimeoutMs: _int(
        m['firstEventTimeoutMs'], 'upstream.firstEventTimeoutMs', errors,
        fallback: 600000),
    streamIdleTimeoutMs: _int(
        m['streamIdleTimeoutMs'], 'upstream.streamIdleTimeoutMs', errors,
        fallback: 300000),
  );
}

ListenConfig _listen(Object? raw, List<String> errors) {
  if (raw is! Map) {
    errors.add('listen 缺失');
    return const ListenConfig();
  }
  final m = raw.cast<String, Object?>();
  final mode = m['mode'] == 'lan' ? ListenMode.lan : ListenMode.loopback;
  return ListenConfig(
    mode: mode,
    bindAddress: m['bindAddress']?.toString(),
    port: _int(m['port'], 'listen.port', errors, fallback: 8787),
  );
}

AuthConfig _auth(Object? raw, List<String> errors) {
  if (raw is! Map) {
    errors.add('auth 缺失');
    return const AuthConfig(clients: {});
  }
  final m = raw.cast<String, Object?>();
  final clientsRaw = m['clients'];
  final clients = <String, ClientSpec>{};
  if (clientsRaw is Map) {
    for (final e in clientsRaw.entries) {
      if (e.value is! Map) {
        errors.add('auth.clients.${e.key} 必须是对象');
        continue;
      }
      final c = (e.value as Map).cast<String, Object?>();
      clients[e.key.toString()] = ClientSpec(
        compatibility: (c['compatibility'] ?? 'tavern_text').toString(),
        allowedProfiles: (c['allowedProfiles'] is List)
            ? (c['allowedProfiles'] as List).map((x) => x.toString()).toList()
            : const [],
      );
    }
  }
  return AuthConfig(clients: clients);
}

PolicyConfig _policy(Object? raw, List<String> errors) {
  final m = (raw is Map) ? raw.cast<String, Object?>() : <String, Object?>{};
  int read(String key, int fallback) =>
      _int(m[key], 'policy.$key', errors, fallback: fallback);

  final p = PolicyConfig(
    defaultProfile: (m['defaultProfile'] ?? 'chat').toString(),
    maxDistinctModels: read('maxDistinctModels', 6),
    maxUpstreamRequests: read('maxUpstreamRequests', 8),
    maxTransientRetriesPerRequest: read('maxTransientRetriesPerRequest', 1),
    maxParamRepairsPerRequest: read('maxParamRepairsPerRequest', 1),
    routingDeadlineMs: read('routingDeadlineMs', 60000),
    requestDeadlineMs: read('requestDeadlineMs', 0),
    maxInFlight: read('maxInFlight', 4),
    maxQueueLength: read('maxQueueLength', 8),
    maxQueueWaitMs: read('maxQueueWaitMs', 2000),
    unknown429CooldownMs: read('unknown429CooldownMs', 60000),
    quotaProbeIntervalMs: read('quotaProbeIntervalMs', 300000),
    maxRequestBytes: read('maxRequestBytes', 0),
    maxBufferedResponseBytes: read('maxBufferedResponseBytes', 0),
    maxInFlightPerClient: read('maxInFlightPerClient', 2),
    maxQueueLengthPerClient: read('maxQueueLengthPerClient', 4),
  );
  for (final pair in [
    ('maxInFlight', p.maxInFlight),
    ('maxUpstreamRequests', p.maxUpstreamRequests),
    ('maxDistinctModels', p.maxDistinctModels),
  ]) {
    if (pair.$2 <= 0) errors.add('policy.${pair.$1} 必须为正数');
  }
  for (final pair in [
    ('maxRequestBytes', p.maxRequestBytes),
    ('maxBufferedResponseBytes', p.maxBufferedResponseBytes),
    ('requestDeadlineMs', p.requestDeadlineMs),
  ]) {
    if (pair.$2 < 0) errors.add('policy.${pair.$1} 不能为负数（0 为不限）');
  }
  return p;
}

LoggingConfig _logging(Object? raw, List<String> errors) {
  final m = (raw is Map) ? raw.cast<String, Object?>() : <String, Object?>{};
  return LoggingConfig(
    rawBodies: m['rawBodies'] == true,
    maxFileBytes: _int(m['maxFileBytes'], 'logging.maxFileBytes', errors,
        fallback: 10485760),
    retentionDays:
        _int(m['retentionDays'], 'logging.retentionDays', errors, fallback: 7),
  );
}

String _string(Object? v, String field, List<String> errors,
    {required String fallback}) {
  if (v == null) {
    errors.add('$field 缺失');
    return fallback;
  }
  return v.toString();
}

int _int(Object? v, String field, List<String> errors,
    {required int fallback}) {
  if (v == null) return fallback;
  if (v is num) return v.toInt();
  final parsed = int.tryParse(v.toString());
  if (parsed == null) {
    errors.add('$field 必须是整数');
    return fallback;
  }
  return parsed;
}

int? _nullableInt(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  final s = v.toString().trim();
  if (s.isEmpty || s == 'null') return null;
  return int.tryParse(s);
}

/// 当前平台是否为 Windows（FFI 相关功能只在 Windows 可用）。
bool get isWindows => Platform.isWindows;
