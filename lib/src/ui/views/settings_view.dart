/// Settings pane: paths, editor, download proxy.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../../model/settings.dart';
import '../../service/autostart.dart';
import '../../service/core_updater.dart';
import '../../service/downloader.dart';
import '../../util/format.dart';
import '../../service/paths.dart';
import '../../term/keys.dart';
import '../../term/style.dart';
import '../../term/width.dart';
import '../../version.dart';
import '../theme.dart';
import '../app_context.dart';
import '../list_state.dart';
import '../overlay.dart';
import '../painter.dart';
import 'view.dart';

class SettingsView extends View {
  final ListState _list = ListState();

  @override
  String get label => 'Settings';

  @override
  String get title => 'Settings';

  @override
  List<KeyHint> hints(AppContext app) => const [
        KeyHint('↑↓', 'Select'),
        KeyHint('Enter', 'Edit'),
        KeyHint('d', 'Detect core'),
        KeyHint('i', 'About'),
      ];

  List<_Row> _rows(AppContext app) {
    final settings = app.settings;
    return [
      _Row(
        'Mihomo binary',
        settings.mihomoBin ?? 'Auto-detect',
        'Leave blank to search PATH and common locations',
        editable: true,
        onEdit: (value) => _apply(
            app,
            settings.copyWith(
              mihomoBin: value,
              clearMihomoBin: value.isEmpty,
            )),
      ),
      _Row(
        'Mihomo directory',
        settings.mihomoHome ?? app.paths.mihomoHome,
        'Mihomo uses this directory with -d and reads config.yaml here.',
        editable: true,
        onEdit: (value) => _apply(
            app,
            settings.copyWith(
              mihomoHome: value,
              clearMihomoHome: value.isEmpty,
            )),
      ),
      _Row(
        'Editor',
        settings.editor ?? AppPaths.defaultEditor,
        'Edit profiles with a command such as "code -w"',
        editable: true,
        onEdit: (value) => _apply(
            app,
            settings.copyWith(
              editor: value,
              clearEditor: value.isEmpty,
            )),
      ),
      _Row(
        'Update core',
        app.coreStatus?.version ?? 'Not installed',
        'Download the matching core from GitHub (${CoreUpdater.platformLabel})',
        action: true,
        onActivate: () => unawaited(app.updateCore()),
      ),
      _Row(
        'Download mirror',
        _mirrorValue(app),
        'Choose a mirror and check its connectivity',
        action: true,
        onActivate: app.showMirrorPicker,
      ),
      _Row(
        'Download proxy',
        settings.downloadProxy ?? _defaultProxy(),
        'Leave blank to use http_proxy and https_proxy',
        editable: true,
        onEdit: (value) => _apply(
            app,
            settings.copyWith(
              downloadProxy: value,
              clearDownloadProxy: value.isEmpty,
            )),
      ),
      _Row(
        'Accent color',
        Theme.accentLabel(settings.accent ?? 'blue'),
        'Press Enter to cycle the accent color',
        action: true,
        onActivate: () => unawaited(app.cycleThemeAccent()),
      ),
      _Row(
        'Color mode',
        switch (settings.colorMode ?? 'auto') {
          'light' => 'Light',
          'dark' => 'Dark',
          _ => 'Terminal default',
        },
        'Use the terminal colors or override them. Auto reads OSC 11 or COLORFGBG.',
        action: true,
        onActivate: () => unawaited(app.cycleColorMode()),
      ),
      _Row(
        'Start at login',
        _autostartLabel(app),
        'Start Mihomo at sign-in (systemd user service or Windows Run)',
        action: true,
        onActivate: () => unawaited(app.toggleAutostart()),
      ),
      _Row(
        'Export data',
        'Export ZIP',
        'Export settings, profile index, and configurations to the home directory',
        action: true,
        onActivate: () => app.confirm(
          title: 'Export data',
          message:
              'Export settings, data.json, and profile configurations as a ZIP.',
          detail: const [
            'The archive is timestamped and saved in your home directory.'
          ],
          confirmLabel: 'Export',
          onConfirm: () => unawaited(app.exportData()),
        ),
      ),
      _Row('Data directory', app.paths.configDir,
          'Profile configurations, logs, and runtime state',
          action: true, onActivate: () => _openPath(app, app.paths.configDir)),
      _Row('Profiles directory', app.paths.profilesDir,
          'Profiles are saved as <name>.yaml',
          action: true,
          onActivate: () => _openPath(app, app.paths.profilesDir)),
      _Row('Log file', app.paths.logFile, 'Mihomo stdout and stderr',
          action: true,
          onActivate: () => _openPath(app,
              app.core.hasLogFile ? app.paths.logFile : app.paths.logsDir)),
      _Row(
        'Detect core',
        app.coreStatus?.binaryPath == null
            ? 'Not found'
            : app.coreStatus!.binaryPath!,
        'Search for the Mihomo executable again',
        action: true,
        onActivate: () => unawaited(app.refresh()),
      ),
      _Row('About', '$appName $appVersion',
          'Terminal interface with mouse and keyboard support',
          action: true, onActivate: () => _about(app)),
    ];
  }

  String _mirrorValue(AppContext app) {
    final current = mirrorById(app.settings.mirror);
    if (app.isMirrorProbing(current.id)) {
      return '${current.label} (checking...)';
    }
    final probe = app.mirrorProbes[current.id];
    if (probe == null) return current.label;
    return '${current.label}(${probe.label})';
  }

  String _autostartLabel(AppContext app) => switch (app.autostartState) {
        AutostartState.enabled => 'Enabled',
        AutostartState.disabled => 'Disabled',
        AutostartState.unsupported => 'Unsupported platform or core missing',
        AutostartState.unknown => 'Checking...',
      };

