import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../theme/echo_theme.dart';

/// Discord-style scrollable camera roll grid for picking photos.
///
/// Loads recent images from the device gallery using [photo_manager] and
/// displays them in a 4-column grid. Tapping a photo invokes [onPhotoSelected]
/// with the file, filename, and MIME type -- the caller wires this into the
/// existing attachment upload flow.
///
/// Handles permission requests and shows a friendly message if denied.
class PhotoGalleryPicker extends StatefulWidget {
  final void Function(File file, String fileName, String mimeType)
  onPhotoSelected;

  const PhotoGalleryPicker({super.key, required this.onPhotoSelected});

  @override
  State<PhotoGalleryPicker> createState() => _PhotoGalleryPickerState();
}

class _PhotoGalleryPickerState extends State<PhotoGalleryPicker> {
  static const _pageSize = 80;
  static const _columns = 4;
  static const _thumbSize = ThumbnailSize(200, 200);

  PermissionState _permission = PermissionState.notDetermined;
  final List<AssetEntity> _assets = [];
  int _currentPage = 0;
  bool _hasMore = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _requestPermissionAndLoad();
  }

  Future<void> _requestPermissionAndLoad() async {
    final perm = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    setState(() => _permission = perm);

    if (perm.isAuth || perm == PermissionState.limited) {
      await _loadPage();
    }
  }

  Future<void> _loadPage() async {
    if (_loading || !_hasMore) return;
    _loading = true;

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );

    if (albums.isEmpty) {
      if (mounted) setState(() => _hasMore = false);
      _loading = false;
      return;
    }

    // Use the "Recent" / "All Photos" album (first one)
    final album = albums.first;
    final assets = await album.getAssetListPaged(
      page: _currentPage,
      size: _pageSize,
    );

    if (!mounted) return;
    setState(() {
      _assets.addAll(assets);
      _currentPage++;
      _hasMore = assets.length >= _pageSize;
    });
    _loading = false;
  }

  String _mimeFromTitle(String? title) {
    if (title == null) return 'image/jpeg';
    final ext = title.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' || 'heif' => 'image/heic',
      _ => 'image/jpeg',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!_permission.isAuth && _permission != PermissionState.limited) {
      return _buildPermissionDenied(context);
    }

    if (_assets.isEmpty && !_hasMore) {
      return Center(
        child: Text(
          'No photos found.',
          style: TextStyle(color: context.textMuted, fontSize: 13),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 200) {
          _loadPage();
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.all(2),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
        ),
        itemCount: _assets.length,
        itemBuilder: (context, index) {
          final asset = _assets[index];
          return _PhotoThumbnail(
            asset: asset,
            thumbSize: _thumbSize,
            onTap: () async {
              final file = await asset.file;
              if (file == null || !mounted) return;
              final name = asset.title ?? 'photo_${asset.id}.jpg';
              widget.onPhotoSelected(file, name, _mimeFromTitle(asset.title));
            },
          );
        },
      ),
    );
  }

  Widget _buildPermissionDenied(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 40,
              color: context.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              'Photo access required',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Allow Echo to access your photos to share them in chat.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => PhotoManager.openSetting(),
              child: Text(
                'Open Settings',
                style: TextStyle(color: context.accent, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A single photo thumbnail tile with async loading.
class _PhotoThumbnail extends StatefulWidget {
  final AssetEntity asset;
  final ThumbnailSize thumbSize;
  final VoidCallback onTap;

  const _PhotoThumbnail({
    required this.asset,
    required this.thumbSize,
    required this.onTap,
  });

  @override
  State<_PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<_PhotoThumbnail> {
  Uint8List? _thumbBytes;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  Future<void> _loadThumb() async {
    final bytes = await widget.asset.thumbnailDataWithSize(widget.thumbSize);
    if (mounted && bytes != null) {
      setState(() => _thumbBytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: _thumbBytes != null
          ? Image.memory(_thumbBytes!, fit: BoxFit.cover, gaplessPlayback: true)
          : Container(color: context.surfaceHover),
    );
  }
}
