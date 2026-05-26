// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'livekit_voice_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$liveKitVoiceNotifierHash() =>
    r'02a029d7f9f884457c93289991431636c6093894';

/// Facade for the LiveKit voice notifier — owns shared state, connection
/// lifecycle (`joinChannel` / `leaveChannel` / `dispose`), the room event
/// listener, peer-state sync, audio-level polling, and the LiveKit JWT
/// fetch. AV controls (mic / camera / screen share / video quality) live
/// in [LiveKitVoiceAvControlsMixin] in `livekit_voice_av_controls.dart`.
///
/// Copied from [LiveKitVoiceNotifier].
@ProviderFor(LiveKitVoiceNotifier)
final liveKitVoiceNotifierProvider =
    NotifierProvider<LiveKitVoiceNotifier, LiveKitVoiceState>.internal(
      LiveKitVoiceNotifier.new,
      name: r'liveKitVoiceNotifierProvider',
      debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
          ? null
          : _$liveKitVoiceNotifierHash,
      dependencies: null,
      allTransitiveDependencies: null,
    );

typedef _$LiveKitVoiceNotifier = Notifier<LiveKitVoiceState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package
