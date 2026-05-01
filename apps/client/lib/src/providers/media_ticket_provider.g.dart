// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_ticket_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$mediaTicketHash() => r'34afad4bbeb8a7e46a64b9afd6771a2313517019';

/// Provides a reusable media ticket for authenticating web `<img>` requests.
///
/// The ticket is fetched once after login and refreshed every 4 minutes
/// (server TTL is 5 minutes).  On native platforms the Authorization header
/// is used instead, so this provider is only consumed on web.
///
/// Migrated from `StateNotifier` to `@riverpod` Notifier (audit 2026-04-30).
/// Singleton lifetime via `keepAlive: true` because the refresh timer must
/// survive moments when no widget is watching the ticket.
///
/// Copied from [MediaTicket].
@ProviderFor(MediaTicket)
final mediaTicketProvider = NotifierProvider<MediaTicket, String?>.internal(
  MediaTicket.new,
  name: r'mediaTicketProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$mediaTicketHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$MediaTicket = Notifier<String?>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
