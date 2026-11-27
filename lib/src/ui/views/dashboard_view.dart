/// Overview pane: core state, quick actions and system proxy shortcuts.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../../service/system_proxy.dart';
import '../../term/keys.dart';
import '../../term/style.dart';
import '../../term/width.dart';
import '../../util/format.dart';
import '../../util/proxy_chain.dart';
import '../../util/traffic.dart';
import '../app_context.dart';
import '../list_state.dart';
import '../overlay.dart';
import '../painter.dart';
import 'view.dart';

class DashboardView extends View {
  static const _mark = [
    '██          ██',
    '   ██    ██',
    '      ██',
    '   ██    ██',
    '██          ██',
  ];

  final ListState _list = ListState();

  @override
  String get label => 'Overview';

  @override
  String get title => 'Overview';

  @override
  List<KeyHint> hints(AppContext app) => const [
        KeyHint('↑↓', 'Select action'),
        KeyHint('Enter', 'Run'),
        KeyHint('s', 'Start/stop'),
        KeyHint('R', 'Restart'),
        KeyHint('r', 'Reload config'),
      ];

  List<_Action> _actions(AppContext app) {
    final status = app.coreStatus;
    final running = status?.running ?? false;
    final online = app.apiOnline;
    final mode = app.apiConfig?.mode ?? app.activeInfo?.mode;
    final allowLan = app.apiConfig?.allowLan;
    return [
      _Action(
        running ? 'Stop core' : 'Start core',
        enabled: status?.binaryPath != null,
        hint: running
            ? 'Stop the Mihomo process'
            : 'Start Mihomo in the background with this config',
        run: () async {
          if (running) {
            await app.stopCore();
          } else {
            await app.startCore();
          }
        },
      ),
      _Action(
        'Restart core',
        enabled: running,
        hint: 'Reload the config and restart Mihomo',
        run: app.restartCore,
      ),
      _Action(
        'Reload config',
        enabled: online,
        hint: 'Apply config.yaml to the running core',
        run: app.reloadConfig,
      ),
      for (final item in const ['rule', 'global', 'direct'])
        _Action(
          'Set mode to $item',
          enabled: online,
          hint: mode == item ? 'Current mode' : 'Apply through the controller',
          marker: mode == item ? 'Current' : null,
          run: () async => app.setMode(item),
        ),
      _Action(
        'Edit active config',
        enabled: File(app.paths.mihomoConfigFile).existsSync(),
        hint: 'Open the active config.yaml in your editor',
        run: app.editActiveConfig,
      ),
      _Action(
        'LAN proxy',
        enabled: online,
        hint: 'Allow other devices on this LAN to use the proxy (allow-lan)',
        marker: allowLan == null ? null : (allowLan ? 'On' : 'Off'),
        markerActive: allowLan == true,
        run: app.toggleAllowLan,
      ),
      _Action(
        'Toggle system proxy',
        enabled: app.activeInfo?.preferredProxyPort != null,
        hint: 'Enable or disable the system proxy',
        marker: switch (app.systemProxyState) {
          SystemProxyState.enabled => 'On',
          SystemProxyState.disabled => 'Off',
          _ => null,
        },
        markerActive: app.systemProxyState == SystemProxyState.enabled,
        run: app.toggleSystemProxy,
      ),
      _Action(
        'Open dashboard',
        enabled: online,
        hint: 'Open zashboard in a browser',
        run: () async {
          final url = app.activeInfo?.panelUrl;
          if (url == null) {
            app.toast('Set external-controller to open the dashboard.',
                level: ToastLevel.warning);
            return;
          }
          app.openUrl(url);
        },
      ),
      _Action(
        'Copy proxy variables',
        enabled: app.activeInfo?.preferredProxyPort != null,
        hint: 'Copy the export commands to the clipboard',
        run: () async {
          final port = app.activeInfo?.preferredProxyPort;
          if (port == null) return;
          final text = [
            'export http_proxy=http://127.0.0.1:$port',
            'export https_proxy=http://127.0.0.1:$port',
            'export all_proxy=socks5://127.0.0.1:$port',
          ].join('\n');
          if (app.copyToClipboard(text)) {
            app.toast('Copied proxy variables to the clipboard.',
                level: ToastLevel.success);
          } else {
            app.toast('Clipboard unavailable. Copy the variables manually.',
                level: ToastLevel.warning);
          }
        },
      ),
      _Action(
        'Refresh status',
        hint: 'Check the process and controller again',
        run: app.refresh,
      ),
    ];
  }

