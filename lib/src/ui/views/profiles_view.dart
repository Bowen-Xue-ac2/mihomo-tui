/// Subscription list: add, update, rename, delete, activate.
library;

import 'dart:async';
import 'dart:math' as math;

import '../../model/profile.dart';
import '../../term/keys.dart';
import '../../term/style.dart';
import '../../term/width.dart';
import '../../util/format.dart';
import '../../util/traffic.dart';
import '../app_context.dart';
import '../list_state.dart';
import '../overlay.dart';
import '../painter.dart';
import '../theme.dart';
import 'view.dart';

class ProfilesView extends View {
  final ListState _list = ListState();
  DateTime? _lastClickAt;
  int? _lastClickIndex;

  @override
  String get label => 'Profiles';

  @override
  String get title => 'Profiles';

  @override
  List<KeyHint> hints(AppContext app) => const [
        KeyHint('Enter', 'Enable'),
        KeyHint('a', 'Add'),
        KeyHint('u', 'Update'),
        KeyHint('r', 'Rename'),
        KeyHint('d', 'Delete'),
        KeyHint('e', 'Profile details'),
        KeyHint('E', 'Edit YAML'),
      ];

  @override
  void draw(
    AppContext app,
    Painter painter,
    Rect area, {
    required bool focused,
  }) {
    final theme = app.theme;
    final profiles = app.repo.profiles;
    if (profiles.isEmpty) {
      _drawEmpty(app, painter, area);
      return;
    }

    if (area.height < 4 || area.width < 20) return;

    // Two independent cards: the list fills the space, the details card is
    // minimal and pinned to the bottom (same arrangement as the overview).
    _list.bind(total: profiles.length, visible: 1);
    final detailRows = _detailRows(app, profiles[_list.selected]);
    final detailHeight = detailRows.length + 2;
    const gap = 1;
    final showDetail = area.height >= detailHeight + gap + 6;
    final listHeight =
        showDetail ? area.height - detailHeight - gap : area.height;
    final listRect = Rect(area.x, area.y, area.width, listHeight);
    final listInner = Rect(
      listRect.x + 1,
      listRect.y + 1,
      listRect.width - 2,
      listRect.height - 2,
    );
    const headerRows = 2; // labels + separator
    final maxRows = math.max(1, listInner.height - headerRows);
    _list.bind(total: profiles.length, visible: maxRows);
    _list.ensureVisible();

    final wide = listInner.width >= 76;
    final showPorts = listInner.width >= 55;
    final nameWidth = (listInner.width * 0.3).round().clamp(10, 24);
    final columns = [
      ('Name', nameWidth),
      ('Nodes', 5),
      if (showPorts) ('Ports', wide ? 12 : 8),
      ('Traffic', listInner.width < 45 ? 10 : 13),
      if (wide) ('Update', 11),
    ];
    final fixedWidth = columns.fold(2, (sum, column) => sum + column.$2 + 1);
    if (listInner.width - fixedWidth >= 10) {
      columns.add(('ProfilesURL', listInner.width - fixedWidth));
    }

    final headerStyle = Style(fg: theme.muted, bg: theme.panel, bold: true);
    final headerY = listInner.y;
    var x = listInner.x + 2;
    for (final (label, width) in columns) {
      painter.text(x, headerY, label, headerStyle, maxWidth: width);
      x += width + 1;
    }
    painter.text(
      listInner.x,
      headerY + 1,
      '─' * listInner.width,
      Style(fg: theme.border, bg: theme.panel),
    );

    final visible = math.min(maxRows, profiles.length - _list.scroll);
    for (var row = 0; row < visible; row++) {
      final index = _list.scroll + row;
      final profile = profiles[index];
      final selected = index == _list.selected;
      final active = profile.name == app.repo.activeName;
      final rowY = listInner.y + headerRows + row;
      final rowRect = Rect(listInner.x, rowY, listInner.width, 1);
      final info = app.repo.cachedInfo(profile.name);

      final rowStyle = selected
          ? theme.selectionStyle()
          : Style(fg: theme.muted, bg: theme.panel);
      painter.fill(rowRect, rowStyle);
      painter.text(
        rowRect.x,
        rowY,
        selected ? '>' : ' ',
        Style(fg: theme.accent, bg: rowStyle.bg, bold: selected),
      );
      var columnX = rowRect.x + 2;
      for (final (label, width) in columns) {
        final value = switch (label) {
          'Name' => active ? '* ${profile.name}' : profile.name,
          'Nodes' => info?.nodeCount.toString() ?? '-',
          'Ports' => info?.portSummary.firstOrNull ?? '-',
          'Traffic' => _trafficCell(profile),
          'Update' => profile.updatedAt == null
              ? '-'
              : formatRelative(profile.updatedAt!),
          _ => profile.url,
        };
        painter.text(
          columnX,
          rowY,
          truncate(value, width),
          Style(
            fg: label == 'Name' && active ? theme.green : rowStyle.fg,
            bg: rowStyle.bg,
            bold: label == 'Name' && (active || selected),
          ),
        );
        columnX += width + 1;
      }

      painter.hit(
        rowRect,
        id: 'profile$index',
        onHover: () => _list.select(index),
        onPress: () => _onRowPress(app, index),
        onWheel: _list.wheel,
      );
    }

    // Frames last: content can never punch through the borders.
    painter.drawBox(
      listRect,
      focused: focused,
      title: 'Profiles (${profiles.length})',
    );
    if (showDetail) {
      final detailRect = Rect(
        area.x,
        area.bottom - detailHeight,
        area.width,
        detailHeight,
      );
      _drawDetailCard(
          app, painter, detailRect, profiles[_list.selected], detailRows,
          focused: focused);
    }
  }

