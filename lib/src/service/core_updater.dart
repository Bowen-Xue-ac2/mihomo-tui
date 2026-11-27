/// Fetching / updating the mihomo core from the official GitHub releases.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../util/net.dart' as net;
import 'paths.dart';

/// A download mirror for GitHub release assets.
class MirrorOption {
  const MirrorOption(this.id, this.label, this.prefix);

  final String id;
  final String label;

  /// Prefix prepended to the original asset URL ('' = direct).
  final String prefix;

  bool get isDirect => prefix.isEmpty;
}

const List<MirrorOption> coreMirrors = [
  MirrorOption('direct', 'GitHub (direct)', ''),
  MirrorOption('ghproxy', 'ghproxy.net', 'https://ghproxy.net/'),
  MirrorOption('gh-proxy', 'gh-proxy.com', 'https://gh-proxy.com/'),
  MirrorOption('akams', 'github.akams.cn', 'https://github.akams.cn/'),
];

MirrorOption mirrorById(String? id) {
  for (final mirror in coreMirrors) {
    if (mirror.id == id) return mirror;
  }
  return coreMirrors.first;
}

/// Result of a quick mirror reachability test.
class MirrorProbe {
  const MirrorProbe.available(this.milliseconds)
      : available = true,
        error = null;

  const MirrorProbe.unavailable(this.error)
      : available = false,
        milliseconds = null;

  final bool available;
  final int? milliseconds;
  final String? error;

  String get label {
    if (!available) {
      return error == null ? 'Unavailable' : 'Unavailable ($error)';
    }
    final ms = milliseconds ?? 0;
    return ms >= 1000
        ? 'Available ${(ms / 1000).toStringAsFixed(1)}s'
        : 'Available ${ms}ms';
  }
}

class CoreUpdateException implements Exception {
  CoreUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CoreRelease {
  const CoreRelease({
    required this.tag,
    required this.assetName,
    required this.url,
    required this.size,
    required this.platform,
  });

  final String tag;
  final String assetName;
  final String url;
  final int size;
  final String platform;
}

class CoreInstallResult {
  const CoreInstallResult({
    required this.version,
    required this.path,
    required this.bytes,
  });

  final String version;
  final String path;
  final int bytes;
}

class CoreUpdater {
  CoreUpdater({MirrorOption? mirror, this.proxy})
      : mirror = mirror ?? coreMirrors.first;

  final MirrorOption mirror;

  /// Explicit proxy (`http://host:port`); env proxies are used when null.
  final String? proxy;

  static const String _apiLatest =
      'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest';
  static const String _userAgent = 'mihomo-tui';

  static String get osName {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isMacOS) return 'darwin';
    return Platform.operatingSystem;
  }

  static String get archName {
    final version = Platform.version.toLowerCase();
    if (version.contains('arm64') || version.contains('aarch64')) {
      return 'arm64';
    }
    if (version.contains('arm')) return 'armv7';
    if (version.contains('x64') || version.contains('amd64')) return 'amd64';
    return 'amd64';
  }

  /// e.g. `linux-amd64`.
  static String get platformLabel => '$osName-$archName';

  static String get archiveExtension => Platform.isWindows ? 'zip' : 'gz';

  static String defaultInstallPath() {
    final separator = Platform.pathSeparator;
    if (Platform.isWindows) {
      final base = Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          AppPaths.homeDir;
      return [base, 'mihomo-tui', 'mihomo.exe'].join(separator);
    }
    return [AppPaths.homeDir, '.local', 'bin', 'mihomo'].join(separator);
  }

  String mirrorUrl(String url) =>
      mirror.isDirect ? url : '${mirror.prefix}$url';

  /// Reads the newest release metadata, falling back to the release page
  /// redirect when the GitHub API is rate limited / unavailable.
  Future<CoreRelease> latest() async {
    try {
      return await _latestFromApi();
    } on CoreUpdateException {
      final fallback = await _latestFromRedirect();
      if (fallback != null) return fallback;
      rethrow;
    }
  }

