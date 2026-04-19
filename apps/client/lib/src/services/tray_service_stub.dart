/// Stub TrayService used on web and mobile platforms.
/// All methods are no-ops.
class TrayService {
  TrayService._();
  static final TrayService instance = TrayService._();

  static bool get isSupported => false;

  Future<void> init() async {}
  Future<void> dispose() async {}
  Future<void> updateBadge(int unreadCount) async {}
}
