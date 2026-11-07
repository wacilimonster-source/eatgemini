/// 内嵌的前端资源类型。
///
/// `assets.g.dart` 由 `tool/embed_assets.dart` 生成；开发期若未生成，
/// 控制台服务会退回读取磁盘上的 `assets/ui/`。
library;

class EmbeddedAsset {
  const EmbeddedAsset({
    required this.mime,
    required this.bytes,
    required this.etag,
  });

  final String mime;
  final List<int> bytes;
  final String etag;
}