  /// Resolves the newest tag through `releases/latest` (no API quota).
  Future<CoreRelease?> _latestFromRedirect() async {
    const page = 'https://github.com/MetaCubeX/mihomo/releases/latest';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = _userAgent;
    final directive = net.envProxyDirective(Uri.parse(page), explicit: proxy);
    if (directive != null) client.findProxy = (_) => directive;
    try {
      final request = await client.getUrl(Uri.parse(page));
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) return null;
      final tag =
          location.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
      if (tag.isEmpty) return null;
      final ext = archiveExtension;
      final name = 'mihomo-$osName-$archName-$tag.$ext';
      return CoreRelease(
        tag: tag,
        assetName: name,
        url: 'https://github.com/MetaCubeX/mihomo/releases/download/$tag/$name',
        size: 0,
        platform: platformLabel,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<CoreRelease> _latestFromApi() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = _userAgent;
    final apiProxy =
        net.envProxyDirective(Uri.parse(_apiLatest), explicit: proxy);
    if (apiProxy != null) client.findProxy = (_) => apiProxy;
    try {
      final request = await client.getUrl(Uri.parse(_apiLatest));
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) {
        throw CoreUpdateException(
          'GitHub API returned HTTP ${response.statusCode}. Check connectivity and rate limits.',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw CoreUpdateException('GitHub API returned invalid data.');
      }
      final tag = decoded['tag_name'];
      final assets = decoded['assets'];
      if (tag is! String || assets is! List) {
        throw CoreUpdateException('GitHub API returned invalid data.');
      }
      final picked = _pickAsset(tag, assets);
      if (picked == null) {
        throw CoreUpdateException(
          'Release $tag has no $archiveExtension package for $platformLabel.',
        );
      }
      return picked;
    } on SocketException catch (error) {
      throw CoreUpdateException('Network error: ${error.message}');
    } on TimeoutException {
      throw CoreUpdateException('GitHub API request timed out.');
    } finally {
      client.close(force: true);
    }
  }

  CoreRelease? _pickAsset(String tag, List<dynamic> assets) {
    final entries = <String, Map<String, dynamic>>{};
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is! String || url is! String) continue;
      entries[name] = {
        'url': url,
        'size': asset['size'] is num ? (asset['size'] as num).toInt() : 0,
      };
    }

