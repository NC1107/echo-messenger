import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// A shimmer-effect skeleton loader that mimics content shape during loading.
class SkeletonLine extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SkeletonLine({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.borderRadius = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Skeleton placeholder for a conversation list item.
class ConversationSkeleton extends StatelessWidget {
  const ConversationSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: context.surface,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonLine(
                  width: 100 + (hashCode % 60).toDouble(),
                  height: 14,
                ),
                const SizedBox(height: 6),
                SkeletonLine(
                  width: 140 + (hashCode % 80).toDouble(),
                  height: 11,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const SkeletonLine(width: 32, height: 11),
        ],
      ),
    );
  }
}

/// Skeleton placeholder for a message bubble.
class MessageSkeleton extends StatelessWidget {
  final bool isMine;

  const MessageSkeleton({super.key, this.isMine = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: context.surface,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Container(
            width: 120 + (hashCode % 100).toDouble(),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMine) const SkeletonLine(width: 60, height: 10),
                if (!isMine) const SizedBox(height: 6),
                const SkeletonLine(height: 12),
                const SizedBox(height: 4),
                SkeletonLine(
                  width: 60 + (hashCode % 40).toDouble(),
                  height: 12,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A list of skeleton conversation items for the sidebar loading state.
class ConversationListSkeleton extends StatelessWidget {
  final int count;

  const ConversationListSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (i) => ConversationSkeleton(key: ValueKey('skel-$i')),
      ),
    );
  }
}

/// A list of skeleton message items for the chat loading state.
class MessageListSkeleton extends StatelessWidget {
  final int count;

  const MessageListSkeleton({super.key, this.count = 8});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (i) =>
            MessageSkeleton(key: ValueKey('msg-skel-$i'), isMine: i % 3 == 0),
      ),
    );
  }
}
