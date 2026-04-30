import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

/// Web implementation: [BrowserClient] with [withCredentials] enabled so the
/// browser attaches the HttpOnly SameSite=Strict refresh-token cookie on
/// every request to the same origin.
http.Client buildHttpClient() => BrowserClient()..withCredentials = true;
