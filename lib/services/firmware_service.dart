import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:http/http.dart' as http;
import 'package:mcumgr_flutter/mcumgr_flutter.dart' as mcumgr;
import 'package:nordic_dfu/nordic_dfu.dart';
import 'package:path_provider/path_provider.dart';

/// Metadata about a firmware release available on GitHub.
class FirmwareInfo {
  final String version;
  final String tagName;
  final String downloadUrl;
  final int size;
  final String? releaseNotes;

  const FirmwareInfo({
    required this.version,
    required this.tagName,
    required this.downloadUrl,
    required this.size,
    this.releaseNotes,
  });
}

/// Checks for, downloads, and installs Omi CV1 firmware updates.
///
/// Uses GitHub Releases API to find the latest CV1 OTA zip, then
/// auto-detects DFU method: MCUmgr (SMP service) or Nordic Legacy DFU.
class FirmwareService extends ChangeNotifier {
  static const _gitHubReleasesUrl =
      'https://api.github.com/repos/BasedHardware/omi/releases';
  static const _tagPrefix = 'Omi_CV1_';

  /// SMP service UUID indicating MCUmgr DFU support.
  static const smpServiceUuid = '8D53DC1D-1DB7-4CD3-868B-8A527460AA84';

  final ValueNotifier<bool> isChecking = ValueNotifier(false);
  final ValueNotifier<bool> isDownloading = ValueNotifier(false);
  final ValueNotifier<bool> isInstalling = ValueNotifier(false);
  final ValueNotifier<int> downloadProgress = ValueNotifier(0);
  final ValueNotifier<int> installProgress = ValueNotifier(0);
  final ValueNotifier<String?> error = ValueNotifier(null);

  FirmwareInfo? latestInfo;
  String? currentVersion;
  String? downloadedZipPath;

  /// Whether a downloaded zip is ready to install.
  bool get hasDownloadedFirmware => downloadedZipPath != null;

  /// Check GitHub releases for latest CV1 firmware.
  /// Release tag pattern: "Omi_CV1_vX.Y.Z"
  /// Asset name pattern: contains "OTA" and ends with ".zip"
  Future<FirmwareInfo?> checkLatest() async {
    isChecking.value = true;
    error.value = null;
    notifyListeners();

    try {
      final response = await http
          .get(
            Uri.parse(_gitHubReleasesUrl),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        error.value = 'GitHub API error: HTTP ${response.statusCode}';
        return null;
      }

      final releases = jsonDecode(response.body) as List<dynamic>;

      // Filter to CV1 releases and find the latest one.
      Map<String, dynamic>? latestRelease;
      for (final release in releases) {
        final tag = release['tag_name'] as String? ?? '';
        if (tag.startsWith(_tagPrefix)) {
          latestRelease = release as Map<String, dynamic>;
          break; // GitHub returns releases newest-first
        }
      }

      if (latestRelease == null) {
        error.value = 'CV1ファームウェアのリリースが見つかりません';
        return null;
      }

      // Find OTA zip asset.
      final assets = latestRelease['assets'] as List<dynamic>? ?? [];
      Map<String, dynamic>? otaAsset;
      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.contains('ota') && name.endsWith('.zip')) {
          otaAsset = asset as Map<String, dynamic>;
          break;
        }
      }

      if (otaAsset == null) {
        error.value = 'OTAアセットが見つかりません';
        return null;
      }

      final tagName = latestRelease['tag_name'] as String;
      // Extract version from tag: "Omi_CV1_v3.0.17" -> "3.0.17"
      final version = tagName.startsWith('${_tagPrefix}v')
          ? tagName.substring(_tagPrefix.length + 1)
          : tagName.substring(_tagPrefix.length);

      latestInfo = FirmwareInfo(
        version: version,
        tagName: tagName,
        downloadUrl: otaAsset['browser_download_url'] as String,
        size: otaAsset['size'] as int? ?? 0,
        releaseNotes: latestRelease['body'] as String?,
      );

