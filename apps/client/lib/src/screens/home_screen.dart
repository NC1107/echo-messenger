import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/channel_layout_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/auth_provider.dart';
import '../services/toast_service.dart';
import '../providers/chat_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/update_provider.dart';
import '../providers/livekit_voice/livekit_voice_provider.dart';
import '../providers/release_notes_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/debug_log_service.dart';
import '../services/notification_service.dart';
import '../services/tray_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../widgets/chat_panel.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/conversation_panel.dart'
    show ConversationPanel, buildAvatar, groupAvatarColor, resolveAvatarUrl;
import '../widgets/members_panel.dart';
import '../utils/web_lifecycle.dart';
import '../version.dart';
import '../widgets/keyboard_shortcuts_overlay.dart';
import '../widgets/global_search_overlay.dart';
import '../widgets/whats_new_modal.dart';
import '../widgets/quick_switcher_overlay.dart';
import '../widgets/system_chrome.dart';
import '../widgets/voice_footer.dart';
import '../widgets/window_chrome.dart';
import 'contacts_screen.dart';
import 'new_message_screen.dart';
import 'saved_messages_screen.dart';
import 'voice_lounge_screen.dart';
import 'create_group_screen.dart';
import 'discover_groups_screen.dart';
import 'settings_screen.dart';
import '../widgets/profile_sheets.dart';

