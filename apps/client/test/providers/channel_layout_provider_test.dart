import 'package:echo_app/src/providers/channel_layout_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke tests for the bar/column channel layout preference (PR1 of the
/// Slack/Discord column-layout series).  Persistence + load round-trip
/// only; visual wiring lands in PR3 and is tested separately.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults to bar layout', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(channelLayoutProvider), ChannelLayout.bar);
  });

  test('setLayout(column) persists across container rebuilds', () async {
    var container = ProviderContainer();
    await container
        .read(channelLayoutProvider.notifier)
        .setLayout(ChannelLayout.column);
    expect(container.read(channelLayoutProvider), ChannelLayout.column);
    container.dispose();

    // Fresh container reads from the persisted backing store. The Notifier
    // hydrates asynchronously in build(), so pump the microtask queue.
    container = ProviderContainer();
    addTearDown(container.dispose);
    // Trigger the build by reading.
    container.read(channelLayoutProvider);
    // Allow the async _load() inside build() to complete.
    await Future<void>.delayed(Duration.zero);
    expect(container.read(channelLayoutProvider), ChannelLayout.column);
  });

  test('setLayout is a no-op when the value is unchanged', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(channelLayoutProvider.notifier);
    await notifier.setLayout(ChannelLayout.bar); // same as default
    expect(container.read(channelLayoutProvider), ChannelLayout.bar);
  });

  test('legacy / unknown stored value falls back to bar', () async {
    SharedPreferences.setMockInitialValues({'channel_layout': 'side'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(channelLayoutProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(channelLayoutProvider), ChannelLayout.bar);
  });
}
