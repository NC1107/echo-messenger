import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/router/app_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/mock_providers.dart';

/// Exposes the container's [Ref] so the auth-gate decision (which reads
/// `authProvider` and mutates `pendingDeepLinkProvider`) can be driven
/// directly in unit tests.
final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  group('authGateRedirect (auth gate)', () {
    late ProviderContainer container;

    ProviderContainer makeContainer(AuthState auth) {
      final c = ProviderContainer(overrides: [authOverride(auth)]);
      addTearDown(c.dispose);
      return c;
    }

    String? redirect(ProviderContainer c, String location, [Uri? uri]) {
      return authGateRedirect(
        c.read(_refProvider),
        location,
        uri ?? Uri.parse(location),
      );
    }

    // -----------------------------------------------------------------------
    // Splash is always a pass-through.
    // -----------------------------------------------------------------------
    test('splash route never redirects regardless of auth', () {
      expect(redirect(makeContainer(loggedOutAuthState), '/splash'), isNull);
      expect(redirect(makeContainer(loggedInAuthState), '/splash'), isNull);
    });

    // -----------------------------------------------------------------------
    // Logged-out user hitting a protected route -> /login.
    // -----------------------------------------------------------------------
    test('logged-out on protected route redirects to /login', () {
      container = makeContainer(loggedOutAuthState);
      expect(redirect(container, '/settings'), '/login');
      expect(redirect(container, '/contacts'), '/login');
    });

    test('logged-out on /home redirects to /login without capturing it', () {
      container = makeContainer(loggedOutAuthState);
      expect(redirect(container, '/home'), '/login');
      // /home is the post-login destination, not a deep link worth capturing.
      expect(container.read(pendingDeepLinkProvider), isNull);
    });

    // -----------------------------------------------------------------------
    // Logged-out deep link is captured for post-login replay.
    // -----------------------------------------------------------------------
    test('logged-out deep link is captured and redirected to /login', () {
      container = makeContainer(loggedOutAuthState);
      final result = redirect(
        container,
        '/group-info/abc',
        Uri.parse('/group-info/abc?ref=share'),
      );
      expect(result, '/login');
      expect(
        container.read(pendingDeepLinkProvider),
        '/group-info/abc?ref=share',
      );
    });

    // -----------------------------------------------------------------------
    // Public auth routes stay reachable while logged out.
    // -----------------------------------------------------------------------
    test('logged-out on public auth routes passes through', () {
      container = makeContainer(loggedOutAuthState);
      for (final route in const [
        '/login',
        '/register',
        '/forgot-password',
        '/reset-password',
        '/auth/pick-account',
      ]) {
        expect(redirect(container, route), isNull, reason: route);
      }
      // No deep link captured for any of them.
      expect(container.read(pendingDeepLinkProvider), isNull);
    });

    test('logged-out on join/invite/username routes passes through', () {
      container = makeContainer(loggedOutAuthState);
      for (final route in const [
        '/join/group-1',
        '/invite/group-1',
        '/invite/t/token-1',
        '/u/alice',
      ]) {
        expect(redirect(container, route), isNull, reason: route);
      }
    });

    test('logged-out on /onboarding passes through', () {
      container = makeContainer(loggedOutAuthState);
      expect(redirect(container, '/onboarding'), isNull);
    });

    // -----------------------------------------------------------------------
    // Logged-in user bounced off auth routes back to home.
    // -----------------------------------------------------------------------
    test('logged-in on /login redirects to /home', () {
      container = makeContainer(loggedInAuthState);
      expect(redirect(container, '/login'), '/home');
    });

    test('logged-in on other auth routes redirects to /home', () {
      container = makeContainer(loggedInAuthState);
      expect(redirect(container, '/register'), '/home');
      expect(redirect(container, '/auth/pick-account'), '/home');
    });

    // -----------------------------------------------------------------------
    // Logged-in user on a protected route stays put.
    // -----------------------------------------------------------------------
    test('logged-in on protected route stays (no redirect)', () {
      container = makeContainer(loggedInAuthState);
      expect(redirect(container, '/home'), isNull);
      expect(redirect(container, '/settings'), isNull);
      expect(redirect(container, '/group-info/abc'), isNull);
    });

    // -----------------------------------------------------------------------
    // Deep-link capture then replay: logged-out capture, login, replay.
    // -----------------------------------------------------------------------
    test('captured deep link is replayed when logged-in hits /login', () {
      // 1. Logged out: hitting a protected deep link captures it.
      final out = makeContainer(loggedOutAuthState);
      expect(redirect(out, '/settings'), '/login');
      final captured = out.read(pendingDeepLinkProvider);
      expect(captured, '/settings');

      // 2. Seed a fresh logged-in container with that captured link, then the
      //    auth route resolves to the deep link and clears it.
      final inn = makeContainer(loggedInAuthState);
      inn.read(pendingDeepLinkProvider.notifier).set(captured);
      expect(redirect(inn, '/login'), '/settings');
      // Replayed link is consumed, so a second pass falls back to /home.
      expect(inn.read(pendingDeepLinkProvider), isNull);
      expect(redirect(inn, '/login'), '/home');
    });

    // -----------------------------------------------------------------------
    // Onboarding gate: completed -> bounce home; not completed -> allow.
    // -----------------------------------------------------------------------
    test('logged-in with completed onboarding is bounced off /onboarding', () {
      container = makeContainer(
        const AuthState(
          isLoggedIn: true,
          userId: 'u1',
          onboardingCompleted: true,
        ),
      );
      expect(redirect(container, '/onboarding'), '/home');
    });

    test('logged-in new account is allowed through /onboarding', () {
      container = makeContainer(
        const AuthState(
          isLoggedIn: true,
          userId: 'u1',
          onboardingCompleted: false,
        ),
      );
      expect(redirect(container, '/onboarding'), isNull);
    });
  });
}
