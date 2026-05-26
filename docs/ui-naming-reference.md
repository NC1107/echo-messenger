# UI naming reference

Cheat sheet of the in-code names for UI regions you see in the app. When filing a bug or asking for a change, point at the name here and code/agents land on the right file immediately.

All paths are relative to `apps/client/lib/src/`.

## Home screen — the main 3-tier layout

`HomeScreen` (`screens/home_screen.dart`) picks one of three tier mixins based on viewport width via `StableLayoutDecision`:

- `_HomeScreenNarrowLayoutMixin` — phone (<600px). Bottom tab bar, full-screen chat panel.
- `_HomeScreenWideLayoutMixin` — tablet (600–899px). Collapsed sidebar + chat.
- `_HomeScreenDesktopLayoutMixin` — desktop (≥900px). Full sidebar + chat + optional right pane.

### Desktop layout

```
┌────────────────────────────────────────────────────────────────────────────┐
│  ┌──────────────┐  ┌────────────────────────────────────┐  ┌────────────┐  │
│  │              │  │  ChatHeaderBar (chat_header_bar)   │  │            │  │
│  │              │  ├────────────────────────────────────┤  │            │  │
│  │              │  │  ChannelBar (channel_bar)          │  │            │  │
│  │              │  │  - text channels + voice dock      │  │            │  │
│  │              │  ├────────────────────────────────────┤  │  Members   │  │
│  │              │  │  EncryptionStatusBanner            │  │  Panel     │  │
│  │ Conversation │  ├────────────────────────────────────┤  │ (members_  │  │
│  │ Panel        │  │                                    │  │  panel)    │  │
│  │ (conversa-   │  │  ChatMessageList                   │  │            │  │
│  │  tion_panel) │  │  (chat_panel/chat_message_list)    │  │  group-    │  │
│  │              │  │                                    │  │  only      │  │
│  │ - sidebar    │  │   - DateDivider                    │  │            │  │
│  │   header     │  │   - UnreadDivider                  │  │            │  │
│  │ - filters    │  │   - MessageItem (message_item)     │  │            │  │
│  │   (All/DMs/  │  │   - FloatingDatePill               │  │            │  │
│  │    Groups)   │  │   - NewMessagesPill                │  │            │  │
│  │ - ConvList   │  │                                    │  │            │  │
│  │ - VoiceDock  │  ├────────────────────────────────────┤  │            │  │
│  │              │  │  ChatInputBar (chat_input_bar)     │  │            │  │
│  │ - account    │  │  - send_button / attach / emoji    │  │            │  │
│  │   rail       │  │                                    │  │            │  │
│  └──────────────┘  └────────────────────────────────────┘  └────────────┘  │
└────────────────────────────────────────────────────────────────────────────┘
        ↑                          ↑                                 ↑
   "the sidebar"             "the chat panel"                "the right panel"
                                                          (group members)
```

### Region names

