// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'canvas_authority_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$canvasAuthorityNotifierHash() =>
    r'2e132c6693f0f07a81dad2847d85501b6004ae45';

/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

abstract class _$CanvasAuthorityNotifier extends BuildlessNotifier<int?> {
  late final String channelId;

  int? build(String channelId);
}

/// Tracks the canvas authority device for a given voice-lounge channel.
///
/// Authority is the device_id (int) of the user's device that currently holds
/// the write lock for canvas events. When null, nobody has claimed yet and any
/// device may write. When set, only the named device's sends reach the server
/// (others are silently dropped server-side; the client skips the send early).
///
/// Updated by inbound `canvas_authority_changed` WS events dispatched from
/// [WsMessageHandler._handleCanvasAuthorityChanged].
///
/// See docs/voice-lounge/03-multi-device.md — Option C decision.
///
/// Copied from [CanvasAuthorityNotifier].
@ProviderFor(CanvasAuthorityNotifier)
const canvasAuthorityNotifierProvider = CanvasAuthorityNotifierFamily();

/// Tracks the canvas authority device for a given voice-lounge channel.
///
/// Authority is the device_id (int) of the user's device that currently holds
/// the write lock for canvas events. When null, nobody has claimed yet and any
/// device may write. When set, only the named device's sends reach the server
/// (others are silently dropped server-side; the client skips the send early).
///
/// Updated by inbound `canvas_authority_changed` WS events dispatched from
/// [WsMessageHandler._handleCanvasAuthorityChanged].
///
/// See docs/voice-lounge/03-multi-device.md — Option C decision.
///
/// Copied from [CanvasAuthorityNotifier].
class CanvasAuthorityNotifierFamily extends Family<int?> {
  /// Tracks the canvas authority device for a given voice-lounge channel.
  ///
  /// Authority is the device_id (int) of the user's device that currently holds
  /// the write lock for canvas events. When null, nobody has claimed yet and any
  /// device may write. When set, only the named device's sends reach the server
  /// (others are silently dropped server-side; the client skips the send early).
  ///
  /// Updated by inbound `canvas_authority_changed` WS events dispatched from
  /// [WsMessageHandler._handleCanvasAuthorityChanged].
  ///
  /// See docs/voice-lounge/03-multi-device.md — Option C decision.
  ///
  /// Copied from [CanvasAuthorityNotifier].
  const CanvasAuthorityNotifierFamily();

  /// Tracks the canvas authority device for a given voice-lounge channel.
  ///
  /// Authority is the device_id (int) of the user's device that currently holds
  /// the write lock for canvas events. When null, nobody has claimed yet and any
  /// device may write. When set, only the named device's sends reach the server
  /// (others are silently dropped server-side; the client skips the send early).
  ///
  /// Updated by inbound `canvas_authority_changed` WS events dispatched from
  /// [WsMessageHandler._handleCanvasAuthorityChanged].
  ///
  /// See docs/voice-lounge/03-multi-device.md — Option C decision.
  ///
  /// Copied from [CanvasAuthorityNotifier].
  CanvasAuthorityNotifierProvider call(String channelId) {
    return CanvasAuthorityNotifierProvider(channelId);
  }

  @override
  CanvasAuthorityNotifierProvider getProviderOverride(
    covariant CanvasAuthorityNotifierProvider provider,
  ) {
    return call(provider.channelId);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'canvasAuthorityNotifierProvider';
}

/// Tracks the canvas authority device for a given voice-lounge channel.
///
/// Authority is the device_id (int) of the user's device that currently holds
/// the write lock for canvas events. When null, nobody has claimed yet and any
/// device may write. When set, only the named device's sends reach the server
/// (others are silently dropped server-side; the client skips the send early).
///
/// Updated by inbound `canvas_authority_changed` WS events dispatched from
/// [WsMessageHandler._handleCanvasAuthorityChanged].
///
/// See docs/voice-lounge/03-multi-device.md — Option C decision.
///
/// Copied from [CanvasAuthorityNotifier].
class CanvasAuthorityNotifierProvider
    extends NotifierProviderImpl<CanvasAuthorityNotifier, int?> {
  /// Tracks the canvas authority device for a given voice-lounge channel.
  ///
  /// Authority is the device_id (int) of the user's device that currently holds
  /// the write lock for canvas events. When null, nobody has claimed yet and any
  /// device may write. When set, only the named device's sends reach the server
  /// (others are silently dropped server-side; the client skips the send early).
  ///
  /// Updated by inbound `canvas_authority_changed` WS events dispatched from
  /// [WsMessageHandler._handleCanvasAuthorityChanged].
  ///
  /// See docs/voice-lounge/03-multi-device.md — Option C decision.
  ///
  /// Copied from [CanvasAuthorityNotifier].
  CanvasAuthorityNotifierProvider(String channelId)
    : this._internal(
        () => CanvasAuthorityNotifier()..channelId = channelId,
        from: canvasAuthorityNotifierProvider,
        name: r'canvasAuthorityNotifierProvider',
        debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
            ? null
            : _$canvasAuthorityNotifierHash,
        dependencies: CanvasAuthorityNotifierFamily._dependencies,
        allTransitiveDependencies:
            CanvasAuthorityNotifierFamily._allTransitiveDependencies,
        channelId: channelId,
      );

  CanvasAuthorityNotifierProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.channelId,
  }) : super.internal();

  final String channelId;

  @override
  int? runNotifierBuild(covariant CanvasAuthorityNotifier notifier) {
    return notifier.build(channelId);
  }

  @override
  Override overrideWith(CanvasAuthorityNotifier Function() create) {
    return ProviderOverride(
      origin: this,
      override: CanvasAuthorityNotifierProvider._internal(
        () => create()..channelId = channelId,
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        channelId: channelId,
      ),
    );
  }

  @override
  NotifierProviderElement<CanvasAuthorityNotifier, int?> createElement() {
    return _CanvasAuthorityNotifierProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is CanvasAuthorityNotifierProvider &&
        other.channelId == channelId;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, channelId.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin CanvasAuthorityNotifierRef on NotifierProviderRef<int?> {
  /// The parameter `channelId` of this provider.
  String get channelId;
}

class _CanvasAuthorityNotifierProviderElement
    extends NotifierProviderElement<CanvasAuthorityNotifier, int?>
    with CanvasAuthorityNotifierRef {
  _CanvasAuthorityNotifierProviderElement(super.provider);

  @override
  String get channelId => (origin as CanvasAuthorityNotifierProvider).channelId;
}

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
