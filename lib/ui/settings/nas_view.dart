import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../local_store.dart';
import '../../nas_config_server.dart';
import '../../webdav_client.dart';
import '../app_scope.dart';
import '../widgets/group_card.dart';

class NasView extends StatefulWidget {
  const NasView({super.key, required this.store});
  final LocalStore store;

  @override
  State<NasView> createState() => _NasViewState();
}

class _NasViewState extends State<NasView> {
  late final _url = TextEditingController(text: widget.store.nasUrl);
  late final _user = TextEditingController(text: widget.store.nasUser);
  late final _password = TextEditingController(text: widget.store.nasPassword);
  late final _root = TextEditingController(text: widget.store.nasRoot);
  bool _busy = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_syncFromStore);
  }

  void _syncFromStore() {
    if (!mounted) return;
    _syncField(_url, widget.store.nasUrl);
    _syncField(_user, widget.store.nasUser);
    _syncField(_password, widget.store.nasPassword);
    _syncField(_root, widget.store.nasRoot);
  }

  void _syncField(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    widget.store.removeListener(_syncFromStore);
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _root.dispose();
    super.dispose();
  }

  WebDavClient _client() => WebDavClient(
    baseUrl: _url.text,
    username: _user.text.trim(),
    password: _password.text,
    root: _root.text,
  );

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _success = message);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test() => _run(() async {
    if (_url.text.trim().isEmpty) throw WebDavException('请先填写 NAS 地址');
    await _client().test();
    return '连接成功，目录可访问';
  });

  Future<void> _save() => _run(() async {
    if (_url.text.trim().isEmpty) throw WebDavException('请先填写 NAS 地址');
    await widget.store.setNasConfig(
      url: _url.text,
      user: _user.text,
      password: _password.text,
      root: _root.text,
    );
    if (!mounted) return '已保存';
    await AppScope.of(context).repository.setNasConfig(
      url: _url.text,
      user: _user.text,
      password: _password.text,
      root: _root.text,
    );
    return '已保存';
  });

  Future<void> _shareToPhone() async {
    final server = NasConfigServer(
      store: widget.store,
      repository: AppScope.of(context).repository,
    );
    try {
      final address = await server.start();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('用手机填写'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              const Text('在同一 Wi-Fi 下，用手机扫码打开：'),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: address,
                    size: 180,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              SelectableText(
                address,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Text('保存后电视端立即生效。关闭此窗口会停止服务。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '无法启动配置服务：$error');
    } finally {
      await server.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        GroupCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'NAS 地址',
                      hintText: 'http://192.168.0.12:5005',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    controller: _root,
                    decoration: const InputDecoration(
                      labelText: '远端目录',
                      hintText: '/XiaoGuoYuan',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    controller: _user,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '密码',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_error case final error?)
                    Text(
                      error,
                      style: text.bodyMedium?.copyWith(color: colors.error),
                    ),
                  if (_success case final message?)
                    Text(
                      message,
                      style: text.bodyMedium?.copyWith(
                        color: colors.primary,
                      ),
                    ),
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _busy ? null : _test,
                          child: const Text('测试连接'),
                        ),
                      ),
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy ? null : _save,
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _shareToPhone,
                    icon: const Icon(Icons.phone_android_rounded, size: 18),
                    label: const Text('用手机填写'),
                  ),
                ],
              ),
            ),
            const Divider(indent: 16, endIndent: 16),
            SwitchListTile(
              title: const Text('下载完成后自动上传'),
              subtitle: const Text('转成 MP4 后自动同步到 NAS'),
              value: widget.store.nasAutoUpload,
              onChanged: _busy
                  ? null
                  : (value) => widget.store.setNasAutoUpload(value),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '上传目录结构：剧名/Season 01/剧名 - S01E01.mp4，Jellyfin 可直接识别。',
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}