| What you see | In-code name | File |
|---|---|---|
| The left sidebar (conversation list + voice dock + account rail) | **`ConversationPanel`** | `widgets/conversation_panel.dart` |
| The big chat area on the right of the sidebar | **`ChatPanel`** | `widgets/chat_panel.dart` |
| Top bar of the chat (peer name, call button, more menu) | **`ChatHeaderBar`** | `widgets/chat_header_bar.dart` |
| Strip of text/voice channels under the header (groups only) | **`ChannelBar`** | `widgets/channel_bar.dart` |
| Banner that says "Identity changed" / "Keys missing" / etc. | **`EncryptionStatusBanner`** | `widgets/encryption_status_banner.dart` |
| Floating date pill that follows scroll | **`FloatingDatePill`** | `widgets/chat_panel/floating_date_pill.dart` |
| "X new messages ↓" pill | **`NewMessagesPill`** | `widgets/chat_panel/new_messages_pill.dart` |
| The scrolling list of messages | **`ChatMessageList`** | `widgets/chat_panel/chat_message_list.dart` |
| A single message row | **`MessageItem`** | `widgets/message_item.dart` |
| "Today" / "Yesterday" / dated section breaks | **`DateDivider`** | `widgets/chat_panel/date_divider.dart` |
| The red "New" line above unread messages | **`UnreadDivider`** | `widgets/chat_panel/unread_divider.dart` |
| Right-click / long-press hover menu on a message | **message_actions** | `widgets/chat_panel/message_actions.dart` |
| The compose / type-here strip at the bottom | **`ChatInputBar`** | `widgets/chat_input_bar.dart` |
| Send button inside the input bar | **`SendButton`** | `widgets/chat_input_bar/send_button.dart` |
| Attach-file paperclip | **attach_file_button** | `widgets/chat_input_bar/attach_file_button.dart` |
| The right-side roster pane on groups | **`MembersPanel`** | `widgets/members_panel.dart` |
| The Discord-style narrow channel rail (column mode) | **`ChannelColumn`** | `widgets/channel_column.dart` |
| Voice-call dock pinned to the bottom of the sidebar | **`VoiceDock`** | `widgets/voice_dock.dart` |
| Voice rejoin strip between content and tab bar (mobile narrow) | **`VoiceFooter`** | `widgets/voice_footer.dart` |
| Mobile bottom tab bar (Chats / Discover / Contacts / Settings) | **mobile tab bar** | `home_screen/parts/narrow_layout.dart` (`_buildMobileTabBar`) |

### Narrow (phone) layout

The conversation list and the chat panel swap places — tapping a row opens the chat full-screen, and a bottom tab bar replaces the desktop sidebar.

```
┌──────────────────────┐         ┌──────────────────────┐
│ Sidebar header       │         │  ChatHeaderBar       │
│ - search / new chat  │         │  - back arrow        │
│ ┌──────────────────┐ │         ├──────────────────────┤
│ │ Conv row         │ │  tap →  │  ChannelBar          │
│ │ Conv row         │ │         ├──────────────────────┤
│ │ Conv row         │ │         │  ChatMessageList     │
│ └──────────────────┘ │         │                      │
│                      │         │                      │
│                      │         ├──────────────────────┤
│                      │         │  ChatInputBar        │
├──────────────────────┤         └──────────────────────┘
│ Chats|Discover|... │           swipe-from-left-edge to
│ ←── mobile tab bar │           pop back to conv list
└──────────────────────┘
```

## Voice lounge

```
┌──────────────────────────────────────────────────────────────────────┐
│  LoungeHeader (lounge_header)                                        │
│  ← Lounge   #channel   [photo icon]                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│             ParticipantGrid (participant_grid)                       │
│             - one tile per participant                               │
│             - LoungeDrawingCanvas overlay (if drawing)               │
│                                                                      │
│                                                                      │
│      ┌────────────────────────────────────────────────────┐          │
│      │  FloatingDock (floating_dock)                      │          │
│      │  mic | deafen | cam | screen | draw | leave        │          │
│      └────────────────────────────────────────────────────┘          │
└──────────────────────────────────────────────────────────────────────┘
```

| What you see | In-code name | File |
|---|---|---|
| Title strip with back + channel + background-picker | **`LoungeHeader`** | `screens/voice_lounge/lounge_header.dart` |
| Grid of participant video / avatar tiles | **`ParticipantGrid`** | `screens/voice_lounge/participant_grid.dart` |
| Floating control dock (mic / cam / leave / etc.) | **`FloatingDock`** | `screens/voice_lounge/floating_dock.dart` |
| Drawing-tool palette popover | **`DrawingToolsMenu`** | `screens/voice_lounge/drawing_tools_menu.dart` |
| Source-picker for screen share | **echo_screen_select_dialog** | `screens/voice_lounge/echo_screen_select_dialog.dart` |
| Hover submenus on the dock buttons | **dock_submenus** | `screens/voice_lounge/dock_submenus.dart` |

## Settings