  @override
  void draw(
    AppContext app,
    Painter painter,
    Rect area, {
    required bool focused,
  }) {
    final theme = app.theme;
    final actions = _actions(app);

    final statusRows = _statusRows(app);
    var y = area.y;

    final statusCount = math.min(statusRows.length, area.height - 6);
    if (statusCount > 0) {
      final statusHeight = statusCount + 2;
      final statusCard = Rect(area.x, y, area.width, statusHeight);
      final showMark = statusCard.width >= 66 && statusCount >= _mark.length;
      final markLeft = statusCard.right - 19;
      final valueLeft = statusCard.x + 16;
      final valueRight = showMark ? markLeft - 2 : statusCard.right - 3;
      final valueWidth = valueRight - valueLeft;
      var rowY = statusCard.y + 1;
      for (final row in statusRows.take(statusCount)) {
        final rowRect = Rect(statusCard.x + 1, rowY, statusCard.width - 2, 1);
        final clickable = row.onPress != null;
        painter.text(
          statusCard.x + 2,
          rowY,
          row.label,
          Style(fg: theme.muted, bg: theme.panel),
        );
        painter.text(
          valueLeft,
          rowY,
          truncate(row.value, valueWidth),
          Style(
            fg: row.color ?? theme.text,
            bold: row.bold,
            underline: clickable && app.hoverId == 'status-${row.label}',
          ),
        );
        if (clickable) {
          painter.hit(
            rowRect,
            id: 'status-${row.label}',
            onPress: row.onPress,
          );
        }
        rowY++;
      }
      painter.drawBox(statusCard, focused: false, title: 'Core status');
      if (showMark) {
        final markTop = statusCard.y + 1 + (statusCount - _mark.length) ~/ 2;
        final markStyle = Style(fg: theme.accent, bg: theme.panel, bold: true);
        for (var index = 0; index < _mark.length; index++) {
          painter.text(markLeft, markTop + index, _mark[index], markStyle);
        }
      }
      y += statusHeight + 1;
    }

    final available = area.bottom - y;
    if (available >= 3) {
      final maxRows = available - 2;
      _list.bind(total: actions.length, visible: maxRows);
      _list.ensureVisible();

      final visible = math.min(maxRows, actions.length - _list.scroll);
      final cardHeight = visible + 2;
      final card = Rect(area.x, y, area.width, cardHeight);
      for (var row = 0; row < visible; row++) {
        final index = _list.scroll + row;
        final action = actions[index];
        final selected = index == _list.selected;
        final rowRect = Rect(card.x + 1, card.y + 1 + row, card.width - 2, 1);
        final baseStyle = selected
            ? theme.selectionStyle()
            : Style(fg: theme.muted, bg: theme.panel);
        painter.text(
          rowRect.x + 1,
          rowRect.y,
          selected ? '>' : ' ',
          Style(fg: theme.accent, bg: baseStyle.bg, bold: selected),
        );
        painter.text(
          rowRect.x + 3,
          rowRect.y,
          truncate(action.label, rowRect.width - 12),
          baseStyle,
        );
        if (action.marker != null) {
          painter.text(
            rowRect.right - textWidth(action.marker!) - 2,
            rowRect.y,
            action.marker!,
            Style(
              fg: action.markerActive ? theme.green : theme.muted,
              bg: baseStyle.bg,
              bold: action.markerActive,
            ),
          );
        }
        final hint = action.hint;
        if (hint != null && rowRect.width > 50) {
          painter.text(
            rowRect.x + 26,
            rowRect.y,
            truncate(hint, rowRect.right - (rowRect.x + 26) - 2),
            Style(fg: theme.muted, bg: baseStyle.bg),
          );
        }
        painter.hit(
          rowRect,
          id: 'action$index',
          onHover: () => _list.select(index),
          onPress: () {
            _list.select(index);
            if (action.enabled) {
              action.run();
            } else {
              app.toast(
                _disabledReason(app, action.label),
                level: ToastLevel.warning,
              );
            }
          },
          onWheel: _list.wheel,
        );
      }
      painter.drawBox(
        card,
        focused: focused,
        title: 'Quick actions',
        borderStyle: Style(
          fg: focused ? theme.borderFocus : theme.border,
          bg: theme.panel,
        ),
      );
    }
  }

