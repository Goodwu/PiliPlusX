import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

void main() => runApp(const PiliPlusWebApp());

class PiliPlusWebApp extends StatelessWidget {
  const PiliPlusWebApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PiliPlus',
    theme: ThemeData(colorSchemeSeed: Colors.pink, brightness: Brightness.dark),
    home: const WebPlayerPage(),
  );
}

class WebPlayerPage extends StatefulWidget {
  const WebPlayerPage({super.key});
  @override
  State<WebPlayerPage> createState() => _WebPlayerPageState();
}

class _WebPlayerPageState extends State<WebPlayerPage> {
  late final html.VideoElement _video;
  final _url = TextEditingController();

  @override
  void initState() {
    super.initState();
    _video = html.VideoElement()
      ..controls = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%';
    ui_web.platformViewRegistry.registerViewFactory(
      'piliplus-sdr-video',
      (_) => _video,
    );
  }

  @override
  void dispose() {
    _video.pause();
    _video.src = '';
    _url.dispose();
    super.dispose();
  }

  void _open() {
    final value = _url.text.trim();
    if (value.isEmpty) return;
    _video.src = value;
    _video.load();
    _video.play();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PiliPlus · Web SDR')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: const HtmlElementView(viewType: 'piliplus-sdr-video'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _url,
                      decoration: const InputDecoration(
                        labelText: 'SDR media URL',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _open, child: const Text('播放')),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Web 使用浏览器 SDR/tone-map 输出；下载、托盘、原生窗口和 native HDR 不可用。',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
