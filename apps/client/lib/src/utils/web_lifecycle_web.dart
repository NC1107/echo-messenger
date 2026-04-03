import 'dart:js_interop';
import 'package:web/web.dart' as web;

void Function()? _currentCallback;
JSFunction? _jsHandler;

void registerBeforeUnload(void Function() onUnload) {
  _currentCallback = onUnload;
  _jsHandler = ((web.Event event) {
    _currentCallback?.call();
  }).toJS;
  web.window.addEventListener('beforeunload', _jsHandler);
}

void unregisterBeforeUnload() {
  if (_jsHandler != null) {
    web.window.removeEventListener('beforeunload', _jsHandler);
    _jsHandler = null;
  }
  _currentCallback = null;
}
