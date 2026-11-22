import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class NasPlayerPage extends StatefulWidget {
  const NasPlayerPage({
    super.key,
    required this.title,
    required this.url,
    required this.headers,
  });

  final String title;
  final String url;
  final Map<String, String> headers;

  @override
  State<NasPlayerPage> createState() => _NasPlayerPageState();
}

class _NasPlayerPageState extends State<NasPlayerPage> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<String>? _errors;
  String? _error;

  @override
  void initState() {
    super.initState();
    _errors = _player.stream.error.listen((message) {
      if (mounted) setState(() => _error = message);
    });
    unawaited(
      _player.open(Media(widget.url, httpHeaders: widget.headers)),
    );
  }

  @override
  void dispose() {
    _errors?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      children: [
        Positioned.fill(child: Video(controller: _controller)),
        if (_error case final error?)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
        SafeArea(
          child: Align(
            alignment: Alignment.topLeft,
            child: IconButton(
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
              color: Colors.white,
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 14, left: 56, right: 56),
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
