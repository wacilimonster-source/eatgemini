import 'dart:convert';

import 'package:eatgemini/src/http/sse.dart';
import 'package:test/test.dart';

Stream<List<int>> _chunks(List<String> parts) async* {
  for (final p in parts) {
    yield utf8.encode(p);
  }
}

Future<List<SseEvent>> _collect(Stream<List<int>> stream) =>
    decodeSse(stream).toList();

void main() {
  test('基本 data 帧与 [DONE]', () async {
    final events = await _collect(_chunks([
      'data: {"a":1}\n\n',
      'data: [DONE]\n\n',
    ]));
    expect(events.length, 2);
    expect(events[0].data, '{"a":1}');
    expect(events[1].isDone, isTrue);
  });

  test('CRLF 与单独 CR', () async {
    final events = await _collect(_chunks([
      'data: {"a":1}\r\n\r\n',
      'data: {"b":2}\r\r',
    ]));
    expect(events.map((e) => e.data).toList(), ['{"a":1}', '{"b":2}']);
  });

  test('DONE 前缺空行时先交付残留完成帧', () async {
    final events = await _collect(_chunks([
      'data: {"choices":[{"delta":{"content":"答案"},"finish_reason":"stop"}]}\n',
      'data: [DONE]\n\n',
    ]));
    expect(events, hasLength(2));
    expect(events.first.isDone, isFalse);
    expect(jsonDecode(events.first.data)['choices'][0]['finish_reason'], 'stop');
    expect(events.last.isDone, isTrue);
  });

  test('多行 data 用换行连接', () async {
    final events = await _collect(_chunks([
      'data: {"a":\ndata: 1}\n\n',
    ]));
    expect(events.single.data, '{"a":\n1}');
  });

  test('注释与 event/id 字段被忽略', () async {
    final events = await _collect(_chunks([
      ': ping\n\n',
      'event: message\nid: 1\ndata: {"a":1}\n\n',
    ]));
    expect(events.single.data, '{"a":1}');
  });

  test('UTF-8 跨包不破坏中文', () async {
    final payload = 'data: {"t":"中文"}\n\n';
    final bytes = utf8.encode(payload);
    // 在中文中间切开
    final cut = payload.indexOf('中');
    expect(cut, greaterThan(0));
    final events = await _collect(Stream.fromIterable([
      bytes.sublist(0, cut + 1),
      bytes.sublist(cut + 1),
    ]));
    expect(jsonDecode(events.single.data)['t'], '中文');
  });

  test('data: 后不带空格也能解析', () async {
    final events = await _collect(_chunks(['data:{"a":1}\n\n']));
    expect(events.single.data, '{"a":1}');
  });

  test('EOF 前没有空行也会交付残留数据', () async {
    final events = await _collect(_chunks(['data: {"a":1}\n']));
    expect(events.single.data, '{"a":1}');
  });

  test('超大单事件抛协议异常', () async {
    final big = 'x' * (2 * 1024 * 1024);
    expect(
      () => decodeSse(_chunks(['data: $big\n\n']), maxEventBytes: 1024 * 1024)
          .toList(),
      throwsA(isA<SseProtocolException>()),
    );
  });

  test('默认不限制单个 SSE 事件的大小', () async {
    final big = 'x' * (2 * 1024 * 1024);
    final events = await _collect(_chunks(['data: $big\n\n']));
    expect(events.single.data, big);
  });

  test('下游编码是一行紧凑 JSON', () {
    final encoded = encodeDownstreamData({'a': 1, 'b': '中文'});
    expect(encoded.startsWith('data: {'), isTrue);
    expect(encoded.endsWith('\n\n'), isTrue);
    expect(encoded.split('\n').length, 3);
    expect(kDownstreamDone, 'data: [DONE]\n\n');
  });
}
