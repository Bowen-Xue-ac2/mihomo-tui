import 'dart:convert';
import 'dart:io';

import 'package:mihomo_tui/src/service/mihomo_api.dart';
import 'package:mihomo_tui/src/service/paths.dart';

final _regions = {
  'us': RegExp(r'🇺🇸|美国|United[ -]?States|(?:^|[^a-z])US(?:[^a-z]|$)',
      caseSensitive: false),
  'sg': RegExp(r'🇸🇬|新加坡|Singapore|(?:^|[^a-z])SG(?:[^a-z]|$)',
      caseSensitive: false),
};

Future<void> runRegionalSelection({
  required MihomoApi api,
  required AppPaths paths,
  required String? matchTarget,
  required String region,
  required int? number,
}) async {
  final path = '${paths.runDir}${Platform.pathSeparator}regional-nodes.json';
  try {
    await Directory(paths.runDir).create(recursive: true);
    final round = await File(path).open(mode: FileMode.append);
    try {
      // Keep listing and consuming a round serialized across CLI processes.
      await round.lock(FileLock.blockingExclusive);
      Map<String, Object?>? saved;
      if (number == null) {
        await round.truncate(0);
      } else {
        saved = await _readRound(round);
        if (saved?['region'] != region) {
          throw ApiException(
              'Run vpn_x $region list for a fresh numbered list.');
        }
        final choices = saved?['nodes'];
        if (choices is! List || number > choices.length) {
          throw ApiException('Choose a number from the latest $region list.');
        }
      }

      final mode = (await api.configs()).mode;
      final target = switch (mode) {
        'global' => 'GLOBAL',
        'rule' => matchTarget,
        _ => null,
      };
      final scope = jsonEncode([
        api.baseUrl,
        paths.mihomoConfigFile,
        (await File(paths.mihomoConfigFile).lastModified()).toIso8601String(),
        mode,
        target,
      ]);
      if (saved != null && saved['scope'] != scope) {
        await round.truncate(0);
        throw ApiException(
            'The mode or profile changed. Run vpn_x $region list again.');
      }
      if (target == null) {
        throw ApiException(mode == 'direct'
            ? 'Choose vpn_x mode global or vpn_x mode rule before listing nodes.'
            : 'The active mode has no selectable proxy group.');
      }

      final snapshot = await api.proxies();
      final group = snapshot.nodes[target];
      if (group == null || group.type.toLowerCase() != 'selector') {
        throw ApiException(
            'The current route group is not selectable: $target');
      }
      if (number == null) {
        final pattern = _regions[region]!;
        final candidates = group.all
            .where((name) =>
                snapshot.nodes[name]?.isGroup == false &&
                pattern.hasMatch(name))
            .toSet()
            .toList();
        if (candidates.isEmpty) {
          throw ApiException('No $region nodes are selectable in $target.');
        }
        stderr.writeln('Testing ${candidates.length} $region nodes...');
        final results = await _measure(api, candidates);
        final ordered = results.map((item) => item.$1).toList();
        await round.setPosition(0);
        await round.writeString(jsonEncode({
          'scope': scope,
          'region': region,
          'nodes': ordered,
        }));
        await round.flush();
        stdout.writeln('${region.toUpperCase()} | $mode | $target');
        for (final (index, (name, delay)) in results.indexed) {
          final current = group.now == name ? '*' : ' ';
          final latency = delay == null ? 'Unavailable' : '$delay ms';
          stdout
              .writeln('$current ${index + 1}  ${latency.padRight(11)}  $name');
        }
        stdout.writeln('Choose once with vpn_x $region <number>.');
      } else {
        final choice = (saved!['nodes'] as List)[number - 1];
        // Retire every number before applying a valid selection.
        await round.truncate(0);
        await round.flush();
        if (choice is! String || !group.all.contains(choice)) {
          throw ApiException(
              'That node is unavailable. Run vpn_x $region list again.');
        }
        if (group.now != choice) await api.select(target, choice);
        if ((await api.proxies()).nodes[target]?.now != choice) {
          throw ApiException('Could not verify the selected node.');
        }
        stdout.writeln('$target → $choice');
      }
    } finally {
      await round.close();
    }
  } on FileSystemException {
    throw ApiException('Could not access the regional node list.');
  }
}

Future<Map<String, Object?>?> _readRound(RandomAccessFile file) async {
  await file.setPosition(0);
  try {
    final data = jsonDecode(utf8.decode(await file.read(await file.length())));
    return data is Map<String, Object?> ? data : null;
  } on FormatException {
    return null;
  }
}

Future<List<(String, int?)>> _measure(
    MihomoApi api, List<String> candidates) async {
  final results = <(String, int?)>[];
  const parallel = 6;
  for (var offset = 0; offset < candidates.length; offset += parallel) {
    results.addAll(await Future.wait(
      candidates.skip(offset).take(parallel).map((name) async {
        try {
          final delay = await api.delay(name);
          return (name, delay != null && delay > 0 ? delay : null);
        } on ApiException {
          return (name, null);
        }
      }),
    ));
  }
  results.sort((a, b) {
    final byDelay = (a.$2 ?? 0x7fffffff).compareTo(b.$2 ?? 0x7fffffff);
    return byDelay == 0 ? a.$1.compareTo(b.$1) : byDelay;
  });
  return results;
}
