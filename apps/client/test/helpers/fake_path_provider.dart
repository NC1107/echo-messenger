import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Fake [PathProviderPlatform] for unit tests.
///
/// Returns [basePath] for all directory queries so that code using
/// `getApplicationSupportDirectory()` (e.g. [UserDataDir]) works without
/// real platform channels.
class FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String basePath;

  FakePathProvider(this.basePath);

  @override
  Future<String?> getApplicationSupportPath() async => basePath;

  @override
  Future<String?> getTemporaryPath() async => basePath;

  @override
  Future<String?> getApplicationDocumentsPath() async => basePath;

  @override
  Future<String?> getApplicationCachePath() async => basePath;
}