  List<(String, String, int?)> _detailRows(AppContext app, Profile profile) {
    final theme = app.theme;
    final info = app.repo.cachedInfo(profile.name);
    final error = app.repo.cachedError(profile.name);
    final isActive = profile.name == app.repo.activeName;
    final rows = <(String, String, int?)>[];
    rows.add((
      'Status',
      isActive ? 'Active' : 'Disabled',
      isActive ? theme.green : theme.muted,
    ));
    if (error != null) {
      rows.add(('Parse', error, theme.red));
    } else if (info != null) {
      rows.add((
        'Nodes',
        '${info.nodeCount} nodes | ${info.groupCount} groups | ${info.ruleCount} rules'
            '${info.providerCount > 0 ? ' | ${info.providerCount} providers' : ''}',
        null,
      ));
      rows.add((
        'Ports',
        info.portSummary.isEmpty ? 'Not set' : info.portSummary.join(' | '),
        theme.accentSoft,
      ));
      rows.add(_trafficRow(profile, app.theme) ?? ('Traffic', '-', null));
      rows.add((
        'Controller',
        '${info.controllerAddress ?? 'Not set'} | Mode ${info.mode}'
            '${info.allowLan ? ' | Allow LAN' : ''}'
            '${info.ipv6 ? ' | IPv6' : ''}',
        null,
      ));
    }
    rows.add((
      'File',
      '${app.repo.profileFile(profile.name)}'
          '${profile.size == null ? '' : ' | ${formatBytes(profile.size!)}'}',
      theme.muted,
    ));
    rows.add((
      'Update',
      profile.updatedAt == null ? 'Never' : formatDateTime(profile.updatedAt!),
      theme.muted,
    ));
    rows.add(('URL', profile.url, theme.muted));
    return rows;
  }

