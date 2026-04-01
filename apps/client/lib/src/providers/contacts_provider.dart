import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/contact.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';

class ContactsState {
  final List<Contact> contacts;
  final List<Contact> pendingRequests;
  final bool isLoading;
  final String? error;

  const ContactsState({
    this.contacts = const [],
    this.pendingRequests = const [],
    this.isLoading = false,
    this.error,
  });

  ContactsState copyWith({
    List<Contact>? contacts,
    List<Contact>? pendingRequests,
    bool? isLoading,
    String? error,
  }) {
    return ContactsState(
      contacts: contacts ?? this.contacts,
      pendingRequests: pendingRequests ?? this.pendingRequests,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class ContactsNotifier extends StateNotifier<ContactsState> {
  final Ref ref;

  ContactsNotifier(this.ref) : super(const ContactsState());

  String get _serverUrl => ref.read(serverUrlProvider);
  String? get _token => ref.read(authProvider).token;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ${_token ?? ""}',
  };

  Future<void> loadContacts() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/api/contacts'),
        headers: _headers,
      );
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
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> loadPending() async {
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/api/contacts/pending'),
        headers: _headers,
      );
      if (response.statusCode == 200) {
        final list = (jsonDecode(response.body) as List)
            .map((e) => Contact.fromJson(e as Map<String, dynamic>))
            .toList();
        state = state.copyWith(pendingRequests: list);
      }
    } catch (_) {}
  }

  Future<void> sendRequest(String username) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/contacts/request'),
        headers: _headers,
        body: jsonEncode({'username': username}),
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

  Future<void> acceptRequest(String contactId) async {
    try {
      await http.post(
        Uri.parse('$_serverUrl/api/contacts/accept'),
        headers: _headers,
        body: jsonEncode({'contact_id': contactId}),
      );
      await loadContacts();
      await loadPending();
    } catch (_) {}
  }
}

final contactsProvider = StateNotifierProvider<ContactsNotifier, ContactsState>(
  (ref) {
    return ContactsNotifier(ref);
  },
);
