import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/time_utils.dart';
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
              emptyLabel: 'No images shared yet',
            ),
            _MediaGrid(
              items: mediaItems.where(_isVideo).toList(),
              serverUrl: serverUrl,
              authToken: authToken,
              emptyLabel: 'No videos shared yet',
            ),
            _FileList(
              items: mediaItems.where(_isFile).toList(),
              serverUrl: serverUrl,
              authToken: authToken,
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
class _MediaGrid extends StatelessWidget {
  final List<_MediaItem> items;
  final String serverUrl;
  final String authToken;
  final String emptyLabel;

  const _MediaGrid({
    required this.items,
    required this.serverUrl,
    required this.authToken,
    required this.emptyLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
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

    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 3,
        mainAxisSpacing: 3,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final resolvedUrl = resolveMediaUrl(
          item.rawUrl,
          serverUrl: serverUrl,
          authToken: authToken,
        );
        final headers = mediaHeaders(authToken: authToken);

        return GestureDetector(
          onTap: () => _showFullImage(context, resolvedUrl, headers),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: resolvedUrl.endsWith('.gif')
                ? Image.network(
                    resolvedUrl,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => _placeholder(context),
                  )
                : CachedNetworkImage(
                    imageUrl: resolvedUrl,
                    httpHeaders: headers,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => _placeholder(context),
                    errorWidget: (_, _, _) => _placeholder(context),
                  ),
          ),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    return Container(
      color: context.surface,
      child: Icon(Icons.image_outlined, color: context.textMuted, size: 24),
    );
  }

  void _showFullImage(
    BuildContext context,
    String imageUrl,
    Map<String, String> headers,
  ) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (dialogContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(dialogContext).pop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(dialogContext).size.width * 0.85,
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.85,
              ),
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  httpHeaders: headers,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorWidget: (_, _, _) => const Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: IconButton(
              icon: const Icon(Icons.close),
              color: Colors.white,
              tooltip: 'Close',
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// List of file attachments.
class _FileList extends StatelessWidget {
  final List<_MediaItem> items;
  final String serverUrl;
  final String authToken;

  const _FileList({
    required this.items,
    required this.serverUrl,
    required this.authToken,
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
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: context.border,
        indent: 56,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        final resolvedUrl = resolveMediaUrl(
          item.rawUrl,
          serverUrl: serverUrl,
          authToken: authToken,
        );
        final filename =
            Uri.tryParse(resolvedUrl)?.pathSegments.lastOrNull ??
            'file';
        final timestamp = formatMessageTimestamp(item.message.timestamp);

        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.insert_drive_file_outlined, color: context.accent, size: 20),
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
