import 'dart:convert';
import 'dart:io';

import 'package:mihomo_tui/src/model/profile_info.dart';
import 'package:mihomo_tui/src/model/settings.dart';
import 'package:mihomo_tui/src/service/core_updater.dart';
import 'package:mihomo_tui/src/service/exporter.dart';
import 'package:mihomo_tui/src/service/mihomo_api.dart';
import 'package:mihomo_tui/src/service/paths.dart';
import 'package:mihomo_tui/src/service/runtime.dart';
import 'package:mihomo_tui/src/service/system_proxy.dart';
import 'package:mihomo_tui/src/term/terminal.dart';
import 'package:mihomo_tui/src/util/format.dart';
import 'package:mihomo_tui/src/util/proxy_chain.dart';
import 'package:mihomo_tui/src/ui/app.dart';
import 'package:mihomo_tui/src/version.dart';
import 'package:yaml/yaml.dart';

Future<void> main(List<String> arguments) async {
  final options = _CliOptions.parse(arguments);
  if (options.error != null) {
    stderr.writeln('Invalid argument: ${options.error}');
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  if (options.version) {
    stdout.writeln('$appName $appVersion');
    return;
  }

  final settings = Settings.load(
    '${options.dataDir ?? AppPaths.defaultConfigDir}'
    '${Platform.pathSeparator}settings.json',
  );
  final runtime = Runtime.build(
    settings: settings,
    configDir: options.dataDir,
    mihomoHome: options.home,
    binaryOverride: options.binary,
    editorOverride: options.editor,
  );

  final proxyCommand = options.proxyCommand;
  if (proxyCommand != null) {
    exitCode = await _runProxyCommand(
      runtime,
      proxyCommand,
      options.proxyArguments,
    );
    return;
  }

  if (options.selfTest) {
    exitCode = await _selfTest(runtime);
    return;
  }

  if (options.status) {
    exitCode = await _printStatus(runtime, json: options.json);
    return;
  }
  if (options.list) {
    runtime.repo.ensureLayout();
    _printList(runtime);
    return;
  }
  final infoName = options.info;
  if (infoName != null) {
    runtime.repo.ensureLayout();
    exitCode = _printInfo(runtime, infoName);
    return;
  }
  if (options.updateCore) {
    exitCode = await _updateCore(runtime, options);
    return;
  }

  final exportPath = options.exportPath;
  if (exportPath != null) {
    runtime.repo.ensureLayout();
    final exporter = DataExporter(paths: runtime.paths, settings: settings);
    try {
      final result = await exporter.export(
        destination: exportPath.isEmpty ? null : File(exportPath),
      );
      stdout.writeln(
          'Exported ${result.entries.length} entries to ${result.file.path}');
      stdout.writeln('  ${result.entries.join('\n  ')}');
      exitCode = 0;
    } catch (error) {
      stderr.writeln('Export failed: $error');
      exitCode = 1;
    }
    return;
  }
  final legacyDir = options.importLegacy;
  if (legacyDir != null) {
    runtime.repo.ensureLayout();
    final imported = runtime.repo.importLegacy(legacyDir);
    stdout.writeln(imported == 0
        ? 'No profiles imported from $legacyDir'
        : 'Imported $imported profiles into ${runtime.paths.profilesDir}');
    exitCode = imported == 0 ? 1 : 0;
    return;
  }
  if (options.start || options.stop || options.restart) {
    runtime.repo.ensureLayout();
    exitCode = await _control(
      runtime,
      start: options.start,
      stop: options.stop,
      restart: options.restart,
    );
    return;
  }

  final terminal = createTerminal();
  if (!terminal.isInteractive) {
    stderr.writeln('$appName requires an interactive terminal.');
    stderr.writeln('Run $appName --help for CLI usage.');
    exitCode = 2;
    return;
  }
  final app = App(
    terminal: terminal,
    settings: settings,
    configDir: options.dataDir,
    mihomoHome: options.home,
    binaryOverride: options.binary,
    editorOverride: options.editor,
  );
  await app.run();
  await stdout.flush();
}

const String _usage = '''
$appName $appVersion — $appDescription

Usage:
  $appName [options]

General options:
  -h, --help            Show help
  -V, --version         Show version
      --data <dir>     Override the data directory (default: ~/.config/mihomo-tui)
      --home <dir>     Override the Mihomo data directory (default: ~/.config/mihomo)
      --bin <path>      Use this Mihomo executable
      --editor <Commands>   Set the profile editor

Non-interactive options:
      --status          Show core state; exit 0 if running, 1 if stopped
      --json            Output JSON with status
      --list            List profiles
      --info [Name]     Show the named profile or the active one
      --start           Start the core
      --stop            Stop the core
      --restart         Restart the core
      --selftest        Run the self-test
      --update-core     Download a Mihomo core for this platform from GitHub
      --mirror <id>     Select a download mirror for --update-core
                        direct / ghproxy / gh-proxy / akams
      --export [path]   Export profiles and settings to a ZIP in the home directory
      --import-legacy <dir>
                        Import legacy clash_tui data with data.json and config/

Commands:
  status [--json]       Show core status, selected node and last latency
  start | stop | restart
                        Manage the core process
  nodes <group>           List node numbers, last latency, and current selection
  use <group> <number>    Select a node by its number in the group
  mode [rule|global|direct]
                        Show or change the running mode
  system-proxy [status|on|off]
                        Manage the system proxy separately from TUN
  tun [status|on|off]   Manage the running core's TUN adapter
  Put --data, --home and --bin before the command.

Interactive keys:
  Tab focus   ↑↓ navigate   Enter select   ? help   q quit
  1–5 switch pages   Mouse click and scroll are supported
''';

class _CliOptions {
  _CliOptions();

  bool help = false;
  bool version = false;
  bool status = false;
  bool json = false;
  bool list = false;
  bool selfTest = false;
  bool start = false;
  bool stop = false;
  bool restart = false;
  String? info;
  String? importLegacy;
  String? exportPath;
  bool updateCore = false;
  String? mirror;
  String? binary;
  String? home;
  String? dataDir;
  String? editor;
  String? error;
  String? proxyCommand;
  List<String> proxyArguments = const [];

  static _CliOptions parse(List<String> arguments) {
    final options = _CliOptions();
    String? nextValue(int index) =>
        index + 1 < arguments.length ? arguments[index + 1] : null;

    for (var index = 0; index < arguments.length; index++) {
      final arg = arguments[index];
      switch (arg) {
        case '-h':
        case '--help':
          options.help = true;
        case '-V':
        case '--version':
          options.version = true;
        case 'status':
        case '--status':
          options.status = true;
        case '--json':
          options.json = true;
        case '--list':
          options.list = true;
        case '--selftest':
          options.selfTest = true;
        case '--update-core':
          options.updateCore = true;
        case '--mirror':
          options.mirror = nextValue(index);
          if (options.mirror == null) {
            options.error = '--mirror requires a mirror ID';
          } else {
            index++;
          }
        case '--export':
          final value = nextValue(index);
          if (value != null && !value.startsWith('-')) {
            options.exportPath = value;
            index++;
          } else {
            options.exportPath = '';
          }
        case '--import-legacy':
          options.importLegacy = nextValue(index);
          if (options.importLegacy == null) {
            options.error = '--import-legacy requires a directory';
          } else {
            index++;
          }
        case 'start':
        case '--start':
          options.start = true;
        case 'stop':
        case '--stop':
          options.stop = true;
        case 'restart':
        case '--restart':
          options.restart = true;
        case 'nodes':
        case 'use':
        case 'mode':
        case 'system-proxy':
        case 'tun':
          final values = arguments.sublist(index + 1);
          final error = switch (arg) {
            'nodes' when values.length != 1 => 'Usage: nodes <group>',
            'use' when values.length != 2 => 'Usage: use <group> <number>',
            'mode'
                when values.length > 1 ||
                    (values.isNotEmpty &&
                        !const ['rule', 'global', 'direct']
                            .contains(values.single.toLowerCase())) =>
              'Usage: mode [rule|global|direct]',
            'system-proxy' ||
            'tun'
                when values.length > 1 ||
                    (values.isNotEmpty &&
                        !const ['status', 'on', 'off']
                            .contains(values.single)) =>
              'Usage: $arg [status|on|off]',
            _ => null,
          };
          options.error ??= error;
          options.proxyCommand = arg;
          options.proxyArguments = values;
          return options;
        case '--bin':
          options.binary = nextValue(index);
          if (options.binary == null) {
            options.error = '--bin requires a path';
          } else {
            index++;
          }
        case '--home':
          options.home = nextValue(index);
          if (options.home == null) {
            options.error = '--home requires a directory';
          } else {
            index++;
          }
        case '--data':
          options.dataDir = nextValue(index);
          if (options.dataDir == null) {
            options.error = '--data requires a directory';
          } else {
            index++;
          }
        case '--editor':
          options.editor = nextValue(index);
          if (options.editor == null) {
            options.error = '--editor requires a command';
          } else {
            index++;
          }
        case '--info':
          final value = nextValue(index);
          if (value != null && !value.startsWith('-')) {
            options.info = value;
            index++;
          } else {
            options.info = '';
          }
        default:
          options.error ??= 'Unknown option $arg';
      }
    }
    return options;
  }
}

ProfileInfo? _readActiveInfo(Runtime runtime) {
  final configFile = File(runtime.paths.mihomoConfigFile);
  if (configFile.existsSync()) {
    try {
      return ProfileInfo.parse(configFile.readAsStringSync());
    } catch (_) {
      return null;
    }
  }
  return null;
}

Future<int> _runProxyCommand(
  Runtime runtime,
  String command,
  List<String> arguments,
) async {
  final info = _readActiveInfo(runtime);
  if (command == 'system-proxy') {
    return _runSystemProxy(info, arguments.firstOrNull ?? 'status');
  }
  final base = info?.apiBase;
  if (base == null) {
    stderr.writeln(
        'The active configuration has no usable Mihomo controller address.');
    return 1;
  }
  final api = MihomoApi(baseUrl: base, secret: info?.secret);
  try {
    if (command == 'tun') {
      return await _runTun(runtime, api, arguments.firstOrNull ?? 'status');
    }
    if (command == 'mode') {
      final target = arguments.isEmpty ? null : arguments.single.toLowerCase();
      if (target != null) await api.setMode(target);
      final current = (await api.configs()).mode;
      if (current == null || (target != null && current != target)) {
        throw ApiException('Could not verify the current mode.');
      }
      stdout.writeln(current);
      return 0;
    }

    final name = arguments.first;
    final snapshot = await api.proxies();
    final group = snapshot.nodes[name];
    if (group == null || !group.isGroup) {
      throw ApiException('Proxy group not found: $name');
    }
    if (command == 'nodes') {
      final numberWidth = group.all.length.toString().length;
      stdout.writeln(
          '  ${'#'.padLeft(numberWidth)}  ${'Latency'.padRight(11)}  Node');
      for (final (index, name) in group.all.indexed) {
        final node = snapshot.nodes[name];
        final latency = switch (node) {
          ProxyNode(delay: 0) => 'Timeout',
          ProxyNode(alive: false) => 'Unavailable',
          ProxyNode(delay: final delay?) when delay > 0 => '$delay ms',
          _ => 'Untested',
        };
        final number = (index + 1).toString().padLeft(numberWidth);
        final current = group.now == name ? '*' : ' ';
        stdout.writeln('$current $number  ${latency.padRight(11)}  $name');
      }
      return 0;
    }

    final choice = arguments[1];
    final number = int.tryParse(choice, radix: 10);
    if (number != null && (number < 1 || number > group.all.length)) {
      throw ApiException(
          'Node number must be between 1 and ${group.all.length}.');
    }
    final node = number == null ? choice : group.all[number - 1];
    if (!group.all.contains(node)) {
      throw ApiException('Node is not in this group: $node');
    }
    if (group.now != node) await api.select(name, node);
    final current = (await api.proxies()).nodes[name]?.now;
    if (current != node) {
      throw ApiException('Could not verify the selected node.');
    }
    stdout.writeln('$name → $current');
    return 0;
  } on ApiException catch (error) {
    stderr.writeln('$error');
    return 1;
  } finally {
    api.dispose();
  }
}

Future<int> _runSystemProxy(ProfileInfo? info, String action) async {
  final port = info?.mixedPort ?? info?.port;
  final state = await SystemProxy.currentState();
  final owned = port != null && await SystemProxy.pointsToLoopback(port);
  if (action == 'status') {
    stdout.writeln(switch (state) {
      SystemProxyState.enabled => owned ? 'vpn_x' : 'another app',
      SystemProxyState.disabled => 'off',
      _ => state.name,
    });
    return 0;
  }
  if (state == SystemProxyState.enabled && !owned) {
    stderr.writeln(
      'Another app owns the system proxy. Disable it in that app first.',
    );
    return 1;
  }
  if ((action == 'on' && state == SystemProxyState.enabled) ||
      (action == 'off' && state == SystemProxyState.disabled)) {
    stdout.writeln(
        action == 'on' ? 'System proxy is on.' : 'System proxy is off.');
    return 0;
  }
  if (state != SystemProxyState.enabled && state != SystemProxyState.disabled) {
    stderr.writeln('The current system proxy state is unavailable.');
    return 1;
  }
  if (action == 'on') {
    if (port == null || port <= 0) {
      stderr.writeln('The active configuration has no HTTP proxy port.');
      return 1;
    }
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
    } on SocketException {
      stderr.writeln('The local proxy port is offline. Run vpn_x start first.');
      return 1;
    }
  }
  final result = action == 'on'
      ? await SystemProxy.enable(httpPort: port!, socksPort: info?.socksPort)
      : await SystemProxy.disable();
  if (!result.ok) {
    stderr.writeln(result.message);
    return 1;
  }
  final current = await SystemProxy.currentState();
  final confirmed = action == 'on'
      ? current == SystemProxyState.enabled &&
          await SystemProxy.pointsToLoopback(port!)
      : current == SystemProxyState.disabled;
  if (!confirmed) {
    stderr.writeln('Could not verify the system proxy setting.');
    return 1;
  }
  stdout.writeln(result.message);
  return 0;
}

const _windowsTunDevice = 'vpn_x';

Future<Set<String>> _windowsTunAdapters() async {
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    r'Get-NetAdapter -IncludeHidden -ErrorAction Stop | '
        r'Where-Object { $_.Status -eq "Up" -and '
        r'($_.InterfaceDescription -like "Meta Tunnel*" -or $_.Name -eq "vpn_x") } | '
        r'Select-Object -ExpandProperty Name',
  ]).timeout(const Duration(seconds: 6));
  if (result.exitCode != 0) {
    throw ApiException('Could not check Windows TUN adapters.');
  }
  return result.stdout
      .toString()
      .split('\n')
      .map((name) => name.trim().toLowerCase())
      .where((name) => name.isNotEmpty)
      .toSet();
}

