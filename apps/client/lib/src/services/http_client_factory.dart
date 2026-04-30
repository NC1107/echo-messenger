// Returns an http.Client appropriate for the current platform.
//
// On web, returns a BrowserClient with withCredentials = true so that the
// browser automatically attaches the HttpOnly refresh-token cookie on requests
// to the same origin.  On all other platforms (IO), returns a plain
// http.Client -- the native http stack handles credentials differently and
// refresh tokens travel in the request body.
export 'http_client_factory_stub.dart'
    if (dart.library.html) 'http_client_factory_web.dart';
