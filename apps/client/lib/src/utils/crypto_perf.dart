/// Timeline-event helpers for the four crypto hot paths flagged by the
/// audit's P1-4 recommendation. Wraps the [dart:developer] `TimelineTask`
/// primitive so each call site stays a one-liner.
///
/// **Visibility**: only emits events under Flutter's `dart:developer`
/// instrumentation, which is a no-op in AOT release builds. You will see
/// these in DevTools' Timeline tab when running a profile or debug build;
/// production users pay nothing.
///
/// **Tagging**: every task uses the `filterKey: 'echo.crypto'` so a
/// reviewer can filter the timeline down to just our crypto work without
/// drowning in framework events. Pass `args` to attach structured
/// metadata visible in the event tooltip (e.g. peer id, conversation id).
library;

import 'dart:async';
import 'dart:developer' show TimelineTask;

/// Wrap [action] in a `TimelineTask(filterKey: 'echo.crypto')` named
/// [name]. Returns the action's result; rethrows any error after the
/// task is finished so timeline captures show the failure window.
Future<T> timedCryptoOp<T>(
  String name,
  Future<T> Function() action, {
  Map<String, Object?>? args,
}) async {
  final task = TimelineTask(filterKey: 'echo.crypto');
  task.start(name, arguments: args);
  try {
    return await action();
  } finally {
    task.finish();
  }
}