Future<int> _runTun(Runtime runtime, MihomoApi api, String action) async {
  final desired = action == 'on';
  final device = Platform.isWindows ? _windowsTunDevice : null;
  if (desired && device != null) {
    final adapters = await _windowsTunAdapters();
    final other = adapters.where((name) => name != device).toList();
    if (other.isNotEmpty) {
      throw ApiException(
          'Another Mihomo TUN adapter is active (${other.join(', ')}). Turn it off in its client first.');
    }
  }
  final ApiConfig before;
  try {
    before = await api.configs();
  } on ApiException catch (error) {
    if (runtime.core.detectPid() == null && error.statusCode == null) {
      throw ApiException(desired && device != null
          ? 'Mihomo is stopped. Run vpn_x start in an Administrator terminal first.'
          : 'Mihomo is stopped.');
    }
    rethrow;
  }
  final enabled = before.tunEnabled;
  if (enabled == null) {
    throw ApiException('The active controller did not report TUN state.');
  }
  if (action == 'status') {
    stdout.writeln(enabled ? 'on (${before.tunDevice ?? 'TUN'})' : 'off');
    return 0;
  }
  if (enabled == desired) {
    stdout.writeln(desired ? 'TUN is on.' : 'TUN is off.');
    return 0;
  }
  final log = File(runtime.paths.logFile);
  final logOffset = desired && device != null ? _tunLogOffset(log) : null;
  await api.setTun(desired, device: desired ? device : null);
  final current = await api.configs();
  if (current.tunEnabled != desired) {
    if (logOffset != null && _tunAccessDenied(log, logOffset)) {
      throw ApiException(
          'Windows denied the running Mihomo process access to TUN. Run vpn_x restart in this Administrator terminal, then retry vpn_x tun on.');
    }
    throw ApiException(
        'Could not apply TUN. Check the Mihomo log for details.');
  }
  if (desired && device != null) {
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if ((await _windowsTunAdapters()).contains(device)) {
          stdout.writeln('TUN is on ($device).');
          return 0;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (_) {
      await api.setTun(false);
      rethrow;
    }
    await api.setTun(false);
    throw ApiException('Windows did not bring up the $device TUN adapter.');
  }
  stdout.writeln(desired ? 'TUN is on.' : 'TUN is off.');
  return 0;
}

int? _tunLogOffset(File log) {
  try {
    return log.existsSync() ? log.lengthSync() : 0;
  } on FileSystemException {
    return null;
  }
}

bool _tunAccessDenied(File log, int offset) {
  try {
    final length = log.lengthSync();
    if (length <= offset) return false;
    final start = length - offset > 16384 ? length - 16384 : offset;
    final handle = log.openSync();
    try {
      handle.setPositionSync(start);
      final text =
          utf8.decode(handle.readSync(length - start), allowMalformed: true);
      return RegExp(r'Start TUN listening error:[^\r\n]*Access is denied',
              caseSensitive: false)
          .hasMatch(text);
    } finally {
      handle.closeSync();
    }
  } on FileSystemException {
    return false;
  }
}

Future<int> _printStatus(Runtime runtime, {required bool json}) async {
  final status = await runtime.core.status();
  final profile = runtime.repo.activeProfile;
  final info = _readActiveInfo(runtime);
  var apiOnline = false;
  String? apiVersion;
  String? mode;
  String? node;
  int? delayMs;
  if (info?.apiBase != null) {
    final api = MihomoApi(baseUrl: info!.apiBase!, secret: info.secret);
    try {
      apiVersion = await api.version();
      apiOnline = apiVersion != null;
      if (apiOnline) {
        mode = (await api.configs()).mode;
        final snapshot =
            mode == null || mode == 'direct' ? null : await api.proxies();
        node = selectedOutbound(snapshot,
            mode: mode, matchTarget: info.finalMatchTarget);
        delayMs = snapshot?.nodes[node]?.delay;
      }
    } on ApiException {
      // Report core and controller status even when route details are unavailable.
    } finally {
      api.dispose();
    }
  }
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert({
      'app': appName,
      'version': appVersion,
      'platform': Platform.operatingSystem,
      'arch': _arch,
      'binary': status.binaryPath,
      'coreVersion': status.version,
      'running': status.running,
      'pid': status.pid,
      'profile': runtime.repo.activeName,
      'configFile': runtime.paths.mihomoConfigFile,
      'api': info?.controllerAddress,
      'apiOnline': apiOnline,
      'apiVersion': apiVersion,
      'mode': mode,
      'node': node,
      'delayMs': delayMs,
    }));
  } else {
    stdout.writeln('$appName $appVersion (${Platform.operatingSystem} $_arch)');
    stdout.writeln('  Binary    ${status.binaryPath ?? 'Not found'}');
    stdout.writeln('  Core version  ${status.version ?? 'Unknown'}');
    stdout.writeln('  Status      ${status.running ? 'Running' : 'Stopped'}'
        '${status.pid == null ? '' : '(pid ${status.pid})'}');
    final latency = switch (delayMs) {
      null => node == null || mode == 'direct' ? '-' : 'Untested',
      0 => 'Timeout',
      final ms => '$ms ms',
    };
    stdout.writeln('  Mode        ${mode ?? '-'}');
    final nodeLabel = mode == 'rule' ? 'MATCH fallback' : 'Node';
    stdout.writeln('  ${nodeLabel.padRight(16)}${node ?? '-'}');
    stdout.writeln('  Delay       $latency');
    stdout.writeln(
      '  Profile      ${runtime.repo.activeName ?? 'None'}'
      '${profile?.updatedAt == null ? '' : ' (updated ${formatDateTime(profile!.updatedAt!)})'}',
    );
    stdout.writeln('  Config      ${runtime.paths.mihomoConfigFile}');
    stdout.writeln(
      '  Controller    ${info?.controllerAddress ?? 'Not configured'}'
      '${apiOnline ? ' · Connected ${apiVersion ?? ''}' : ''}',
    );
    stdout.writeln('  Data directory  ${runtime.paths.configDir}');
  }
  return status.running ? 0 : 1;
}