  void _drawDetailCard(
    AppContext app,
    Painter painter,
    Rect rect,
    Profile profile,
    List<(String, String, int?)> rows, {
    required bool focused,
  }) {
    final theme = app.theme;
    var y = rect.y + 1;
    for (final row in rows) {
      if (y >= rect.bottom - 1) break;
      painter.text(
        rect.x + 2,
        y,
        row.$1,
        Style(fg: theme.muted, bg: theme.panel),
      );
      painter.text(
        rect.x + 2 + 8,
        y,
        truncate(row.$2, rect.width - 12),
        Style(fg: row.$3 ?? theme.text, bg: theme.panel),
      );
      y++;
    }
    painter.hit(
      Rect(rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2),
      id: 'detail',
      onPress: () => openProfileInfo(app, profile),
    );
    painter.drawBox(
      rect,
      focused: focused,
      title: 'Details | ${profile.name} | i for full details',
    );
  }

  /// Compact `used/total` text for the table column.
  String _trafficCell(Profile profile) {
    final used = profile.trafficUsed;
    final total = profile.trafficTotal;
    if (used == null && total == null) return '-';
    if (used != null && total != null && total > 0) {
      return '${formatBytesShort(used)}/${formatBytesShort(total)}';
    }
    if (used != null) return formatBytesShort(used);
    return '-';
  }

  /// Detail row with an ASCII progress bar (hidden when the provider does not
  /// report traffic).
  (String, String, int?)? _trafficRow(Profile profile, Theme theme) {
    final summary = summarizeTraffic(
      used: profile.trafficUsed,
      total: profile.trafficTotal,
      expire: profile.trafficExpireAt,
    );
    if (summary == null) return null;
    final fraction = summary.fraction;
    final color = fraction == null
        ? theme.accentSoft
        : fraction >= 0.9
            ? theme.red
            : fraction >= 0.7
                ? theme.yellow
                : theme.green;
    return ('Traffic', summary.display, color);
  }

  void _drawEmpty(AppContext app, Painter painter, Rect area) {
    final theme = app.theme;
    final box = Rect(area.x, area.y, area.width, area.height);
    painter.text(
      box.x + 3,
      box.y + 2,
      'Press a to add a profile or u to refresh one.',
      Style(fg: theme.text),
    );
    painter.text(
      box.x + 3,
      box.y + 3,
      'Profiles are saved in ${app.paths.profilesDir}',
      Style(fg: theme.muted),
    );
    painter.text(
      box.x + 3,
      box.y + 4,
      'Activating a profile copies it to ${app.paths.mihomoConfigFile}',
      Style(fg: theme.muted),
    );
    painter.hit(
      Rect(box.x + 1, box.y + 1, box.width - 2, math.min(5, box.height - 2)),
      id: 'add',
      onPress: () => unawaited(app.addProfileInteractive()),
    );
    painter.drawBox(box, title: 'Profiles | No profiles');
  }

  void _onRowPress(AppContext app, int index) {
    final now = DateTime.now();
    final doubleClick = _lastClickIndex == index &&
        _lastClickAt != null &&
        now.difference(_lastClickAt!) < const Duration(milliseconds: 450);
    _lastClickAt = now;
    _lastClickIndex = index;
    _list.select(index);
    if (doubleClick) {
      final profiles = app.repo.profiles;
      if (index < profiles.length) {
        unawaited(app.activateProfile(profiles[index]));
      }
    }
  }

