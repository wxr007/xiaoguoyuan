import 'dart:async';

import 'package:flutter/material.dart';

import '../../local_store.dart';
import '../../webdav_client.dart';
import 'nas_player_page.dart';

class NasLibraryPage extends StatefulWidget {
  const NasLibraryPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<NasLibraryPage> createState() => _NasLibraryPageState();
}

class _NasLibraryPageState extends State<NasLibraryPage> {
  late final WebDavClient _client = WebDavClient(
    baseUrl: widget.store.nasUrl,
    username: widget.store.nasUser,
    password: widget.store.nasPassword,
    root: widget.store.nasRoot,
  );
  final _stack = <String>[];
  List<WebDavEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  String get _path => _stack.join('/');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!widget.store.nasConfigured) {
      setState(() {
        _loading = false;
        _error = '请先在 设置 › NAS 中填写地址';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _client.list(_path);
      if (mounted) {
        setState(() {
          _entries = entries;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  void _enter(WebDavEntry entry) {
    setState(() => _stack.add(entry.name));
    unawaited(_load());
  }

  void _up() {
    if (_stack.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _stack.removeLast());
    unawaited(_load());
  }

  Future<void> _play(WebDavEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NasPlayerPage(
          title: entry.name,
          url: _client.playUrl(entry.path),
          headers: {
            'Authorization': WebDavClient.authorization(
              widget.store.nasUser,
              widget.store.nasPassword,
            ),
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: _stack.isEmpty ? '返回' : '上一级',
        onPressed: _up,
        icon: Icon(
          _stack.isEmpty
              ? Icons.arrow_back_rounded
              : Icons.arrow_upward_rounded,
        ),
      ),
      title: Text(_stack.isEmpty ? 'NAS 媒体库' : _stack.last),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : () => unawaited(_load()),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: _body(context),
  );

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final error?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              Text(error, textAlign: TextAlign.center),
              FilledButton(
                onPressed: () => unawaited(_load()),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(child: Text('这个目录是空的'));
    }
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return ListTile(
          leading: Icon(
            entry.isDirectory ? Icons.folder_rounded : Icons.movie_rounded,
          ),
          title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: entry.isDirectory
              ? const Text('文件夹')
              : Text(_size(entry.size)),
          onTap: () {
            if (entry.isDirectory) {
              _enter(entry);
            } else {
              unawaited(_play(entry));
            }
          },
        );
      },
    );
  }

  static String _size(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1 << 20) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1 << 30) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
  }
}