      return latestInfo;
    } catch (e) {
      error.value = 'アップデート確認エラー: $e';
      return null;
    } finally {
      isChecking.value = false;
      notifyListeners();
    }
  }

  /// Download the OTA zip to temp directory.
  Future<String?> download(FirmwareInfo info) async {
    isDownloading.value = true;
    downloadProgress.value = 0;
    error.value = null;
    downloadedZipPath = null;
    notifyListeners();

    try {
      final request = http.Request('GET', Uri.parse(info.downloadUrl));
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30),
      );

      if (streamedResponse.statusCode != 200) {
        error.value = 'ダウンロードエラー: HTTP ${streamedResponse.statusCode}';
        return null;
      }

      final totalBytes = streamedResponse.contentLength ?? info.size;
      final tempDir = await getTemporaryDirectory();
      final zipFile = File('${tempDir.path}/firmware.zip');

      int receivedBytes = 0;
      final sink = zipFile.openWrite();

      try {
        await for (final chunk in streamedResponse.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (totalBytes > 0) {
            downloadProgress.value = ((receivedBytes / totalBytes) * 100)
                .round()
                .clamp(0, 100);
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }

      downloadProgress.value = 100;
      downloadedZipPath = zipFile.path;
      notifyListeners();
      debugPrint('[FW] Downloaded ${zipFile.path} ($receivedBytes bytes)');
      return zipFile.path;
    } catch (e) {
      error.value = 'ダウンロードエラー: $e';
      return null;
    } finally {
      isDownloading.value = false;
      notifyListeners();
    }
  }

  /// Perform DFU update. Auto-detects MCUmgr vs Legacy DFU based on
  /// whether the device advertises the SMP service.
  Future<void> performUpdate(
    String deviceId,
    String zipPath, {
    required bool hasSmpService,
  }) async {
    isInstalling.value = true;
    installProgress.value = 0;
    error.value = null;
    notifyListeners();

    try {
      if (hasSmpService) {
        await _performMcumgrUpdate(deviceId, zipPath);
      } else {
        await _performLegacyDfu(deviceId, zipPath);
      }
    } catch (e) {
      error.value = 'インストールエラー: $e';
      debugPrint('[FW] DFU error: $e');
    } finally {
      isInstalling.value = false;
      notifyListeners();
    }
  }

  /// MCUmgr SMP DFU path.
  Future<void> _performMcumgrUpdate(String deviceId, String zipPath) async {
    debugPrint('[FW] Starting MCUmgr DFU for $deviceId');
    final images = await _processZip(zipPath);
    if (images.isEmpty) {
      error.value = 'ZIPにファームウェアイメージが見つかりません';
      return;
    }

    final factory = mcumgr.FirmwareUpdateManagerFactory();
    final manager = await factory.getUpdateManager(deviceId);

    final config = mcumgr.FirmwareUpgradeConfiguration(
      estimatedSwapTime: const Duration(seconds: 0),
      eraseAppSettings: true,
      pipelineDepth: 1,
    );

    final stateStream = manager.setup();
    final completer = Completer<void>();

    final stateSub = stateStream.listen(
      (state) {
        debugPrint('[FW] MCUmgr state: $state');
        if (state == mcumgr.FirmwareUpgradeState.success) {
          installProgress.value = 100;
          notifyListeners();
          if (!completer.isCompleted) completer.complete();
        }
      },
      onError: (Object e) {
        debugPrint('[FW] MCUmgr error: $e');
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    final progressSub = manager.progressStream.listen((progress) {
      if (progress.imageSize > 0) {
        installProgress.value =
            ((progress.bytesSent / progress.imageSize) * 100).round().clamp(
              0,
              99,
            );
        notifyListeners();
      }
    });

    try {
      await manager.update(images, configuration: config);
      await completer.future.timeout(const Duration(minutes: 10));
    } finally {
      await stateSub.cancel();
      await progressSub.cancel();
      await manager.kill();
    }
  }

  /// Nordic Legacy DFU path.
  Future<void> _performLegacyDfu(String deviceId, String zipPath) async {
    debugPrint('[FW] Starting Legacy DFU for $deviceId');
    final completer = Completer<void>();
    final dfu = NordicDfu();

    try {
      await dfu.startDfu(
        deviceId,
        zipPath,
        dfuEventHandler: DfuEventHandler(
          onProgressChanged: (address, percent, speed, avgSpeed, part, total) {
            installProgress.value = percent;
            notifyListeners();
          },
          onDfuCompleted: (address) {
            debugPrint('[FW] Legacy DFU completed');
            installProgress.value = 100;
            notifyListeners();
            if (!completer.isCompleted) completer.complete();
          },
          onError: (address, errorCode, errorType, message) {
            final msg = 'DFUエラー: $message (code=$errorCode)';
            debugPrint('[FW] $msg');
            if (!completer.isCompleted) completer.completeError(msg);
          },
          onDfuAborted: (address) {
            debugPrint('[FW] Legacy DFU aborted');
            if (!completer.isCompleted) {
              completer.completeError('DFU was aborted');
            }
          },
        ),
      );

      await completer.future.timeout(const Duration(minutes: 10));
    } on TimeoutException {
      error.value = 'DFUがタイムアウトしました';
    }
  }

  /// Extract the OTA zip and build mcumgr Image objects from manifest.json.
  Future<List<mcumgr.Image>> _processZip(String zipPath) async {
    final tempDir = await getTemporaryDirectory();
    final extractDir = Directory('${tempDir.path}/fw_extract');
    if (extractDir.existsSync()) {
      extractDir.deleteSync(recursive: true);
    }
    extractDir.createSync(recursive: true);

    await ZipFile.extractToDirectory(
      zipFile: File(zipPath),
      destinationDir: extractDir,
    );

    final manifestFile = File('${extractDir.path}/manifest.json');
    if (!manifestFile.existsSync()) {
      debugPrint('[FW] No manifest.json in ZIP');
      return [];
    }

    final manifestJson =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final files = manifestJson['files'] as List<dynamic>? ?? [];

    final images = <mcumgr.Image>[];
    for (final entry in files) {
      final imageIndex = entry['image'] as int? ?? 0;
      final fileName = entry['file'] as String? ?? '';
      if (fileName.isEmpty) continue;

      final binFile = File('${extractDir.path}/$fileName');
      if (!binFile.existsSync()) {
        debugPrint('[FW] Missing image file: $fileName');
        continue;
      }

      final data = await binFile.readAsBytes();
      images.add(
        mcumgr.Image(image: imageIndex, data: Uint8List.fromList(data)),
      );
      debugPrint('[FW] Loaded image $imageIndex: $fileName (${data.length}B)');
    }

    return images;
  }

  /// Whether an update is available (newer than current).
  bool get updateAvailable {
    if (latestInfo == null || currentVersion == null) return false;
    if (currentVersion!.isEmpty) return false;
    return latestInfo!.version != currentVersion;
  }

  /// Clear downloaded firmware and reset state.
  void reset() {
    downloadedZipPath = null;
    latestInfo = null;
    downloadProgress.value = 0;
    installProgress.value = 0;
    error.value = null;
    isChecking.value = false;
    isDownloading.value = false;
    isInstalling.value = false;
    notifyListeners();
  }

  @override
  void dispose() {
    isChecking.dispose();
    isDownloading.dispose();
    isInstalling.dispose();
    downloadProgress.dispose();
    installProgress.dispose();
    error.dispose();
    super.dispose();
  }
}