void _printList(Runtime runtime) {
  final profiles = runtime.repo.profiles;
  if (profiles.isEmpty) {
    stdout.writeln('(No profiles)');
    return;
  }
  stdout.writeln('  Name\tNodes\tPorts\tUpdated\tURL');
  for (final profile in profiles) {
    final info = runtime.repo.cachedInfo(profile.name);
    final marker = profile.name == runtime.repo.activeName ? '*' : ' ';
    final ports =
        info == null || info.portSummary.isEmpty ? '-' : info.portSummary.first;
    stdout.writeln(
      '$marker ${profile.name}\t'
      '${info?.nodeCount ?? '?'}\t'
      '$ports\t'
      '${profile.updatedAt == null ? '-' : formatDateTime(profile.updatedAt!)}\t'
      '${profile.url}',
    );
  }
}

int _printInfo(Runtime runtime, String name) {
  final target = name.isEmpty ? runtime.repo.activeName : name;
  if (target == null) {
    stderr
        .writeln('No active profile. Specify one with $appName --info <Name>');
    return 1;
  }
  final profile = runtime.repo.byName(target);
  if (profile == null) {
    stderr.writeln('Profile not found: $target');
    return 1;
  }
  final info = runtime.repo.cachedInfo(target);
  final error = runtime.repo.cachedError(target);
  stdout.writeln('Name      ${profile.name}');
  stdout.writeln('URL      ${profile.url}');
  stdout.writeln('File      ${runtime.repo.profileFile(target)}');
  stdout.writeln(
    'Updated      ${profile.updatedAt == null ? 'Never' : formatDateTime(profile.updatedAt!)}',
  );
  stdout.writeln(
      'Active      ${profile.name == runtime.repo.activeName ? 'Yes' : 'No'}');
  if (error != null) {
    stdout.writeln('Parse failed  $error');
    return 1;
  }
  if (info != null) {
    stdout.writeln('Nodes      ${info.nodeCount}');
    stdout.writeln('Groups    ${info.groupCount}');
    stdout.writeln('Rules      ${info.ruleCount}');
    stdout.writeln('Mode      ${info.mode}');
    stdout.writeln(
      'Ports      ${info.portSummary.isEmpty ? 'Not set' : info.portSummary.join(' · ')}',
    );
    stdout.writeln('Controller    ${info.controllerAddress ?? 'Not set'}');
    stdout.writeln('Allow LAN ${info.allowLan ? 'Yes' : 'No'}');
    stdout.writeln('IPv6      ${info.ipv6 ? 'Yes' : 'No'}');
    stdout.writeln('Dashboard      ${info.panelUrl ?? 'None'}');
  }
  return 0;
}

