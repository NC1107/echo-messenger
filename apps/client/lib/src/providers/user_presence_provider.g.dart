// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'user_presence_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$userPresenceHash() => r'03fd47f477919993466a00bcc478ab9baf98ae1d';

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

/// See also [userPresence].
@ProviderFor(userPresence)
const userPresenceProvider = UserPresenceFamily();

/// See also [userPresence].
class UserPresenceFamily extends Family<UserPresence> {
  /// See also [userPresence].
  const UserPresenceFamily();

  /// See also [userPresence].
  UserPresenceProvider call(String userId) {
    return UserPresenceProvider(userId);
  }

  @override
  UserPresenceProvider getProviderOverride(
    covariant UserPresenceProvider provider,
  ) {
    return call(provider.userId);
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'userPresenceProvider';
}

/// See also [userPresence].
class UserPresenceProvider extends Provider<UserPresence> {
  /// See also [userPresence].
  UserPresenceProvider(String userId)
    : this._internal(
        (ref) => userPresence(ref as UserPresenceRef, userId),
        from: userPresenceProvider,
        name: r'userPresenceProvider',
        debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
            ? null
            : _$userPresenceHash,
        dependencies: UserPresenceFamily._dependencies,
        allTransitiveDependencies:
            UserPresenceFamily._allTransitiveDependencies,
        userId: userId,
      );

  UserPresenceProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.userId,
  }) : super.internal();

  final String userId;

  @override
  Override overrideWith(
    UserPresence Function(UserPresenceRef provider) create,
  ) {
    return ProviderOverride(
      origin: this,
      override: UserPresenceProvider._internal(
        (ref) => create(ref as UserPresenceRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        userId: userId,
      ),
    );
  }

  @override
  ProviderElement<UserPresence> createElement() {
    return _UserPresenceProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is UserPresenceProvider && other.userId == userId;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, userId.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin UserPresenceRef on ProviderRef<UserPresence> {
  /// The parameter `userId` of this provider.
  String get userId;
}

class _UserPresenceProviderElement extends ProviderElement<UserPresence>
    with UserPresenceRef {
  _UserPresenceProviderElement(super.provider);

  @override
  String get userId => (origin as UserPresenceProvider).userId;
}

// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
