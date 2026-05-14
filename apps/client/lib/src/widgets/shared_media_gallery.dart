import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/media_ticket_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/media_cache_service.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';
import 'image_gallery_viewer.dart';
import 'message/media_content.dart';

/// Extracts all shared media (images, videos, files) from a conversation's
/// cached messages and displays them in a grid with a filter tab row.
class SharedMediaGallery extends ConsumerWidget {
  final String conversationId;

  const SharedMediaGallery({super.key, required this.conversationId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatState = ref.watch(chatProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    final authToken = ref.watch(authProvider.select((s) => s.token)) ?? '';
    final mediaTicket = ref.watch(mediaTicketProvider);
    final messages = chatState.messagesForConversation(conversationId);

    // Collect media items from all cached messages
    final mediaItems = <_MediaItem>[];
    for (final msg in messages.reversed) {
      final url = extractMediaUrl(msg.content);
      if (url != null) {
        mediaItems.add(_MediaItem(message: msg, rawUrl: url));
      }
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: context.chatBg,
        appBar: AppBar(
          backgroundColor: context.sidebarBg,
          title: Text(
            'Shared Media',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          leading: IconButton(
            icon: Icon(Icons.close, color: context.textSecondary),
            onPressed: () => Navigator.of(context).pop(),
          ),
          bottom: TabBar(
            indicatorColor: context.accent,
            labelColor: context.accent,
            unselectedLabelColor: context.textMuted,
            dividerColor: context.border,
            tabs: const [
              Tab(text: 'Images'),
              Tab(text: 'Videos'),
              Tab(text: 'Files'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _MediaGrid(
              items: mediaItems.where(_isImage).toList(),
              serverUrl: serverUrl,
              authToken: authToken,
              mediaTicket: mediaTicket,
              emptyLabel: 'No images shared yet',
            ),
            _MediaGrid(
              items: mediaItems.where(_isVideo).toList(),
              serverUrl: serverUrl,
              authToken: authToken,
              mediaTicket: mediaTicket,
              emptyLabel: 'No videos shared yet',
              isVideo: true,
            ),
            _FileList(
              items: mediaItems.where(_isFile).toList(),
              serverUrl: serverUrl,
              authToken: authToken,
              mediaTicket: mediaTicket,
            ),
          ],
        ),
      ),
    );
  }

  static bool _isImage(_MediaItem item) {
    return item.message.content.startsWith('[img:');
  }

  static bool _isVideo(_MediaItem item) {
    return item.message.content.startsWith('[video:');
  }

  static bool _isFile(_MediaItem item) {
    return item.message.content.startsWith('[file:');
  }
}

class _MediaItem {
  final ChatMessage message;
  final String rawUrl;

  const _MediaItem({required this.message, required this.rawUrl});
}

/// Grid of image/video thumbnails.
///
/// When [isVideo] is true, each tile fetches the server-generated first-frame
/// thumbnail from `<rawUrl>/thumb` instead of trying to render the raw video
/// file as an image (which always failed and showed the placeholder, #735).
/// Video tiles also get a play-icon overlay and open the video externally on
/// tap rather than launching the in-app image gallery.
class _MediaGrid extends StatelessWidget {
  final List<_MediaItem> items;
  final String serverUrl;
  final String authToken;
  final String? mediaTicket;
  final String emptyLabel;
  final bool isVideo;

  const _MediaGrid({
    required this.items,
    required this.serverUrl,
    required this.authToken,
    this.mediaTicket,
    required this.emptyLabel,
    this.isVideo = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVideo ? Icons.videocam_outlined : Icons.image_outlined,
              size: 48,
              color: context.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              emptyLabel,
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          ],
        ),
      );
    }

    // For images, the resolved URL points to the file itself. For videos, the
    // file URL would be the .mp4/.webm bytes, so we resolve `<rawUrl>/thumb`
    // for the tile preview instead. Building the `/thumb` path off the raw URL
    // (before resolveMediaUrl appends any `?ticket=`) keeps the query string
    // at the very end of the URL — matches the InlineVideoPlayer fix in #411.
    final resolvedThumbUrls = [
      for (final item in items)
        resolveMediaUrl(
          isVideo ? '${item.rawUrl}/thumb' : item.rawUrl,
          serverUrl: serverUrl,
          authToken: authToken,
          mediaTicket: mediaTicket,
        ),
    ];
    // For video tap-to-open we still want the raw file URL, not /thumb.
    final resolvedFileUrls = isVideo
        ? [
            for (final item in items)
              resolveMediaUrl(
                item.rawUrl,
                serverUrl: serverUrl,
                authToken: authToken,
                mediaTicket: mediaTicket,
              ),
          ]
        : resolvedThumbUrls;
    final headers = mediaHeaders(authToken: authToken);

    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final thumbUrl = resolvedThumbUrls[index];
        final fileUrl = resolvedFileUrls[index];

        return Semantics(
          label: isVideo ? 'play video' : 'view media',
          button: true,
          child: GestureDetector(
            onTap: () {
              if (isVideo) {
                final uri = Uri.tryParse(fileUrl);
                if (uri != null) {
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              } else {
                showImageGallery(
                  context: context,
                  imageUrls: resolvedThumbUrls,
                  initialIndex: index,
                  headers: headers,
                );
              }
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  thumbUrl.endsWith('.gif')
                      ? Image.network(
                          thumbUrl,
                          headers: headers,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              _placeholder(context, isVideo: isVideo),
                        )
                      : CachedNetworkImage(
                          imageUrl: thumbUrl,
                          cacheKey: stableMediaCacheKey(thumbUrl),
                          cacheManager: chatMediaCacheManager,
                          httpHeaders: headers,
                          fit: BoxFit.cover,
                          placeholder: (_, _) =>
                              _placeholder(context, isVideo: isVideo),
                          errorWidget: (_, _, _) =>
                              _placeholder(context, isVideo: isVideo),
                        ),
                  if (isVideo)
                    const Center(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Color(0x80000000),
                          shape: BoxShape.circle,
                        ),
                        child: Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool isVideo = false}) {
    return Container(
      color: context.surface,
      child: Icon(
        isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        color: context.textMuted,
        size: 24,
      ),
    );
  }
}

/// List of file attachments.
class _FileList extends StatelessWidget {
  final List<_MediaItem> items;
  final String serverUrl;
  final String authToken;
  final String? mediaTicket;

  const _FileList({
    required this.items,
    required this.serverUrl,
    required this.authToken,
    this.mediaTicket,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.attach_file_outlined,
              size: 48,
              color: context.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              'No files shared yet',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: context.border, indent: 56),
      itemBuilder: (context, index) {
        final item = items[index];
        final resolvedUrl = resolveMediaUrl(
          item.rawUrl,
          serverUrl: serverUrl,
          authToken: authToken,
          mediaTicket: mediaTicket,
        );
        final filename =
            Uri.tryParse(resolvedUrl)?.pathSegments.lastOrNull ?? 'file';
        final timestamp = formatMessageTimestamp(item.message.timestamp);

        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.insert_drive_file_outlined,
              color: context.accent,
              size: 20,
            ),
          ),
          title: Text(
            filename,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${item.message.fromUsername} · $timestamp',
            style: TextStyle(color: context.textMuted, fontSize: 11),
          ),
          onTap: () {
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}