// Behaviour mixins share the same library scope as `_HomeScreenState` via `part of`.
part 'home_screen/parts/lifecycle.dart';
part 'home_screen/parts/actions.dart';
part 'home_screen/parts/listeners.dart';
part 'home_screen/parts/desktop_layout.dart';
part 'home_screen/parts/wide_layout.dart';
part 'home_screen/parts/narrow_layout.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final String? initialConversationId;
  final String? initialMessageId;

  const HomeScreen({
    super.key,
    this.initialConversationId,
    this.initialMessageId,
  });

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with
        WidgetsBindingObserver,
        SingleTickerProviderStateMixin,
        _HomeScreenActionsMixin,
        _HomeScreenListenersMixin,
        _HomeScreenLifecycleMixin,
        _HomeScreenDesktopLayoutMixin,
        _HomeScreenWideLayoutMixin,
        _HomeScreenNarrowLayoutMixin {
  Conversation? _selectedConversation;
  String? _pendingMessageId;
  // Slice 7: members panel defaults to on so group context (roles, online
  // status) is visible without an explicit toggle. Users can still hide it.
  bool _showMembers = true;
  Timer? _pendingRefreshTimer;
  late final LiveKitVoiceNotifier _voiceRtcNotifier;
  StreamSubscription<String>? _notificationTapSub;

  // Edge-swipe constants for narrow chat → conversation-list navigation
  static const double _edgeSwipeZone = 60;
  static const double _edgeSwipeThreshold = 60;

  // For narrow screen navigation
  int _narrowPanelIndex = 0; // 0 = conv list, 1 = chat

  // Voice lounge: when true and voice is active, show lounge instead of chat
  bool _showingLounge = true;
  bool _userDismissedLounge = false;

  // Settings inline state
  bool _showSettings = false;
  SettingsSection _settingsSection = SettingsSection.profile;

  /// Bottom tab index on mobile narrow viewport.
  /// 0 = Chats, 1 = Discover, 2 = Contacts, 3 = Settings.
  int _mobileTabIndex = 0;

  // Members panel resize state. Mirrors the sidebar's drag-resize handle so
  // ultrawide users can grow the right rail without code changes.
  double _membersPanelWidth = MembersPanel.defaultWidth;

  // Collapsible sidebar state
  bool _sidebarCollapsed = false;
  double _sidebarWidth = 350;
  static const _sidebarMinWidth = 200.0;

  /// Base sidebar ceiling on a typical 1280-1600 px laptop. The actual max
  /// used by the drag handle scales with viewport width via
  /// [_sidebarMaxWidthFor] so ultrawide users (3440 px etc.) can grow the
  /// sidebar past 500 px. The 640 px ceiling that batch D landed earlier
  /// is now superseded by the scaling function — see `_sidebarMaxWidthFor`.
  static const _sidebarMaxWidthBase = 500.0;
  static const _sidebarMaxWidthCeiling = 720.0;

  /// Computes the sidebar's drag-resize ceiling for a given viewport width.
  /// 28% of the viewport, clamped to `[500, 720]`. On a 1280 px screen this
  /// returns 500 (base); on a 3440 px ultrawide it returns 720 (ceiling).
  static double _sidebarMaxWidthFor(double viewportWidth) {
    final scaled = viewportWidth * 0.28;
    if (scaled < _sidebarMaxWidthBase) return _sidebarMaxWidthBase;
    if (scaled > _sidebarMaxWidthCeiling) return _sidebarMaxWidthCeiling;
    return scaled;
  }

  /// Lower clamp during a resize drag — below `_sidebarMinWidth` so the
  /// drag-end handler can detect a pull-through and snap into compact mode
  /// (#739). Stays above 0 so the sidebar never visually vanishes mid-drag.
  static const _sidebarPullThroughWidth = 100.0;
  static const _sidebarCollapsedWidth = 60.0;
  static const _sidebarDefaultWidth = 350.0;

  // Search focus node for Ctrl+K shortcut
  final _searchFocusNode = FocusNode();

  // Non-null = render WhatsNewInlineOverlay above the page so AppTitleBar stays draggable.
  ReleaseNotesView? _whatsNewNotes;

  // Edge-swipe state lives on parent so initState/dispose own the AnimationController
  // even though gesture handlers live in narrow_layout.dart.
  double? _swipeStartX;

  // Progress of the in-flight edge swipe: 0.0 (idle) → 1.0 (threshold reached).
  // Drives the left-edge peek panel translation feedback.
  double _swipeProgress = 0.0;

  // Snap-back animation: plays from current _swipeProgress down to 0.0 when
  // the drag ends without crossing the threshold.  Initialized in initState.
  late final AnimationController _swipeSnapController;

  /// Layout-tier picker with hysteresis. Lives on the State so the previous
  /// decision survives across rebuilds. Without this, dragging the window
  /// across 600 px or 900 px would swap top-level scaffolds every frame,
  /// dropping scroll positions, open popovers and in-flight overlays.
  final StableLayoutDecision _layoutDecision = StableLayoutDecision();

  @override
  void initState() {
    super.initState();
    _swipeSnapController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 150),
        )..addListener(() {
          if (mounted) {
            setState(() => _swipeProgress = _swipeSnapController.value);
          }
        });
    _voiceRtcNotifier = ref.read(voiceRtcProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initData();
    });
    // Navigate to conversation when user taps a notification
    _notificationTapSub = NotificationService().onNotificationTap.listen(
      _onNotificationTap,
    );
    // Web: leave voice call on tab close
    registerBeforeUnload(() {
      _voiceRtcNotifier.leaveChannel();
    });
  }

  @override
  void dispose() {
    _notificationTapSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unregisterBeforeUnload();
    _pendingRefreshTimer?.cancel();
    _searchFocusNode.dispose();
    _swipeSnapController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep the notification service in sync with app focus so that native
    // notifications are suppressed while the user is looking at the app.
    NotificationService().setAppFocused(state == AppLifecycleState.resumed);

    if (state == AppLifecycleState.resumed) {
      ref.read(contactsProvider.notifier).loadPending(force: true);
    } else if (state == AppLifecycleState.detached) {
      // Only leave voice on full app termination; backgrounded calls must keep running.
      _voiceRtcNotifier.leaveChannel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final tier = _layoutDecision.next(width);

    _listenForErrors();
    _syncSelectedConversation();

    final Widget layout = switch (tier) {
      LayoutTier.narrow => _buildNarrowLayout(),
      LayoutTier.desktop => _buildDesktopLayout(),
      LayoutTier.wide => _buildWideLayout(),
    };

    return EchoSystemChrome(
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
            _showQuickSwitcher();
          },
          // Ctrl+F (native "find" muscle memory) + legacy Ctrl+Shift+F both open global search (#1135).
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
            _showGlobalSearch();
          },
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            control: true,
            shift: true,
          ): () {
            _showGlobalSearch();
          },
          const SingleActivator(LogicalKeyboardKey.slash, control: true): () {
            _showKeyboardShortcuts();
          },
          // Ctrl+, opens settings (Discord/browser convention); Esc closes for no-mouse exit.
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () {
            _openSettings();
          },
          const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
        },
        child: Focus(autofocus: true, child: layout),
      ),
    );
  }

  /// Esc closes the inline settings panel on desktop. On narrow viewports
  /// the settings screen is a real route and its own back button handles
  /// dismissal, so we only intercept Esc when the inline panel is open.
  void _onEscape() {
    if (_showSettings) {
      setState(() => _showSettings = false);
    }
  }

  bool get _isDesktop => Responsive.isDesktop(context);
}