  @override
  bool onWheel(AppContext app, int delta) {
    _list.wheel(delta);
    return true;
  }

  String _disabledReason(AppContext app, String label) {
    if (label.toLowerCase().contains('core') &&
        app.coreStatus?.binaryPath == null) {
      return 'Set the Mihomo executable path in Settings.';
    }
    if (app.coreStatus?.running != true) return 'The core is stopped.';
    if (!app.apiOnline) {
      return 'Controller unavailable. Check external-controller.';
    }
    return 'Unavailable';
  }

  List<_StatusRow> _statusRows(AppContext app) {
    final theme = app.theme;
    final status = app.coreStatus;
    final info = app.activeInfo;
    final running = status?.running ?? false;
    final pid = status?.pid;
    final uptime = app.coreStartedAt == null
        ? null
        : DateTime.now().difference(app.coreStartedAt!);
    final rows = <_StatusRow>[];

    rows.add(_StatusRow(
      'Binary',
      status?.binaryPath ?? 'Mihomo not found. Set its path in Settings.',
      color: status?.binaryPath == null ? theme.red : null,
    ));
    rows.add(_StatusRow('Version', status?.version ?? 'Unknown'));
    rows.add(_StatusRow(
      'Process',
      running
          ? 'Running${status?.pidFromFile == false ? ' (external)' : ''}'
              ' | pid ${pid ?? '?'}'
              '${uptime == null ? '' : ' | uptime ${formatDuration(uptime)}'}'
          : 'Stopped',
      color: running
          ? (status?.pidFromFile == false ? theme.yellow : theme.green)
          : theme.red,
      bold: true,
    ));
    rows.add(_StatusRow(
      'Config',
      app.repo.activeName ?? 'None',
      color: app.repo.activeName == null ? theme.yellow : null,
    ));
    final ports = info?.portSummary ?? const <String>[];
    rows.add(_StatusRow('Ports', ports.isEmpty ? '-' : ports.join(' | ')));
    final controller = info?.controllerAddress;
    rows.add(_StatusRow(
      'Controller',
      controller == null
          ? '-'
          : '$controller ${app.apiOnline ? '| Connected ${app.apiVersion ?? ''}' : '| Offline'}'
              .trim(),
      color: controller == null
          ? theme.muted
          : app.apiOnline
              ? theme.green
              : theme.yellow,
    ));
    final mode = app.apiConfig?.mode ?? info?.mode;
    rows.add(_StatusRow('Mode', mode ?? '-'));
    final tun = app.apiConfig?.tunEnabled;
    rows.add(_StatusRow('TUN', tun == null ? '-' : (tun ? 'On' : 'Off')));

    final liveMode = app.apiConfig?.mode;
    final node = selectedOutbound(
      app.proxySnapshot,
      mode: liveMode,
      matchTarget: info?.finalMatchTarget,
    );
    rows.add(_StatusRow(
      liveMode == 'rule' ? 'MATCH fallback' : 'Current node',
      node ?? (app.apiOnline && app.proxySnapshot == null ? 'Loading...' : '-'),
      color: node == null ? theme.muted : theme.accentSoft,
      onPress: () => app.openView(2),
    ));

    final panel = info?.panelUrl;
    rows.add(_StatusRow(
      'Dashboard',
      panel ?? (controller == null ? 'No external-controller' : '-'),
      color: panel == null ? theme.muted : theme.accent,
      onPress: panel == null ? null : () => app.openUrl(panel),
    ));

    if (app.apiConfig?.allowLan == true) {
      final port = info?.mixedPort ??
          info?.port ??
          info?.socksPort ??
          app.activeInfo?.preferredProxyPort;
      final address = app.lanAddress;
      if (address != null) {
        rows.add(_StatusRow(
          'LAN proxy',
          port == null ? address : '$address:$port',
          color: theme.accentSoft,
        ));
      }
    }

    final profile = app.repo.activeProfile;
    if (profile != null) {
      final summary = summarizeTraffic(
        used: profile.trafficUsed,
        total: profile.trafficTotal,
        expire: profile.trafficExpireAt,
      );
      if (summary != null) {
        final fraction = summary.fraction;
        rows.add(_StatusRow(
          'Plan',
          summary.display,
          color: fraction == null
              ? theme.accentSoft
              : fraction >= 0.9
                  ? theme.red
                  : fraction >= 0.7
                      ? theme.yellow
                      : theme.green,
        ));
      }
    }

    final connections = app.connections;
    rows.add(_StatusRow(
      'Connections',
      connections == null ? '-' : '${connections.count} ',
    ));
    rows.add(_StatusRow(
      'Traffic',
      connections == null
          ? '-'
          : 'Up ${formatBytes(connections.uploadTotal)}'
              ' | Down ${formatBytes(connections.downloadTotal)}'
              ' (since start)',
      color: connections == null ? null : theme.accentSoft,
    ));
    return rows;
  }