```
┌─────────────────┬──────────────────────────────────────────────────┐
│ ← Back          │                                                  │
│                 │                                                  │
│ T username      │                                                  │
│                 │                                                  │
│ Account prefs   │            (selected section body                │
│  Status         │             rendered here — e.g.                 │
│  Appearance     │             AppearanceSection,                   │
│  Language       │             AccessibilitySection,                │
│  Notifications  │             AccountSection, etc.)                │
│  Voice & Video  │                                                  │
│  Privacy        │                                                  │
│  Devices        │                                                  │
│  Storage        │                                                  │
│  Accessibility  │                                                  │
│ Echo            │                                                  │
│  About v0.0.x   │                                                  │
│ Log out         │                                                  │
└─────────────────┴──────────────────────────────────────────────────┘
       ↑                              ↑
"settings sidebar"               "section body"
(SettingsRootView)               (one of the *Section widgets)
```

| What you see | In-code name | File |
|---|---|---|
| Whole screen | **`SettingsScreen`** | `screens/settings_screen.dart` |
| Left nav with section list | **`SettingsRootView`** | `screens/settings_screen.dart` (`SettingsRootView`) |
| One row in the left nav | **`CardRow`** | `widgets/settings/card_row.dart` |
| A plain icon+title row inside a section | **`SettingsListTile`** | `widgets/settings/settings_list_tile.dart` |
| Section header label inside a section body | **`SectionHeader`** | `widgets/settings/section_header.dart` |
| User identity card at the top of Account section | **`UserHeaderCard`** | `widgets/settings/user_header_card.dart` |
| Status section body | **`StatusSection`** | `screens/settings/status_section.dart` |
| Appearance section body (themes, GIF autoplay today) | **`AppearanceSection`** | `screens/settings/appearance_section.dart` |
| Language section body | **`LanguageSection`** | `screens/settings/language_section.dart` |
| Notifications section body | **`NotificationSection`** | `screens/settings/notification_section.dart` |
| Voice & Video section body | **`VoiceVideoSection`** | `screens/settings/voice_section.dart` |
| Privacy section body | **`PrivacySection`** | `screens/settings/privacy_section.dart` |
| Devices section body | **`DevicesSection`** | `screens/settings/devices_section.dart` |
| Storage section body | **`DataStorageSection`** | `screens/settings/data_storage_section.dart` |
| Accessibility section body (font scale today) | **`AccessibilitySection`** | `screens/settings/accessibility_section.dart` |
| About section body | **`AboutSection`** | `screens/settings/about_section.dart` |
| Account section body | **`AccountSection`** | `screens/settings/account_section.dart` |
| Advanced theme picker | **`AdvancedThemeSection`** | `screens/settings/advanced_theme_section.dart` |

## Group info

Open from the chat header (group conv) or anywhere that calls `showGroupProfileSheet`. Dialog on desktop ≥800px, bottom-sheet below.

```
┌─────────────────────────────────────────────────┐
│  ← Group Info                                   │
├─────────────────────────────────────────────────┤
│  HeaderSection (parts/header_section)           │
│   - avatar + name + description                 │
├─────────────────────────────────────────────────┤
│  ChannelsSection (admin only)                   │
│  DisappearingMessages (admin only)              │
│  MembersSection (parts/members_section)         │
│   - roster grouped by role                      │
│   - AddMemberDialog launcher                    │
│  InviteSection (parts/invite_section)           │
│  DangerActions (parts/danger_actions)           │
│   - Leave / Delete                              │
└─────────────────────────────────────────────────┘
```

| What you see | In-code name | File |
|---|---|---|
| Whole screen / sheet | **`GroupInfoScreen`** | `screens/group_info_screen.dart` |
| Icon + name + description block at top | **HeaderSection** | `screens/group_info_screen/parts/header_section.dart` |
| Text + voice channel list | **ChannelsSection** | `screens/group_info_screen/parts/channels_section.dart` |
| TTL picker | **DisappearingMessages** | `screens/group_info_screen/parts/disappearing_messages.dart` |
| Roster + role grouping | **MembersSection** | `screens/group_info_screen/parts/members_section.dart` |
| Add-member modal | **AddMemberDialog** | `screens/group_info_screen/parts/add_member_dialog.dart` |
| Invite-link card | **InviteSection** | `screens/group_info_screen/parts/invite_section.dart` |
| Leave / Delete buttons | **DangerActions** | `screens/group_info_screen/parts/danger_actions.dart` |

