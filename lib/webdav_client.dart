import 'dart:async';
import 'dart:convert';
import 'dart:io';

class WebDavException implements Exception {
  WebDavException(this.message, [this.status]);
  final String message;
  final int? status;

  @override
  String toString() => message;
}

class WebDavEntry {
  const WebDavEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.size,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final int size;
}

class WebDavClient {
  WebDavClient({
    required String baseUrl,
    required this.username,
    required this.password,
    required String root,
  }) : baseUrl = _normalizeBase(baseUrl),
       root = _normalizeRoot(root);

  final String baseUrl;
  final String username;
  final String password;
  final String root;

  static String _normalizeBase(String value) {
    var url = value.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static String _normalizeRoot(String value) {
    var path = value.trim();
    if (!path.startsWith('/')) path = '/$path';
    while (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    return path == '/' ? '' : path;
  }

  bool get configured => baseUrl.isNotEmpty;

  Uri uriFor(String relative) {
    final segments = relative
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final suffix = segments.isEmpty ? '' : '/$segments';
    return Uri.parse('$baseUrl$root$suffix');
  }

  static String authorization(String username, String password) =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  String get _authorization => authorization(username, password);

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 5);

  String _message(int status) => switch (status) {
    301 || 302 => 'NAS 地址发生跳转，请检查端口或路径',
    401 => '用户名或密码不正确',
    403 => '没有访问该目录的权限',
    404 => '目录或文件不存在',
    405 => 'NAS 不允许该操作',
    423 => '文件被占用，请稍后重试',
    507 => 'NAS 存储空间不足',
    _ => '请求失败（HTTP $status）',
  };

  Future<_Reply> _send(
    String method,
    Uri uri, {
    String? depth,
    List<int>? body,
    Stream<List<int>>? stream,
    int? length,
    void Function(int sent, int total)? onProgress,
  }) async {
    final client = _client();
    try {
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.authorizationHeader, _authorization);
      if (depth != null) request.headers.set('depth', depth);
      if (length != null) request.headers.contentLength = length;
      if (body != null) {
        request.headers.contentType = ContentType(
          'application',
          'octet-stream',
        );
        request.add(body);
      } else if (stream != null) {
        request.headers.contentType = ContentType(
          'application',
          'octet-stream',
        );
        var sent = 0;
        final total = length ?? 0;
        await request.addStream(
          stream.map((chunk) {
            sent += chunk.length;
            onProgress?.call(sent, total);
            return chunk;
          }),
        );
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _Reply(response.statusCode, text);
      }
      throw WebDavException(_message(response.statusCode), response.statusCode);
    } on WebDavException {
      rethrow;
    } on SocketException {
      throw WebDavException('无法连接 NAS，请检查地址、端口和网络');
    } on HandshakeException {
      throw WebDavException('HTTPS 证书校验失败，请改用 HTTP 或检查证书');
    } on TimeoutException {
      throw WebDavException('连接 NAS 超时，请稍后重试');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> test() async {
    if (!configured) throw WebDavException('请先填写 NAS 地址');
    await _send('PROPFIND', uriFor(''), depth: '0');
  }

  Future<List<WebDavEntry>> list(String relative) async {
    final reply = await _send('PROPFIND', uriFor(relative), depth: '1');
    return _parse(reply.body, relative);
  }

  List<WebDavEntry> _parse(String xml, String base) {
    final entries = <WebDavEntry>[];
    final responses = RegExp(
      r'<(?:[A-Za-z0-9]+:)?response\b[^>]*>([\s\S]*?)</(?:[A-Za-z0-9]+:)?response>',
      caseSensitive: false,
    ).allMatches(xml);
    final basePath = _cleanPath(base);
    for (final match in responses) {
      final block = match.group(1) ?? '';
      final href = RegExp(
        r'<(?:[A-Za-z0-9]+:)?href\b[^>]*>([^<]+)</(?:[A-Za-z0-9]+:)?href>',
        caseSensitive: false,
      ).firstMatch(block)?.group(1);
      if (href == null) continue;
      final path = _relative(href.trim());
      if (path == null || path == basePath) continue;
      final name = path.split('/').last;
      if (name.isEmpty || name.startsWith('.')) continue;
      entries.add(
        WebDavEntry(
          path: path,
          name: name,
          isDirectory: RegExp(
            r'<(?:[A-Za-z0-9]+:)?collection\b',
            caseSensitive: false,
          ).hasMatch(block),
          size:
              int.tryParse(
                RegExp(
                      r'<(?:[A-Za-z0-9]+:)?getcontentlength\b[^>]*>(\d+)<',
                      caseSensitive: false,
                    ).firstMatch(block)?.group(1) ??
                    '',
              ) ??
              0,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  String _cleanPath(String value) {
    var path = value;
    if (path.startsWith('http')) {
      path = Uri.tryParse(path)?.path ?? path;
    }
    try {
      path = Uri.decodeComponent(path);
    } catch (_) {}
    if (root.isNotEmpty && path.startsWith(root)) {
      path = path.substring(root.length);
    }
    return path.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
  }

  String? _relative(String href) {
    final path = _cleanPath(href);
    return path.isEmpty ? null : path;
  }

  Future<void> ensureDirectory(String relative) async {
    var current = '';
    for (final segment in relative.split('/')) {
      if (segment.isEmpty) continue;
      current = current.isEmpty ? segment : '$current/$segment';
      try {
        await _send('MKCOL', uriFor(current));
      } on WebDavException catch (error) {
        if (error.status != 405 && error.status != 301 && error.status != 409) {
          rethrow;
        }
      }
    }
  }

  Future<bool> exists(String relative) async {
    try {
      await _send('PROPFIND', uriFor(relative), depth: '0');
      return true;
    } on WebDavException catch (error) {
      if (error.status == 404) return false;
      rethrow;
    }
  }

  Future<void> uploadText(String relative, String content) async {
    final bytes = utf8.encode(content);
    await _send('PUT', uriFor(relative), body: bytes);
  }

  Future<void> uploadFile(
    String relative,
    File file, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final length = await file.length();
    await _send(
      'PUT',
      uriFor(relative),
      stream: file.openRead(),
      length: length,
      onProgress: onProgress,
    );
  }

  String playUrl(String relative) => uriFor(relative).toString();
}

class _Reply {
  const _Reply(this.status, this.body);
  final int status;
  final String body;
}