    final ext = archiveExtension;
    final preferred = [
      'mihomo-$osName-$archName-$tag.$ext',
      'mihomo-$osName-$archName-compatible-$tag.$ext',
    ];
    for (final name in preferred) {
      final entry = entries[name];
      if (entry != null) {
        return CoreRelease(
          tag: tag,
          assetName: name,
          url: entry['url'] as String,
          size: entry['size'] as int,
          platform: platformLabel,
        );
      }
    }
    // Fall back to any plain build (skip microarch / go-version variants).
    final prefix = 'mihomo-$osName-$archName-';
    for (final name in entries.keys) {
      if (!name.startsWith(prefix) || !name.endsWith('.$ext')) continue;
      final middle =
          name.substring(prefix.length, name.length - ext.length - 1);
      if (middle.contains('-go') ||
          RegExp(r'(^|-)v[123]($|-)').hasMatch(middle)) {
        continue;
      }
      final entry = entries[name]!;
      return CoreRelease(
        tag: tag,
        assetName: name,
        url: entry['url'] as String,
        size: entry['size'] as int,
        platform: platformLabel,
      );
    }
    return null;
  }

  /// Quick reachability test for [mirror]: requests the first chunk of the
  /// release asset and measures how long it takes to get a response.
  static Future<MirrorProbe> probe(
    MirrorOption mirror,
    CoreRelease release, {
    Duration timeout = const Duration(seconds: 10),
    String? proxy,
  }) async {
    final url =
        mirror.isDirect ? release.url : '${mirror.prefix}${release.url}';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = _userAgent
      ..idleTimeout = const Duration(seconds: 3);
    final directive = net.envProxyDirective(Uri.parse(url), explicit: proxy);
    if (directive != null) client.findProxy = (_) => directive;
    final stopwatch = Stopwatch()..start();
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200 && response.statusCode != 206) {
        return MirrorProbe.unavailable('HTTP ${response.statusCode}');
      }
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (received > 0) break;
      }
      stopwatch.stop();
      if (received == 0) {
        return const MirrorProbe.unavailable('No data received');
      }
      return MirrorProbe.available(stopwatch.elapsedMilliseconds);
    } on TimeoutException {
      return const MirrorProbe.unavailable('Timed out');
    } on SocketException catch (error) {
      return MirrorProbe.unavailable(error.message);
    } catch (error) {
      return MirrorProbe.unavailable('$error');
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads [release] and installs it at [targetPath], keeping a `.bak`.
  Future<CoreInstallResult> install(
    CoreRelease release, {
    required String targetPath,
    void Function(int received, int? total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final bytes = await _download(
      mirrorUrl(release.url),
      expectedSize: release.size,
      onProgress: onProgress,
      cancelled: cancelled,
    );
    final binary = await _unpack(release.assetName, bytes);
    if (binary.isEmpty) {
      throw CoreUpdateException('The downloaded archive is empty.');
    }

    final target = File(targetPath);
    target.parent.createSync(recursive: true);

    // Write next to the target and swap it in: a *running* executable cannot
    // be overwritten in place (ETXTBSY "Text file busy"), but rename(2) over
    // it is allowed on POSIX and keeps the old inode alive for the process.
    final temp = File('$targetPath.new');
    try {
      if (temp.existsSync()) temp.deleteSync();
      await temp.writeAsBytes(binary, flush: true);
      if (!Platform.isWindows) {
        try {
          Process.runSync('chmod', ['755', temp.path]);
        } catch (_) {}
      }
      final version = await _probeVersion(temp.path);
      if (version == null) {
        throw CoreUpdateException(
            'The new core failed to run. The previous binary was kept.');
      }
      if (target.existsSync()) {
        try {
          target.copySync('$targetPath.bak');
        } catch (_) {}
      }
      if (Platform.isWindows && target.existsSync()) {
        try {
          target.deleteSync();
        } on FileSystemException {
          throw CoreUpdateException(
              'Stop the running core before replacing it.');
        }
      }
      try {
        await temp.rename(targetPath);
      } on FileSystemException catch (error) {
        final reason = error.osError?.message ?? error.message;
        throw CoreUpdateException(
          reason.toLowerCase().contains('busy')
              ? 'Stop the running core before replacing it.'
              : 'Could not replace the core: $reason',
        );
      }
      return CoreInstallResult(
        version: version,
        path: target.path,
        bytes: binary.length,
      );
    } finally {
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } catch (_) {}
      }
    }
  }

  static Future<String?> _probeVersion(String path) async {
    try {
      final result = await Process.run(
        path,
        ['-v'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 10));
      final output = '${result.stdout}\n${result.stderr}';
      final match = RegExp(r'v?\d+\.\d+\.\d+[\w.\-+]*').firstMatch(output);
      return match?.group(0);
    } catch (_) {
      return null;
    }
  }

  Future<List<int>> _download(
    String url, {
    required int expectedSize,
    void Function(int received, int? total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = _userAgent
      ..idleTimeout = const Duration(seconds: 10);
    final directive = net.envProxyDirective(Uri.parse(url), explicit: proxy);
    if (directive != null) client.findProxy = (_) => directive;
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw CoreUpdateException(
            'Download failed: HTTP ${response.statusCode}');
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : (expectedSize > 0 ? expectedSize : null);
      final builder = BytesBuilder(copy: false);
      var received = 0;
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      await for (final chunk in response) {
        if (cancelled?.call() ?? false) throw CoreUpdateException('Canceled');
        if (DateTime.now().isAfter(deadline)) {
          throw CoreUpdateException('Download timed out');
        }
        builder.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      if (received == 0) throw CoreUpdateException('Download was empty');
      return builder.takeBytes();
    } on SocketException catch (error) {
      throw CoreUpdateException('Network error: ${error.message}');
    } on TimeoutException {
      throw CoreUpdateException('Download timed out');
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<int>> _unpack(String name, List<int> bytes) async {
    if (name.endsWith('.gz')) {
      return GZipCodec().decode(bytes);
    }
    if (name.endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? best;
      for (final file in archive.files) {
        if (!file.isFile) continue;
        final lower = file.name.toLowerCase();
        if (!lower.endsWith('.exe') && !lower.endsWith('mihomo')) continue;
        if (best == null || file.size > best.size) best = file;
      }
      if (best == null) return const [];
      return best.content;
    }
    // Raw binary.
    return bytes;
  }
}