  String _defaultProxy() {
    final proxy = Downloader.envProxy();
    return proxy ?? 'Direct';
  }

  @override
  void draw(
    AppContext app,
    Painter painter,
    Rect area, {
    required bool focused,
  }) {
    final theme = app.theme;
    final rows = _rows(app);
    final inner = Rect(area.x + 1, area.y + 1, area.width - 2, area.height - 2);
    final labelWidth = (inner.width * 0.28).round().clamp(14, 30);

    // Rows take two lines plus a separating blank line; compute capacity from
    // the real height so the list never leaves a blank row behind.
    var capacity = 0;
    var used = 0;
    while (used + (capacity == 0 ? 2 : 3) <= inner.height) {
      used += capacity == 0 ? 2 : 3;
      capacity++;
    }
    if (capacity < 1) capacity = 1;
    _list.bind(total: rows.length, visible: capacity);
    _list.ensureVisible();

    var y = inner.y;
    final visible = math.min(capacity, rows.length - _list.scroll);
    for (var row = 0; row < visible; row++) {
      final index = _list.scroll + row;
      final entry = rows[index];
      final selected = index == _list.selected;
      const rowHeight = 2;
      final rowStyle = selected
          ? theme.selectionStyle()
          : Style(fg: theme.muted, bg: theme.panel);
      painter.text(
        inner.x,
        y,
        selected ? '>' : ' ',
        Style(fg: theme.accent, bg: rowStyle.bg),
      );
      painter.text(
        inner.x + 2,
        y,
        truncate(entry.label, labelWidth),
        Style(
            fg: selected ? theme.text : theme.muted,
            bg: rowStyle.bg,
            bold: selected),
      );
      final valueStyle = Style(
        fg: entry.editable
            ? theme.accentSoft
            : (selected ? theme.text : theme.muted),
        bg: rowStyle.bg,
      );
      painter.text(
        inner.x + 2 + labelWidth,
        y,
        truncate(entry.value, inner.width - labelWidth - 4),
        valueStyle,
      );
      painter.text(
        inner.x + 2 + labelWidth,
        y + 1,
        truncate(entry.description, inner.width - labelWidth - 4),
        Style(fg: theme.muted, bg: rowStyle.bg),
      );
      painter.hit(
        Rect(inner.x, y, inner.width, rowHeight + 1),
        id: 'setting$index',
        onHover: () => _list.select(index),
        onWheel: _list.wheel,
        onPress: () {
          _list.select(index);
          if (entry.onActivate != null) {
            entry.onActivate!();
          } else {
            _edit(app, entry);
          }
        },
      );
      y += rowHeight + 1;
    }
    // Painted last so stray text can never break the frame.
    painter.drawBox(area, focused: focused, title: 'Settings');
  }

  void _edit(AppContext app, _Row row) {
    if (row.onEdit == null) return;
    app.showOverlay(
      FormOverlay(
        onChanged: app.requestFrame,
        title: row.label,
        description: [row.description],
        fields: [
          FormFieldSpec(
            key: 'value',
            label: 'New value',
            hint: row.label == 'Mihomo binary'
                ? 'Leave blank to detect automatically'
                : row.value,
            initial: row.value == 'Auto-detect' ? '' : row.value,
          ),
        ],
        onSubmit: (values) => row.onEdit!(values['value']?.trim() ?? ''),
      ),
    );
  }

  Future<void> _apply(AppContext app, Settings next) async {
    await app.applySettings(next);
    app.toast('Settings saved.', level: ToastLevel.success);
  }

  void _openPath(AppContext app, String path) {
    final directory = Directory(path);
    final target = directory.existsSync() ? path : File(path).parent.path;
    app.openUrl(target);
  }

  void _about(AppContext app) {
    app.showOverlay(
      InfoOverlay(
        title: 'About $appName',
        lines: [
          '$appName $appVersion',
          appDescription,
          '',
          'Platform      ${platformLabel()}',
          'Dart      ${Platform.version.split(' ').first}',
          'Data directory  ${app.paths.configDir}',
          'Config directory  ${app.paths.mihomoHome}',
          'Core      ${app.coreStatus?.binaryPath ?? 'Not found'}',
          'Version      ${app.coreStatus?.version ?? 'Unknown'}',
          '',
          'Keyboard and mouse',
          '  | Click to select or scroll to browse',
          '  | Tab switches focus between navigation and content',
          '  | ? Show keyboard shortcuts',
          '',
          'Based on wzk0/mihomo-tui, the Dart rewrite of clash_tui.',
          'Uses Mihomo (Clash.Meta) with controller integration,',
          'mouse input, and live logs.',
        ],
      ),
    );
  }

  @override
  bool onKey(AppContext app, KeyEvent event) {
    final rows = _rows(app);
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
      _list.select(rows.length - 1);
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
      final row = rows[_list.selected];
      if (row.onActivate != null) {
        row.onActivate!();
      } else {
        _edit(app, row);
      }
      return true;
    }
    if (event.isChar('d')) {
      unawaited(app.refresh());
      return true;
    }
    if (event.isChar('i')) {
      _about(app);
      return true;
    }
    return false;
  }
}

class _Row {
  _Row(
    this.label,
    this.value,
    this.description, {
    this.editable = false,
    this.action = false,
    this.onEdit,
    this.onActivate,
  });

  final String label;
  final String value;
  final String description;
  final bool editable;
  final bool action;
  final void Function(String value)? onEdit;
  final void Function()? onActivate;
}
