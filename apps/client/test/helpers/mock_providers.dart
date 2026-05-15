import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/accessibility_provider.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/biometric_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/contacts_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/providers/websocket_provider.dart'
    show WebSocketNotifier, WebSocketState, websocketProvider;

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

/// A logged-in auth state for widget tests.
const loggedInAuthState = AuthState(
  isLoggedIn: true,
  userId: 'test-user-id',
  username: 'testuser',
  token: 'fake-jwt-token',
  refreshToken: 'fake-refresh-token',
);

/// A logged-out auth state.
const loggedOutAuthState = AuthState();

/// An auth state with an error message.
const errorAuthState = AuthState(error: 'Invalid credentials');

/// An auth state that is loading.
const loadingAuthState = AuthState(isLoading: true);

/// Override [authProvider] with a fixed [AuthState].
Override authOverride([AuthState state = const AuthState()]) {
  return authProvider.overrideWith((ref) => _FakeAuthNotifier(ref, state));
}

class _FakeAuthNotifier extends AuthNotifier {
  _FakeAuthNotifier(super.ref, AuthState initial) {
    state = initial;
  }

  @override
  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    state = const AuthState(
      isLoggedIn: true,
      userId: 'test-user-id',
      username: 'testuser',
      token: 'fake-jwt-token',
      refreshToken: 'fake-refresh-token',
    );
  }

  @override
  Future<void> register(String username, String password) async {
    state = state.copyWith(isLoading: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    state = const AuthState(
      isLoggedIn: true,
      userId: 'test-user-id',
      username: 'testuser',
      token: 'fake-jwt-token',
    );
  }

  @override
  Future<bool> tryAutoLogin() async => false;

  @override
  Future<void> logout({String? serverUrl}) async => state = const AuthState();
}

// ---------------------------------------------------------------------------
// Server URL
// ---------------------------------------------------------------------------

/// Override [serverUrlProvider] with a test URL.
Override serverUrlOverride([String url = 'http://localhost:8080']) {
  return serverUrlProvider.overrideWith(() => FakeServerUrlNotifier(url));
}

/// Test override for [ServerUrlNotifier] that publishes a fixed URL via
/// `build()` and turns `load()` / `setUrl()` into no-ops (so tests don't
/// touch SharedPreferences). Exposed publicly so per-test files can build
/// their own overrides without re-declaring the boilerplate.
class FakeServerUrlNotifier extends ServerUrlNotifier {
  FakeServerUrlNotifier(this._initial);
  final String _initial;

  @override
  String build() => _initial;

  @override
  Future<void> load() async {}

  @override
  Future<void> setUrl(String url) async => state = url;
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

/// Sample conversations used in tests.
final sampleConversations = [
  const Conversation(
    id: 'conv-1',
    name: null,
    isGroup: false,
    lastMessage: 'Hey there!',
    lastMessageTimestamp: '2026-01-15T10:30:00Z',
    lastMessageSender: 'alice',
    unreadCount: 2,
    members: [
      ConversationMember(userId: 'user-alice', username: 'alice'),
      ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ],
  ),
  const Conversation(
    id: 'conv-2',
    name: 'Dev Team',
    isGroup: true,
    lastMessage: 'Meeting at 3pm',
    lastMessageTimestamp: '2026-01-15T09:00:00Z',
    lastMessageSender: 'bob',
    unreadCount: 0,
    members: [
      ConversationMember(userId: 'user-bob', username: 'bob'),
      ConversationMember(userId: 'user-carol', username: 'carol'),
      ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ],
  ),
];

/// Override [conversationsProvider] with a fixed list.
Override conversationsOverride([List<Conversation> conversations = const []]) {
  return conversationsProvider.overrideWith(
    (ref) => _FakeConversationsNotifier(ref, conversations),
  );
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(super.ref, List<Conversation> initial) {
    state = ConversationsState(conversations: initial);
  }

  @override
  Future<void> loadConversations() async {}
}

// ---------------------------------------------------------------------------
// Contacts
// ---------------------------------------------------------------------------

/// Override [contactsProvider] with an empty state.
Override contactsOverride() {
  return contactsProvider.overrideWith(_FakeContacts.new);
}

class _FakeContacts extends Contacts {
  @override
  ContactsState build() => const ContactsState();

  @override
  Future<void> loadContacts() async {}

