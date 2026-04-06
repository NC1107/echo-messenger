import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/debug_log_service.dart';
import '../../theme/echo_theme.dart';

/// Settings section that displays a scrollable list of recent debug log entries
/// captured by [DebugLogService].
class DebugSection extends StatefulWidget {
  const DebugSection({super.key});

  @override
  State<DebugSection> createState() => _DebugSectionState();
}

class _DebugSectionState extends State<DebugSection> {
  final _scrollController = ScrollController();
  final _logService = DebugLogService.instance;

  @override
  void initState() {
    super.initState();
    _logService.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    _logService.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLogsChanged() {
    if (!mounted) return;
    setState(() {});
    // Auto-scroll to the newest entry after the frame renders.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _logService.entries;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header row with title and clear button
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Debug Logs',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: entries.isEmpty ? null : _logService.clear,
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('Clear Logs'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textSecondary,
                  disabledForegroundColor: context.textMuted,
                  side: BorderSide(color: context.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            '${entries.length} entries (max ${DebugLogService.maxEntries})',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ),
        const SizedBox(height: 12),
        // Log list
        Expanded(
          child: entries.isEmpty
              ? Center(
                  child: Text(
                    'No debug logs yet.',
                    style: TextStyle(color: context.textMuted, fontSize: 14),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  itemCount: entries.length,
                  itemBuilder: (context, index) =>
                      _LogEntryTile(entry: entries[index]),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Individual log entry row
// ---------------------------------------------------------------------------

class _LogEntryTile extends StatelessWidget {
  final DebugLogEntry entry;

  const _LogEntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamp
          SizedBox(
            width: 72,
            child: Text(
              _formatTime(entry.timestamp),
              style: GoogleFonts.jetBrainsMono(
                color: context.textMuted,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Level badge
          _LevelBadge(level: entry.level),
          const SizedBox(width: 8),
          // Source tag
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: context.surfaceHover,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.source,
              style: GoogleFonts.jetBrainsMono(
                color: context.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Message
          Expanded(
            child: Text(
              entry.message,
              style: GoogleFonts.jetBrainsMono(
                color: context.textPrimary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

// ---------------------------------------------------------------------------
// Colored level badge (green / yellow / red)
// ---------------------------------------------------------------------------

class _LevelBadge extends StatelessWidget {
  final LogLevel level;

  const _LevelBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (level) {
      LogLevel.info => ('INF', EchoTheme.online),
      LogLevel.warning => ('WRN', EchoTheme.warning),
      LogLevel.error => ('ERR', EchoTheme.danger),
    };

    return Container(
      width: 32,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.jetBrainsMono(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
