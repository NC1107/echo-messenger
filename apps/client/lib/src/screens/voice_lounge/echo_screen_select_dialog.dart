/// Replacement for livekit_client's ScreenSelectDialog with two bugs fixed:
///
/// 1. **Image.memory without errorBuilder** — the original ThumbnailWidget renders
///    `Image.memory(_thumbnail!)` unconditionally.  When the desktop capturer
///    sends thumbnail bytes that Flutter cannot decode (invalid/raw pixel data)
///    Flutter throws "Invalid image data" via MemoryImage._loadAsync.  Every
///    3 s refresh cycle repeats the error.  Fixed here by wrapping all
///    Image.memory calls with an errorBuilder that shows a placeholder.
///
/// 2. **setState after dispose race** — the original ThumbnailWidget cancels its
///    stream subscriptions with `unawaited(cancel())` in deactivate().  A
///    DesktopCapturerNative event that arrives before the async cancel settles
///    calls setState() on a disposed element (_element is null), crashing with
///    "Null check operator used on a null value".  Fixed here by setting a
///    `_disposed` flag synchronously in dispose() and checking it (plus
///    `mounted`) before every setState call.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Shows the screen / window picker and returns the selected source, or null
/// when the user cancels.
Future<rtc.DesktopCapturerSource?> showEchoScreenSelectDialog(
  BuildContext context,
) {
  return showDialog<rtc.DesktopCapturerSource>(
    context: context,
    builder: (_) => const _EchoScreenSelectDialog(),
  );
}

// ---------------------------------------------------------------------------
// Dialog widget
// ---------------------------------------------------------------------------

class _EchoScreenSelectDialog extends StatefulWidget {
  const _EchoScreenSelectDialog();

  @override
  State<_EchoScreenSelectDialog> createState() =>
      _EchoScreenSelectDialogState();
}

class _EchoScreenSelectDialogState extends State<_EchoScreenSelectDialog> {
  final Map<String, rtc.DesktopCapturerSource> _sources = {};
  rtc.SourceType _tab = rtc.SourceType.Screen;
  rtc.DesktopCapturerSource? _selected;

  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _refreshTimer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();

    _subs.add(
      rtc.desktopCapturer.onAdded.stream.listen((source) {
        if (_disposed || !mounted) return;
        setState(() => _sources[source.id] = source);
      }),
    );

    _subs.add(
      rtc.desktopCapturer.onRemoved.stream.listen((source) {
        if (_disposed || !mounted) return;
        setState(() => _sources.remove(source.id));
      }),
    );

    _subs.add(
      rtc.desktopCapturer.onThumbnailChanged.stream.listen((source) {
        if (_disposed || !mounted) return;
        setState(() => _sources[source.id] = source);
      }),
    );

    _loadSources();
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  Future<void> _loadSources() async {
    try {
      final sources = await rtc.desktopCapturer.getSources(types: [_tab]);
      if (_disposed || !mounted) return;
      setState(() {
        _sources.clear();
        for (final s in sources) {
          _sources[s.id] = s;
        }
      });
      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!_disposed && mounted) {
          unawaited(rtc.desktopCapturer.updateSources(types: [_tab]));
        }
      });
    } catch (e) {
      debugPrint('[EchoScreenSelect] getSources error: $e');
    }
  }

  void _onTabTap(int index) {
    final type = index == 0 ? rtc.SourceType.Screen : rtc.SourceType.Window;
    if (_tab == type) return;
    _refreshTimer?.cancel();
    setState(() {
      _tab = type;
      _sources.clear();
      _selected = null;
    });
    _loadSources();
  }

  void _submit() {
    _refreshTimer?.cancel();
    Navigator.of(context).pop(_selected);
  }

  void _cancel() {
    _refreshTimer?.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _sources.values.where((s) => s.type == _tab).toList();
    final columns = _tab == rtc.SourceType.Screen ? 2 : 3;

    return Dialog(
      child: SizedBox(
        width: 640,
        height: 560,
        child: Column(
          children: [
            // --- header --------------------------------------------------
            Padding(
              padding: const EdgeInsets.all(10),
              child: Stack(
                children: [
                  const Align(
                    alignment: Alignment.topLeft,
                    child: Text(
                      'Choose what to share',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: InkWell(
                      onTap: _cancel,
                      child: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),

            // --- tab bar + grid ------------------------------------------
            Expanded(
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    TabBar(
                      onTap: _onTabTap,
                      tabs: const [
                        Tab(text: 'Entire Screen'),
                        Tab(text: 'Window'),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Expanded(
                      child: visible.isEmpty
                          ? const Center(child: CircularProgressIndicator())
                          : GridView.builder(
                              padding: const EdgeInsets.all(8),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    crossAxisSpacing: 8,
                                    mainAxisSpacing: 8,
                                  ),
                              itemCount: visible.length,
                              itemBuilder: (_, i) {
                                final source = visible[i];
                                return _SourceTile(
                                  key: ValueKey(source.id),
                                  source: source,
                                  selected: _selected?.id == source.id,
                                  onTap: () =>
                                      setState(() => _selected = source),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),

            // --- action buttons ------------------------------------------
            OverflowBar(
              children: [
                TextButton(onPressed: _cancel, child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: _selected != null ? _submit : null,
                  child: const Text('Share'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Source thumbnail tile
// ---------------------------------------------------------------------------

class _SourceTile extends StatefulWidget {
  const _SourceTile({
    super.key,
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final rtc.DesktopCapturerSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SourceTile> createState() => _SourceTileState();
}

class _SourceTileState extends State<_SourceTile> {
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;

  Uint8List? _thumb;
  String _name = '';

  @override
  void initState() {
    super.initState();
    _name = widget.source.name;
    final t = widget.source.thumbnail;
    _thumb = (t != null && t.isNotEmpty) ? t : null;

    _subs.add(
      widget.source.onThumbnailChanged.stream.listen((bytes) {
        if (_disposed || !mounted) return;
        setState(() => _thumb = bytes.isNotEmpty ? bytes : null);
      }),
    );

    _subs.add(
      widget.source.onNameChanged.stream.listen((name) {
        if (_disposed || !mounted) return;
        setState(() => _name = name);
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          border: widget.selected
              ? Border.all(
                  width: 2,
                  color: Theme.of(context).colorScheme.primary,
                )
              : null,
        ),
        child: Column(
          children: [
            Expanded(
              child: _thumb != null
                  ? Image.memory(
                      _thumb!,
                      gaplessPlayback: true,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const _ThumbPlaceholder(),
                    )
                  : const _ThumbPlaceholder(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: widget.selected
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fallback when a thumbnail cannot be decoded
// ---------------------------------------------------------------------------

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade200,
      child: const Center(
        child: Icon(Icons.desktop_windows, size: 40, color: Colors.grey),
      ),
    );
  }
}
