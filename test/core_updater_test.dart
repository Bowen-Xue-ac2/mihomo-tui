import 'dart:convert';
import 'dart:io';

import 'package:mihomo_tui/src/service/core_updater.dart';
import 'package:test/test.dart';

/// A tiny shell script that answers `-v`, wrapped in gzip, to exercise the
/// download -> unpack -> verify -> swap path without touching the network.
List<int> _fakeCoreGzip(String version) {
  final script =
      '#!/bin/sh\nif [ "\$1" = "-v" ]; then echo "Mihomo Meta v$version linux amd64"; exit 0; fi\nsleep 30\n';
  return GZipCodec().encode(utf8.encode(script));
}

void main() {
  late HttpServer server;
  late Directory temp;
  var payload = _fakeCoreGzip('9.9.9');
  var statusCode = 200;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = statusCode;
      request.response.headers.contentType = ContentType.binary;
      request.response.add(payload);
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('mihomo-tui-core');
    payload = _fakeCoreGzip('9.9.9');
    statusCode = 200;
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  CoreRelease release() => CoreRelease(
        tag: 'v9.9.9',
        assetName: 'asset.gz',
        url: 'http://127.0.0.1:${server.port}/asset.gz',
        size: 0,
        platform: CoreUpdater.platformLabel,
      );

  test('installs next to the target and keeps a backup', () async {
    final target = File('${temp.path}/mihomo');
    final updater = CoreUpdater();
    final result = await updater.install(release(), targetPath: target.path);

    expect(result.version, 'v9.9.9');
    expect(target.existsSync(), isTrue);
    expect(File('${target.path}.bak').existsSync(), isFalse);
    expect(File('${target.path}.new').existsSync(), isFalse);
    final output = Process.runSync(target.path, ['-v']).stdout.toString();
    expect(output, contains('v9.9.9'));
  });

  test('replaces an existing (even running) binary atomically', () async {
    final target = File('${temp.path}/mihomo');
    final old = _fakeCoreGzip('1.0.0');
    target.writeAsBytesSync(GZipCodec().decode(old));
    Process.runSync('chmod', ['755', target.path]);
    // Keep the old binary busy while upgrading.
    final running = await Process.start(target.path, const []);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final result =
        await CoreUpdater().install(release(), targetPath: target.path);
    expect(result.version, 'v9.9.9');
    expect(File('${target.path}.bak').existsSync(), isTrue);
    expect(target.readAsStringSync(), contains('9.9.9'));
    expect(
      Process.runSync(target.path, ['-v']).stdout.toString(),
      contains('v9.9.9'),
    );

    running.kill();
    await running.exitCode;
  });

  test('keeps the old binary when the download fails', () async {
    final target = File('${temp.path}/mihomo');
    target.writeAsStringSync('old');
    statusCode = 500;
    await expectLater(
      CoreUpdater().install(release(), targetPath: target.path),
      throwsA(isA<CoreUpdateException>()),
    );
    expect(target.readAsStringSync(), 'old');
  });
}
