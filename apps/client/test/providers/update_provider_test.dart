import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/update_provider.dart';

void main() {
  group('UpdateState', () {
    test('default state is idle', () {
      const state = UpdateState();
      expect(state.status, UpdateStatus.idle);
      expect(state.latestVersion, isNull);
      expect(state.downloadUrl, isNull);
      expect(state.assetDownloadUrl, isNull);
      expect(state.downloadedFilePath, isNull);
      expect(state.downloadProgress, 0);
      expect(state.errorMessage, isNull);
      expect(state.dismissed, isFalse);
    });

    test('checking getter reflects status', () {
      const idle = UpdateState();
      expect(idle.checking, isFalse);

      const checking = UpdateState(status: UpdateStatus.checking);
      expect(checking.checking, isTrue);
    });

    test('copyWith preserves unchanged fields', () {
      const state = UpdateState(
        status: UpdateStatus.downloading,
        latestVersion: '1.2.3',
        downloadProgress: 0.5,
      );

      final copied = state.copyWith(downloadProgress: 0.75);
      expect(copied.status, UpdateStatus.downloading);
      expect(copied.latestVersion, '1.2.3');
      expect(copied.downloadProgress, 0.75);
    });

    test('copyWith can update all fields', () {
      const state = UpdateState();
      final updated = state.copyWith(
        status: UpdateStatus.readyToInstall,
        latestVersion: '2.0.0',
        downloadUrl: 'https://example.com',
        assetDownloadUrl: 'https://example.com/file.zip',
        downloadedFilePath: '/tmp/update.zip',
        downloadProgress: 1.0,
        errorMessage: null,
        dismissed: false,
      );

      expect(updated.status, UpdateStatus.readyToInstall);
      expect(updated.latestVersion, '2.0.0');
      expect(updated.downloadUrl, 'https://example.com');
      expect(updated.downloadedFilePath, '/tmp/update.zip');
      expect(updated.downloadProgress, 1.0);
    });
  });

  group('UpdateStatus', () {
    test('all status values are distinct', () {
      final values = UpdateStatus.values.toSet();
      expect(values, hasLength(UpdateStatus.values.length));
    });

    test('contains expected statuses', () {
      expect(
        UpdateStatus.values,
        containsAll([
          UpdateStatus.idle,
          UpdateStatus.checking,
          UpdateStatus.downloading,
          UpdateStatus.readyToInstall,
          UpdateStatus.installing,
          UpdateStatus.error,
        ]),
      );
    });
  });
}