  @override
  Future<void> loadPending({bool force = false}) async {}
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

/// Override [websocketProvider] with a connected state by default. Pass
/// [initial] to override (e.g. tests for disconnect/reconnect flows).
///
/// Default = connected because the [ConnectionStatusBadge] in the sidebar
/// runs a pulse animation while reconnecting, which would otherwise prevent
/// [WidgetTester.pumpAndSettle] from ever terminating in widget tests.
Override webSocketOverride([
  WebSocketState initial = const WebSocketState(isConnected: true),
]) {
  return websocketProvider.overrideWith(() => _FakeWebSocketNotifier(initial));
}

class _FakeWebSocketNotifier extends WebSocketNotifier {
  _FakeWebSocketNotifier(this._initial);

  final WebSocketState _initial;

  @override
  WebSocketState build() => _initial;

  @override
  void connect() {}

  @override
  void disconnect() {}
}

// ---------------------------------------------------------------------------
// Crypto
// ---------------------------------------------------------------------------

/// Override [cryptoProvider] with an initialized state (crypto ready).
///
/// Pass a full [CryptoState] via [cryptoState] for fine-grained control, or
/// use the simpler [isInitialized] flag for the common case.
Override cryptoOverride({bool isInitialized = true, CryptoState? cryptoState}) {
  return cryptoProvider.overrideWith(
    () => FakeCryptoNotifier(
      initial: cryptoState ?? CryptoState(isInitialized: isInitialized),
    ),
  );
}

class FakeCryptoNotifier extends CryptoNotifier {
  FakeCryptoNotifier({CryptoState initial = const CryptoState()})
    : _initial = initial;

  final CryptoState _initial;
  int initCallCount = 0;

  @override
  CryptoState build() => _initial;

  @override
  Future<void> initAndUploadKeys() async {
    initCallCount++;
  }

  @override
  Future<void> retryKeyUpload() async {}
}

// ---------------------------------------------------------------------------
// Biometric
// ---------------------------------------------------------------------------

/// Override [biometricProvider] with a fixed state (unavailable by default in
/// tests since [LocalAuthentication] is not available on host machines).
///
/// After the @riverpod migration the `Biometric` class extends a generated
/// `_$Biometric` parent, so the test fake overrides `build()` to return the
/// fixed state instead of mutating `state` from a constructor.
Override biometricOverride([
  BiometricState initialState = const BiometricState(isLoading: false),
]) {
  return biometricProvider.overrideWith(() => _FakeBiometric(initialState));
}

class _FakeBiometric extends Biometric {
  _FakeBiometric(this._initial);
  final BiometricState _initial;

  @override
  BiometricState build() => _initial;

  @override
  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value && state.isAvailable);
  }

  @override
  Future<bool> authenticate() async => true;
}

// ---------------------------------------------------------------------------
// Accessibility
// ---------------------------------------------------------------------------

/// Override [accessibilityProvider] with reduced motion enabled.
///
/// Use this in widget tests that render screens with [AnimatedGradientBackground]
/// (login, register, splash) so that [pumpAndSettle] does not time out waiting
/// for the continuous animation loop to stop.
Override accessibilityOverride([
  AccessibilityState initialState = const AccessibilityState(
    reducedMotion: true,
  ),
]) {
  return accessibilityProvider.overrideWith(
    () => _FakeAccessibility(initialState),
  );
}

class _FakeAccessibility extends Accessibility {
  _FakeAccessibility(this._initial);
  final AccessibilityState _initial;

  @override
  AccessibilityState build() => _initial;
}

// ---------------------------------------------------------------------------
// Convenience: all standard overrides in one list
// ---------------------------------------------------------------------------

/// Returns the typical set of provider overrides for widget tests:
/// logged-in auth, test server url, sample conversations, empty contacts,
/// disconnected websocket.
List<Override> standardOverrides({
  AuthState authState = const AuthState(
    isLoggedIn: true,
    userId: 'test-user-id',
    username: 'testuser',
    token: 'fake-jwt-token',
    refreshToken: 'fake-refresh-token',
  ),
  List<Conversation>? conversations,
}) {
  return [
    authOverride(authState),
    serverUrlOverride(),
    conversationsOverride(conversations ?? sampleConversations),
    contactsOverride(),
    webSocketOverride(),
    cryptoOverride(),
  ];
}