  @override
  bool onKey(AppContext app, KeyEvent event) {
    final profiles = app.repo.profiles;
    if (profiles.isEmpty) {
      if (event.isChar('a') || event.kind == KeyKind.enter) {
        unawaited(app.addProfileInteractive());
        return true;
      }
      return false;
    }
    _list.bind(total: profiles.length, visible: _list.visible);
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
      _list.select(profiles.length - 1);
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
    final profile = profiles[_list.selected];
    if (event.kind == KeyKind.enter) {
      unawaited(app.activateProfile(profile));
      return true;
    }
    if (event.isChar('a')) {
      unawaited(app.addProfileInteractive());
      return true;
    }
    if (event.isCharExact('u')) {
      unawaited(app.updateProfile(profile));
      return true;
    }
    if (event.isCharExact('U')) {
      unawaited(_updateAll(app));
      return true;
    }
    if (event.isChar('r')) {
      _rename(app, profile);
      return true;
    }
    if (event.isChar('d')) {
      app.confirm(
        title: 'Delete profile',
        message: 'Delete the profile ${profile.name} and its file?',
        detail: [
          if (profile.name == app.repo.activeName)
            'The running core will keep its current config.',
        ],
        confirmLabel: 'Delete',
        danger: true,
        onConfirm: () {
          try {
            app.repo.delete(profile);
            app.toast('Deleted ${profile.name}', level: ToastLevel.success);
            _list.bind(
              total: app.repo.profiles.length,
              visible: _list.visible,
            );
          } catch (error) {
            app.toast('Delete failed: $error', level: ToastLevel.error);
          }
        },
      );
      return true;
    }
    if (event.isCharExact('E')) {
      unawaited(app.editProfile(profile));
      return true;
    }
    if (event.isCharExact('e')) {
      unawaited(app.editProfileMeta(profile));
      return true;
    }
    if (event.isChar('i')) {
      openProfileInfo(app, profile);
      return true;
    }
    return false;
  }

  Future<void> _updateAll(AppContext app) async {
    for (final profile in app.repo.profiles) {
      await app.updateProfile(profile);
    }
  }

  void _rename(AppContext app, Profile profile) {
    app.showOverlay(
      FormOverlay(
        onChanged: app.requestFrame,
        title: 'Rename profile',
        fields: [
          FormFieldSpec(
            key: 'name',
            label: 'New name',
            initial: profile.name,
            required: true,
            validator: validateProfileName,
          ),
        ],
        onSubmit: (values) {
          final name = values['name']?.trim() ?? '';
          try {
            app.repo.rename(profile, name);
            app.toast('Renamed to $name', level: ToastLevel.success);
          } catch (error) {
            app.toast('Rename failed: $error', level: ToastLevel.error);
          }
        },
      ),
    );
  }

  void openProfileInfo(AppContext app, Profile profile) {
    final info = app.repo.cachedInfo(profile.name);
    final error = app.repo.cachedError(profile.name);
    final lines = <String>[
      'Name      ${profile.name}',
      'Status      ${profile.name == app.repo.activeName ? 'Active' : 'Disabled'}',
      'File      ${app.repo.profileFile(profile.name)}',
      if (profile.size != null) 'Size      ${formatBytes(profile.size!)}',
      'Update      ${profile.updatedAt == null ? 'Never' : formatDateTime(profile.updatedAt!)}',
      'URL      ${profile.url}',
      '',
    ];
    if (error != null) {
      lines.add('Parse failed  $error');
    } else if (info != null) {
      lines.addAll([
        'Nodes      ${info.nodeCount}',
        'Proxy groups    ${info.groupCount}',
        'Rules      ${info.ruleCount}',
        'Provider  ${info.providerCount}',
        'Mode      ${info.mode}',
        'Ports      ${info.portSummary.isEmpty ? 'Not set' : info.portSummary.join(' | ')}',
        'Controller    ${info.controllerAddress ?? 'Not set'}',
        'Secret      ${info.secret == null ? 'Not set' : 'Set'}',
        'Allow LAN ${info.allowLan ? 'Yes' : 'No'}',
        'IPv6      ${info.ipv6 ? 'Yes' : 'No'}',
        'TUN       ${info.tunEnabled ? 'Enable' : 'Disabled'}',
        'Log level  ${info.logLevel ?? 'info'}',
        'Dashboard      ${info.panelUrl ?? 'None'}',
      ]);
    }
    app.showOverlay(
        InfoOverlay(title: 'Profile details | ${profile.name}', lines: lines));
  }

  @override
  bool onWheel(AppContext app, int delta) {
    _list.wheel(delta);
    return true;
  }

  @override
  void reset() => _list.reset();
}
