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

// Behaviour parts. Each part adds a mixin onto `_HomeScreenState` that
// shares the same library scope (so private fields and methods are
// freely visible across files). Mirrors `apps/client/lib/src/providers/
// auth/` which uses the same `part of` + mixin pattern.
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

  // Collapsible sidebar state
  bool _sidebarCollapsed = false;
  double _sidebarWidth = 350;
  static const _sidebarMinWidth = 200.0;
  // 640 px gives users on 2560x1440+ displays room to surface long
  // conversation titles, group names, and last-message previews without
  // truncation. The previous 500 px cap felt cramped on wide monitors.
  static const _sidebarMaxWidth = 640.0;

  /// Lower clamp during a resize drag — below `_sidebarMinWidth` so the
  /// drag-end handler can detect a pull-through and snap into compact mode
  /// (#739). Stays above 0 so the sidebar never visually vanishes mid-drag.
  static const _sidebarPullThroughWidth = 100.0;
  static const _sidebarCollapsedWidth = 60.0;
  static const _sidebarDefaultWidth = 350.0;

  // Search focus node for Ctrl+K shortcut
  final _searchFocusNode = FocusNode();

  // Inline "What's New" notes for the desktop overlay path. When non-null
  // the body Stack renders a [WhatsNewInlineOverlay] above the page so
  // the AppTitleBar remains draggable.
  ReleaseNotesView? _whatsNewNotes;

  // Edge-swipe state for narrow chat → conversation-list navigation. Kept
  // on the parent class because `_swipeSnapController` is initialised in
  // `initState` and disposed in `dispose`, while the gesture handlers live
  // in narrow_layout.dart — splitting the state across parts would scatter
  // fragile animation timing across files.
  double? _swipeStartX;

  // Progress of the in-flight edge swipe: 0.0 (idle) → 1.0 (threshold reached).
  // Drives the left-edge peek panel translation feedback.
  double _swipeProgress = 0.0;

  // Snap-back animation: plays from current _swipeProgress down to 0.0 when
  // the drag ends without crossing the threshold.  Initialized in initState.
  late final AnimationController _swipeSnapController;

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
      // Only leave voice on full app termination, not on background.
      // Mobile users expect calls to continue when switching apps or
      // locking the screen.
      _voiceRtcNotifier.leaveChannel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 600;
    final isDesktop = width >= 900;

    _listenForErrors();
    _syncSelectedConversation();

    Widget layout;
    if (isNarrow) {
      layout = _buildNarrowLayout();
    } else if (isDesktop) {
      layout = _buildDesktopLayout();
    } else {
      layout = _buildWideLayout();
    }

    return EchoSystemChrome(
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
            _showQuickSwitcher();
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
          // Power-user shortcuts: open settings (matches the Discord /
          // browser convention) and close settings with Esc so the panel
          // never strands the user without a mouse.
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