## Other dialogs / overlays you might mean

| What you see | In-code name | File |
|---|---|---|
| User profile popup (avatar + status + bio + actions) | **`UserProfileScreen`** (opened via `showUserProfileSheet`) | `screens/user_profile_screen.dart` (host) / `widgets/profile_sheets.dart` (presenter) |
| Cmd+K / Ctrl+K conversation switcher | **`QuickSwitcherOverlay`** | `widgets/quick_switcher_overlay.dart` |
| Ctrl+Shift+F across-all-chats search | **`GlobalSearchOverlay`** | `widgets/global_search_overlay.dart` |
| Per-chat search (the magnifying glass on the header — pending removal in #1135) | **`MessageSearchOverlay`** | `widgets/message_search_overlay.dart` |
| "Are you sure?" confirmation dialog | **`showEchoConfirmDialog`** | `widgets/confirm_dialog.dart` |
| Any modal bottom sheet | **`showEchoBottomSheet`** | `widgets/echo_bottom_sheet.dart` |
| Generic empty state with illustration | **`EmptyState`** | `widgets/empty_state.dart` |
| Generic info / warning / danger banner | **`EchoBanner`** | `widgets/echo_banner.dart` |
| Image lightbox | **`ImageGalleryViewer`** | `widgets/image_gallery_viewer.dart` |
| Sticker / emoji picker | **`EmojiPickerConfig`** | `widgets/emoji_picker_config.dart` |
| Reactions full picker (after More) | **`FullReactionPicker`** | `widgets/chat_panel/full_reaction_picker.dart` |
| Auth screens scaffold (login / register / forgot / reset) | **`AuthLayout`** | `widgets/auth/auth_layout.dart` |
| Onboarding wizard | **`OnboardingWizard`** | `screens/onboarding_wizard.dart` |
| Splash | **`SplashScreen`** | `screens/splash_screen.dart` |
| Update-available card on splash | **(update prompt)** | `providers/update_provider.dart` + `screens/splash_screen.dart` |
| New-message composer | **`NewMessageScreen`** | `screens/new_message_screen.dart` |
| Create-group flow | **`CreateGroupScreen`** | `screens/create_group_screen.dart` |
| Discover groups list | **`DiscoverGroupsScreen`** | `screens/discover_groups_screen.dart` |
| Saved-messages list | **`SavedMessagesScreen`** | `screens/saved_messages_screen.dart` |
| Contacts list | **`ContactsScreen`** | `screens/contacts_screen.dart` |
| Safety number / verification | **`SafetyNumberScreen`** | `screens/safety_number_screen.dart` |
| Join-by-invite landing | **`JoinGroupScreen`** | `screens/join_group_screen.dart` |
| Admin dashboard | **`AdminDashboardScreen`** | `screens/admin/admin_dashboard_screen.dart` |
| Connection indicator dot near the top-left | **`ConnectionStatusBadge`** | `widgets/connection_status_badge.dart` |

## How to use this when filing a bug

Best: paste the name directly. "On `MembersPanel`, the presence dot is offset by 4px on hi-DPI Linux" lands faster than "on the right side roster thing".

Second-best: paste the file path. `widgets/chat_panel/floating_date_pill.dart:42` is unambiguous and goes straight to the line.

When unsure: describe the screen + region. "Settings → Voice & Video, the input device dropdown" maps cleanly to `screens/settings/voice_section.dart`.

If you see a region that isn't on this list, add it here. The doc is the source of truth — anything inconsistent with current code is a bug to fix in the doc.
