import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/blocked_user.dart';
import '../models/contact.dart';
import '../services/debug_log_service.dart';
import 'authed_http.dart';
import 'conversations_provider.dart';
import 'server_url_provider.dart';

part 'contacts_provider.g.dart';

/// Sentinel used by [ContactsState.copyWith] to distinguish "not provided"
/// from an explicit `null` (which clears the error).
const Object _sentinel = Object();

class ContactsState {
  final List<Contact> contacts;
  final List<Contact> pendingRequests;
  final List<BlockedUser> blockedUsers;
  final bool isLoading;
  final bool isBlockedLoading;
  final String? error;

  const ContactsState({
    this.contacts = const [],
    this.pendingRequests = const [],
    this.blockedUsers = const [],
    this.isLoading = false,
    this.isBlockedLoading = false,
    this.error,
  });

  ContactsState copyWith({
    List<Contact>? contacts,
    List<Contact>? pendingRequests,
    List<BlockedUser>? blockedUsers,
    bool? isLoading,
    bool? isBlockedLoading,
    Object? error = _sentinel,
  }) {
    return ContactsState(
      contacts: contacts ?? this.contacts,
      pendingRequests: pendingRequests ?? this.pendingRequests,
      blockedUsers: blockedUsers ?? this.blockedUsers,
      isLoading: isLoading ?? this.isLoading,
      isBlockedLoading: isBlockedLoading ?? this.isBlockedLoading,
      error: error == _sentinel ? this.error : error as String?,
    );
  }
}

@Riverpod(keepAlive: true)
class Contacts extends _$Contacts with AuthedHttp<ContactsState> {
  bool _isPendingLoadInFlight = false;
  DateTime? _lastPendingLoadedAt;

  /// Monotonic generation counter for [loadContacts] (#599). Each call
  /// captures `++_loadGen` and bails before mutating state when the captured
  /// value no longer matches -- guards against a stale in-flight response
  /// overwriting fresh state when two reloads overlap.
  int _loadGen = 0;

  /// True after the provider has been disposed; gates state writes from
  /// async callbacks (the StateNotifier `mounted` check has no equivalent
  /// on Notifier so we track it manually).
  bool _disposed = false;

  @override
  ContactsState build() {
    ref.onDispose(() => _disposed = true);
    return const ContactsState();
  }

  String get _serverUrl => ref.read(serverUrlProvider);

  Future<void> loadContacts() async {
    state = state.copyWith(isLoading: true, error: null);
    final gen = ++_loadGen;
    try {
      final response = await authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/contacts'),
          headers: headersWithToken(token),
        ),
      );
      // Drop a stale response -- a newer call has been issued or the notifier
      // was disposed while awaiting.
      if (gen != _loadGen || _disposed) return;

      if (response.statusCode == 200) {
        final list = (jsonDecode(response.body) as List)
            .map((e) => Contact.fromJson(e as Map<String, dynamic>))
            .toList();
        state = state.copyWith(contacts: list, isLoading: false);
      } else {
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to load contacts',
        );
      }
    } catch (e) {
      if (gen != _loadGen || _disposed) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> loadPending({bool force = false}) async {
    if (_isPendingLoadInFlight) {
      return;
    }
    if (!force &&
        _lastPendingLoadedAt != null &&
        DateTime.now().difference(_lastPendingLoadedAt!) <
            const Duration(seconds: 8)) {
      return;
    }

    _isPendingLoadInFlight = true;
    try {
      final response = await authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/contacts/pending'),
          headers: headersWithToken(token),
        ),
      );
      if (response.statusCode == 200) {
        final list = (jsonDecode(response.body) as List)
            .map((e) => Contact.fromJson(e as Map<String, dynamic>))
            .toList();
        state = state.copyWith(pendingRequests: list);
        _lastPendingLoadedAt = DateTime.now();
      }
    } catch (e) {
      debugPrint('[Contacts] loadPending failed: $e');
      DebugLogService.instance.log(
        LogLevel.warning,
        'Contacts',
        'loadPending failed: $e',
      );
    } finally {
      _isPendingLoadInFlight = false;
    }
  }

  Future<void> sendRequest(String username) async {
    try {
      final response = await authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/contacts/request'),
          headers: headersWithToken(token),
          body: jsonEncode({'username': username}),
        ),
      );
      if (response.statusCode == 201 || response.statusCode == 200) {
        await loadContacts();
        await loadPending();
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          error: data['error'] as String? ?? 'Failed to send request',
        );
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> declineRequest(String contactId) async {
    try {
      final response = await authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/contacts/decline'),
          headers: headersWithToken(token),
          body: jsonEncode({'contact_id': contactId}),
        ),
      );
      if (response.statusCode == 200) {
        // Remove from local pending list immediately.
        state = state.copyWith(
          pendingRequests: state.pendingRequests
              .where((c) => c.id != contactId)
              .toList(),
        );
      } else {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          error: data['error'] as String? ?? 'Failed to decline request',
        );
      }
    } catch (e) {
      debugPrint('[Contacts] declineRequest failed for $contactId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Contacts',
        'declineRequest failed for $contactId: $e',
      );
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> acceptRequest(String contactId) async {
    try {
      final response = await authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/contacts/accept'),
          headers: headersWithToken(token),
          body: jsonEncode({'contact_id': contactId}),
        ),
      );
      if (response.statusCode != 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        state = state.copyWith(
          error: data['error'] as String? ?? 'Failed to accept request',
        );
        return;
      }
      await loadContacts();
      await loadPending();
      // Accepting a contact creates a DM conversation on the server —
      // reload conversations so the new DM appears in the chat list.
      ref.read(conversationsProvider.notifier).loadConversations();
    } catch (e) {
      debugPrint('[Contacts] acceptRequest failed for $contactId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Contacts',
        'acceptRequest failed for $contactId: $e',
      );
    }
  }

  Future<void> loadBlockedUsers() async {
    state = state.copyWith(isBlockedLoading: true, error: null);
    try {
      final response = await authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/contacts/blocked'),
          headers: headersWithToken(token),
        ),
      );
      if (response.statusCode == 200) {
        final list = (jsonDecode(response.body) as List)
            .map((e) => BlockedUser.fromJson(e as Map<String, dynamic>))
            .toList();
        state = state.copyWith(blockedUsers: list, isBlockedLoading: false);
      } else {
        state = state.copyWith(
          isBlockedLoading: false,
          error: 'Failed to load blocked users',
        );
      }
    } catch (e) {
      state = state.copyWith(isBlockedLoading: false, error: e.toString());
    }
  }

  Future<bool> unblockUser(String userId) async {
    try {
      final response = await authenticatedRequest(
        (token) => http.post(
          Uri.parse('$_serverUrl/api/contacts/unblock'),
          headers: headersWithToken(token),
          body: jsonEncode({'user_id': userId}),
        ),
      );
      if (response.statusCode == 200) {
        state = state.copyWith(
          blockedUsers: state.blockedUsers
              .where((u) => u.blockedId != userId)
              .toList(),
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[Contacts] unblockUser failed for $userId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Contacts',
        'unblockUser failed for $userId: $e',
      );
      return false;
    }
  }
}
