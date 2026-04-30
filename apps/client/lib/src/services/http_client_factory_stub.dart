import 'package:http/http.dart' as http;

/// Native (IO) implementation: plain [http.Client].
http.Client buildHttpClient() => http.Client();