  @override
  bool onKey(AppContext app, KeyEvent event) {
    final actions = _actions(app);
    _list.bind(total: actions.length, visible: _list.visible);
    if (event.kind == KeyKind.down || event.isChar('j')) {
      _list.moveBy(1);
      return true;
    }
    if (event.kind == KeyKind.up || event.isChar('k')) {
      _list.moveBy(-1);
      return true;
    }
    if (event.kind == KeyKind.home || event.isCharExact('g')) {
      _list.select(0);
      return true;
    }
    if (event.kind == KeyKind.end || event.isCharExact('G')) {
      _list.select(actions.length - 1);
      return true;
    }
    if (event.kind == KeyKind.pageDown) {
      _list.wheel(_list.visible - 1);
      return true;
    }
    if (event.kind == KeyKind.pageUp) {
      _list.wheel(-(_list.visible - 1));
      return true;
    }
    if (event.kind == KeyKind.enter) {
      final action = actions[_list.selected];
      if (action.enabled) {
        action.run();
      } else {
        app.toast(_disabledReason(app, action.label),
            level: ToastLevel.warning);
      }
      return true;
    }
    if (event.isChar('s')) {
      if (app.coreStatus?.running ?? false) {
        unawaited(app.stopCore());
      } else {
        unawaited(app.startCore());
      }
      return true;
    }
    if (event.isCharExact('R')) {
      unawaited(app.restartCore());
      return true;
    }
    if (event.isChar('r')) {
      unawaited(app.reloadConfig());
      return true;
    }
    if (event.isChar('m')) {
      final current = app.apiConfig?.mode ?? 'rule';
      const order = ['rule', 'global', 'direct'];
      final next = order[(order.indexOf(current) + 1) % order.length];
      unawaited(app.setMode(next));
      return true;
    }
    if (event.isChar('o')) {
      final url = app.activeInfo?.panelUrl;
      if (url != null) app.openUrl(url);
      return true;
    }
    if (event.isChar('p')) {
      unawaited(app.toggleSystemProxy());
      return true;
    }
    return false;
  }
}

class _Action {
  _Action(
    this.label, {
    required this.run,
    this.enabled = true,
    this.hint,
    this.marker,
    this.markerActive = true,
  });

  final String label;
  final Future<void> Function() run;
  final bool enabled;
  final String? hint;
  final String? marker;
  final bool markerActive;
}

class _StatusRow {
  _StatusRow(
    this.label,
    this.value, {
    this.color,
    this.bold = false,
    this.onPress,
  });

  final String label;
  final String value;
  final int? color;
  final bool bold;
  final void Function()? onPress;
}
