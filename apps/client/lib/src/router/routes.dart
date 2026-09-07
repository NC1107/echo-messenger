/// Centralised GoRouter path constants.
///
/// Kept dependency-free so any screen can import it for typo-safe navigation
/// (`context.go(routeHome)`) without creating an import cycle back into
/// [app_router] (which imports every screen). Parametrised routes
/// (`/group-info/:id`, `/safety-number/:peerId`, profile deep links) stay as
/// inline interpolated strings since they carry an id.
library;

const routeSplash = '/splash';
const routeLogin = '/login';
const routeAccountPicker = '/auth/pick-account';
const routeRegister = '/register';
const routeForgotPassword = '/forgot-password';
const routeResetPassword = '/reset-password';
const routeOnboarding = '/onboarding';
const routeHome = '/home';
const routeContacts = '/contacts';
const routeThreads = '/threads';
const routeCreateGroup = '/create-group';
const routeDiscoverGroups = '/discover-groups';
const routeSettings = '/settings';
const routeSaved = '/saved';
const routeAdmin = '/admin';