Future<int> _control(
  Runtime runtime, {
  required bool start,
  required bool stop,
  required bool restart,
}) async {
  if (stop || restart) {
    final wasRunning = runtime.core.detectPid() != null;
    final stopped = await runtime.core.stop();
    if (wasRunning && !stopped) {
      stderr.writeln(
          'Could not stop Mihomo. Use an Administrator terminal if it was started with elevated privileges.');
      return 1;
    }
    if (stop && !restart && stopped) {
      final info = _readActiveInfo(runtime);
      final port = info?.mixedPort ?? info?.port;
      if (port != null &&
          await SystemProxy.currentState() == SystemProxyState.enabled &&
          await SystemProxy.pointsToLoopback(port)) {
        final result = await SystemProxy.disable();
        if (!result.ok) {
          stderr.writeln(result.message);
          return 1;
        }
      }
    }
    stdout.writeln(stopped ? 'Mihomo stopped' : 'No running Mihomo process');
    if (stop && !restart) return stopped ? 0 : 1;
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  if (start || restart) {
    if (runtime.repo.activeName == null &&
        !File(runtime.paths.mihomoConfigFile).existsSync()) {
      stderr.writeln('Select a profile in the TUI before starting Mihomo.');
      return 1;
    }
    final result = await runtime.core.start();
    if (!result.isSuccess) {
      stderr.writeln('Start failed: ${result.error}');
      return 1;
    }
    stdout.writeln('Mihomo started, PID ${result.pid}');
  }
  return 0;
}

Future<int> _selfTest(Runtime runtime) async {
  var failures = 0;
  void check(String label, bool ok, [String? detail]) {
    stdout.writeln(
        '${ok ? 'ok  ' : 'FAIL'} $label${detail == null ? '' : ' · $detail'}');
    if (!ok) failures++;
  }

  stdout.writeln('$appName $appVersion selftest');
  check('platform', Platform.operatingSystem.isNotEmpty,
      '${Platform.operatingSystem} $_arch');
  check(
    'dart runtime',
    Platform.version.isNotEmpty,
    Platform.version.split(' ').first,
  );

  try {
    final temp = Directory.systemTemp.createTempSync('mihomo-tui-selftest');
    final file = File('${temp.path}${Platform.pathSeparator}probe.txt');
    file.writeAsStringSync('probe');
    check('filesystem', file.readAsStringSync() == 'probe', temp.path);
    temp.deleteSync(recursive: true);
  } catch (error) {
    check('filesystem', false, '$error');
  }

  try {
    final parsed = ProfileInfo.parse('''
mixed-port: 7890
mode: rule
external-controller: 127.0.0.1:9090
proxies:
  - {name: a, type: ss, server: 1.1.1.1, port: 80, cipher: aes-128-gcm, password: x}
proxy-groups:
  - {name: g, type: select, proxies: [a]}
rules:
  - DOMAIN-SUFFIX,example.com,DIRECT
''');
    check(
      'config parser',
      parsed.nodeCount == 1 &&
          parsed.mixedPort == 7890 &&
          parsed.mode == 'rule',
      '${parsed.nodeCount} Nodes · Ports ${parsed.mixedPort}',
    );
  } catch (error) {
    check('config parser', false, '$error');
  }

  try {
    final sample = loadYaml('a: 1');
    check('yaml engine', sample is YamlMap);
  } catch (error) {
    check('yaml engine', false, '$error');
  }

  try {
    final settings = Settings(
      mihomoBin: runtime.paths.mihomoBin,
      editor: 'vi',
    );
    final roundTrip = Settings.fromJson(settings.toJson());
    check('settings roundtrip', roundTrip.editor == 'vi');
  } catch (error) {
    check('settings roundtrip', false, '$error');
  }

  final binary = runtime.core.resolveBinary();
  stdout.writeln(
    'info  mihomo binary · ${binary ?? 'Not found (set it in Settings)'}',
  );
  if (binary != null) {
    final version = await runtime.core.version();
    stdout.writeln('info  mihomo version · ${version ?? 'Unavailable'}');
  }
  stdout.writeln('info  data dir · ${runtime.paths.configDir}');
  stdout.writeln('info  config dir · ${runtime.paths.mihomoHome}');
  stdout.writeln(
      'info  tty · stdin=${stdin.hasTerminal} stdout=${stdout.hasTerminal}');

  return failures == 0 ? 0 : 1;
}

Future<int> _updateCore(Runtime runtime, _CliOptions options) async {
  final mirror = mirrorById(options.mirror);
  final updater = CoreUpdater(mirror: mirror);
  final target = options.binary != null
      ? File(options.binary!).absolute.path
      : runtime.core.resolveBinary() ?? CoreUpdater.defaultInstallPath();
  stdout.writeln('$appName $appVersion');
  stdout.writeln('  Platform/arch  ${CoreUpdater.platformLabel}');
  stdout.writeln('  Download source     ${mirror.label}');
  stdout.writeln('  Target path   $target');
  stdout.writeln(
      '  Current version   ${await runtime.core.version() ?? 'Not installed'}');
  final wasRunning = runtime.core.detectPid() != null;
  if (wasRunning) {
    stdout.writeln('  Stop the core before updating.');
    await runtime.core.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  try {
    stdout.write('  Looking up latest version...');
    final release = await updater.latest();
    stdout.writeln(' ${release.tag}(${release.assetName})');
    var lastPercent = -1;
    var progressOpen = false;
    final result = await updater.install(
      release,
      targetPath: target,
      onProgress: (received, total) {
        if (total == null) return;
        final percent = (received * 100 / total).floor();
        if (percent < lastPercent + 10) return;
        lastPercent = percent;
        stdout.write(' $percent%');
        progressOpen = percent < 100;
        if (percent >= 100) stdout.writeln();
      },
    );
    if (progressOpen) stdout.writeln();
    stdout.writeln('Done: ${result.path}(${result.version})');
    if (wasRunning) {
      final started = await runtime.core.start();
      stdout.writeln(
        started.isSuccess
            ? 'Mihomo restarted, PID ${started.pid}'
            : 'Restart failed: ${started.error}',
      );
    }
    return 0;
  } on CoreUpdateException catch (error) {
    stderr.writeln('Update failed: ${error.message}');
    return 1;
  }
}

String get _arch {
  final version = Platform.version;
  if (version.contains('arm64') || version.contains('aarch64')) return 'arm64';
  if (version.contains('arm')) return 'arm';
  if (version.contains('x64')) return 'x64';
  return 'unknown';
}
