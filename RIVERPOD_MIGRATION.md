# Riverpod modernization — migration playbook

Status: **5 of 22 providers migrated** in this PR. The remaining 17 are
deliberately deferred — they pair with Sprint 4 widget refactors (#512,
#628, #693) so each consumer surface is edited only once.

## What this is

Echo was already on `flutter_riverpod ^2.6.0` but every stateful provider
used the legacy `StateNotifier` API. This PR adopts:

- `@Riverpod` annotation + `riverpod_generator` (codegen)
- `Notifier` / `AsyncNotifier` API instead of `StateNotifier`
- `ref.onDispose` for lifecycle cleanup instead of overridden `dispose()`
- `keepAlive: true` for singletons that need to outlive transient
  un-watch periods (auto-dispose is the default for `@riverpod`)

## Done in this PR

| Provider | Class name | Generated provider | Alias kept? | Notes |
|---|---|---|---|---|
| `accessibility_provider` | `Accessibility` | `accessibilityProvider` | n/a — same name | first migrated, simplest |
| `gif_playback_provider` | `GifPlayback` | `gifPlaybackProvider` | n/a | callback `WidgetsBindingObserver` via `ref.onDispose` |
| `theme_provider` | `AppTheme` | `appThemeProvider` | `themeProvider` | renamed to avoid colliding with Material `Theme` |
| `theme_provider` (layout) | `MessageLayoutNotifier` | `messageLayoutNotifierProvider` | `messageLayoutProvider` | `MessageLayout` enum already taken |
| `biometric_provider` | `Biometric` | `biometricProvider` | n/a | keepAlive for lock-session timer |
| `media_ticket_provider` | `MediaTicket` | `mediaTicketProvider` | n/a | refresh `Timer` cancelled via `ref.onDispose` |

## Not yet migrated (17 providers)

### Defer to Sprint 4 — coupled to god-widget refactors

These should land in the same PRs that split their consumer widgets, so the
call-site sweep happens once:

| Provider | Coupled refactor | Reason |
|---|---|---|
| `chat_provider` | #512 ChatPanel split | 600+ LoC, 30+ consumer widgets, biggest blast radius |
| `livekit_voice_provider` | #693 voice_lounge split | Consumer is `voice_lounge_screen.dart` (2683 LoC) |
| `voice_rtc_provider` | #693 | Same consumer |
| `voice_settings_provider` | #693 | Same consumer + persistence layer |
| `screen_share_provider` | #693 | Same consumer |
| `ws_message_handler` | #352 ws/handler.rs split (server-side) + chat split | 901-line god orchestrator; cross-touches every state-mutation surface |

### Defer to Sprint 2/3 — stable but high call-site count

These are mechanically straightforward but touch many consumers, so batch
them with related work:

| Provider | Defer reason |
|---|---|
| `auth_provider` | 32 KB file; touches every authenticated request site |
| `crypto_provider` | Foundation for chat_provider — migrate together |
| `server_url_provider` | Cross-talks with auth + websocket; multi-step transactions |
| `conversations_provider` | 628 LoC, list rendering hot path |
| `contacts_provider` | Already noted in #599 for stale-reload race; do alongside that fix |
| `channels_provider` | Tied to ws_message_handler events |
| `canvas_provider` | Tied to ws CanvasEvent dispatch |
| `websocket_provider` | Lifecycle-heavy; coordinate with #696 follow-up |

### Defer to Sprint 4 (medium-priority leaves)

| Provider | Reason |
|---|---|
| `privacy_provider` | 224 LoC, persistence-heavy; pairs with settings UI refactors |
| `update_provider` | 293 LoC; checks for app updates, has its own retry loop |

## Migration recipe

For each provider:

### 1. Edit the file

```dart
// BEFORE
class FooNotifier extends StateNotifier<FooState> {
  FooNotifier() : super(const FooState()) {
    _load();
  }
  Future<void> _load() async { ... }
  Future<void> setBar(bool v) async { state = state.copyWith(bar: v); ... }
}

final fooProvider = StateNotifierProvider<FooNotifier, FooState>((ref) {
  return FooNotifier();
});
```

```dart
// AFTER
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'foo_provider.g.dart';

@Riverpod(keepAlive: true)
class Foo extends _$Foo {
  @override
  FooState build() {
    _load();
    return const FooState();
  }

  Future<void> _load() async { ... }
  Future<void> setBar(bool v) async { state = state.copyWith(bar: v); ... }
}
```

### 2. If the class name collides with something else in importing files

Rename the class and add an alias for the historical provider symbol:

```dart
@Riverpod(keepAlive: true)
class AppFoo extends _$AppFoo {
  // ...
}

/// Back-compat: existing call sites still refer to `fooProvider`.
final fooProvider = appFooProvider;
```

### 3. Lifecycle hooks

Replace any of these:

| Old | New |
|---|---|
| `super.dispose()` override | `ref.onDispose(() { ... })` inside `build()` |
| `WidgetsBindingObserver` mixin | callback-based observer + `ref.onDispose(() => removeObserver(...))` |
| Constructor that calls `_load()` | Call `_load()` from inside `build()` before returning the initial value |

### 4. Run codegen

```bash
cd apps/client
dart run build_runner build --delete-conflicting-outputs
```

Commit the generated `.g.dart` file alongside the edit.

### 5. Update tests

The override pattern changes:

```dart
// BEFORE
fooProvider.overrideWith((ref) => _FakeFooNotifier())

class _FakeFooNotifier extends FooNotifier {
  _FakeFooNotifier() {
    state = const FooState(bar: true);   // mutate from constructor
  }
}
```

```dart
// AFTER
fooProvider.overrideWith(_FakeFoo.new)   // pass the class constructor

class _FakeFoo extends Foo {
  @override
  FooState build() => const FooState(bar: true);  // override build()
}
```

Test code that used to do:

```dart
final notifier = FooNotifier();
await Future<void>.delayed(...);
expect(notifier.state, ...);
```

Becomes:

```dart
final container = ProviderContainer();
addTearDown(container.dispose);
container.read(fooProvider);     // triggers build()
await _flushLoad();              // wait for async _load() to settle
expect(container.read(fooProvider), ...);
```

## Common gotchas

- **`@riverpod` defaults to auto-dispose**. Use `@Riverpod(keepAlive: true)`
  for any provider that holds state that should survive moments without
  watchers (timers, accumulators, anything cached from disk).
- **Class name → provider name is mechanical**: `class Foo` → `fooProvider`,
  `class AppFoo` → `appFooProvider`. There is no way to override this in
  the annotation, so pick the class name carefully.
- **Don't shadow Flutter built-ins**: `class Theme` collides with Material's
  `Theme` widget; `class Notifier` would shadow Riverpod's own; etc. The
  analyzer catches these but only after consumers import the provider.
- **`ref` is available inside Notifier methods** — no need to inject it
  through a constructor parameter like StateNotifier did. `ref.read`,
  `ref.watch`, `ref.listen` all work the same.
- **`state` is the state of THIS notifier**, not the wrapped value's
  property. `state = state.copyWith(...)` is unchanged from StateNotifier.
- **`build()` runs once per provider instantiation**, including any side
  effects like `_load()` or `ref.listen(...)`. Subsequent `state = ...`
  mutations don't re-run `build()`.

## Validation per migrated provider

For each PR that migrates a provider:

1. `dart format --set-exit-if-changed apps/client/lib/src/providers/foo_provider.dart`
2. `flutter analyze --fatal-infos` (full project — catches consumer breakage)
3. `flutter test test/providers/foo_provider_test.dart`
4. Spot-check at least one consumer widget test that watches the provider

## Related issues

- audit recommendations: SPRINT_PLAN.md "Riverpod modernization" section
- coupled refactors: #512 (ChatPanel), #693 (voice_lounge), #628 (god widgets)
- ws_message_handler god orchestrator: #352
