import 'dart:convert';
import 'dart:io';

import 'core_bridge.dart';
import 'local_store.dart';

/// TV 端临时 HTTP 配置页：手机在同一局域网打开后填写 NAS 参数。
class NasConfigServer {
  NasConfigServer({required this.store, required this.repository});

  final LocalStore store;
  final AppRepository repository;

  static const port = 8899;
  HttpServer? _server;

  bool get running => _server != null;

  Future<String> start() async {
    await stop();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(_handle);
    return 'http://${await localIp()}:$port';
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  static Future<String> localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/') {
        await _page(request, _form());
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/save') {
        final body = await utf8.decoder.bind(request).join();
        final form = Uri.splitQueryString(body);
        final url = (form['url'] ?? '').trim();
        final user = (form['user'] ?? '').trim();
        final password = form['password'] ?? '';
        final root = (form['root'] ?? '').trim();
        if (url.isEmpty || user.isEmpty) {
          await _page(request, _form(message: '地址和用户名不能为空'));
          return;
        }
        await store.setNasConfig(
          url: url,
          user: user,
          password: password,
          root: root,
        );
        await repository.setNasConfig(
          url: url,
          user: user,
          password: password,
          root: root,
        );
        await _page(request, _done());
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (error) {
      request.response.statusCode = HttpStatus.internalServerError;
      await _page(request, _message('保存失败：$error'));
    }
  }

  Future<void> _page(HttpRequest request, String html) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store');
    request.response.write(html);
    await request.response.close();
  }

  String _form({String? message}) {
    final style = '''
    body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;margin:0;padding:24px;background:#faf7f0;color:#2b2b2b}
    h1{font-size:20px;margin:0 0 6px}
    p{color:#6b6b6b;font-size:13px;margin:0 0 18px;line-height:1.6}
    label{display:block;font-size:13px;color:#555;margin:14px 0 6px}
    input{width:100%;box-sizing:border-box;padding:12px;font-size:16px;border:1px solid #ddd;border-radius:10px;background:#fff}
    button{width:100%;margin-top:22px;padding:14px;font-size:16px;border:0;border-radius:10px;background:#a86f0e;color:#fff;font-weight:600}
    .error{margin-top:14px;padding:10px 12px;border-radius:8px;background:#fdecea;color:#b3261e;font-size:13px}
    .hint{margin-top:18px;font-size:12px;color:#8a8a8a;line-height:1.7}
    ''';
    final error = message == null
        ? ''
        : '<div class="error">${_escape(message)}</div>';
    return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>小果园 · NAS 配置</title>
<style>$style</style>
</head>
<body>
<h1>配置 NAS</h1>
<p>填写后点保存，电视端会立即生效。</p>
$error
<form method="post" action="/save">
  <label>NAS 地址</label>
  <input name="url" value="${_escape(store.nasUrl)}" placeholder="http://192.168.0.12:5005" required autocomplete="off">
  <label>远端目录</label>
  <input name="root" value="${_escape(store.nasRoot)}" placeholder="/XiaoGuoYuan" autocomplete="off">
  <label>用户名</label>
  <input name="user" value="${_escape(store.nasUser)}" required autocomplete="username">
  <label>密码</label>
  <input name="password" type="password" value="${_escape(store.nasPassword)}" required autocomplete="current-password">
  <button type="submit">保存</button>
</form>
<div class="hint">地址填到端口即可，例如 http://192.168.0.12:5005。远端目录不存在时会由上传功能自动创建。</div>
</body>
</html>''';
  }

  String _done() => '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>已保存</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;margin:0;padding:48px 24px;background:#faf7f0;color:#2b2b2b;text-align:center}
b{display:block;font-size:20px;margin-bottom:10px}
p{color:#6b6b6b;font-size:14px;line-height:1.7}
</style>
</head>
<body>
<b>已保存</b>
<p>电视端已收到配置，可以关闭此页面。</p>
</body>
</html>''';

  String _message(String text) => '''<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>出错了</title></head>
<body style="font-family:sans-serif;padding:24px">${_escape(text)}</body></html>''';

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
