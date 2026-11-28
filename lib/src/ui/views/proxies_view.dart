/// Proxy groups / nodes pane backed by mihomo's RESTful controller.
library;

import 'dart:async';
import 'dart:math' as math;

import '../../service/mihomo_api.dart';
import '../../util/node_sort.dart';
import '../../term/keys.dart';
import '../../term/style.dart';
import '../../term/width.dart';
import '../app_context.dart';
import '../list_state.dart';
import '../overlay.dart';
import '../painter.dart';
import '../theme.dart';
import 'view.dart';

class ProxiesView extends View {
  final ListState _groupList = ListState();
  final ListState _nodeList = ListState();
  String? _displayedGroup;
  int _pane = 0; // 0 = groups, 1 = nodes
  final Map<String, int?> _delays = {};
  final Set<String> _testing = {};
  NodeSortMode _sort = NodeSortMode.original;
  bool _testingAll = false;
  bool _cancelTestAll = false;
  int _testDone = 0;
  int _testTotal = 0;

  @override
  String get label => 'Proxies';

  @override
  String get title => 'Proxy groups';

  @override
  List<KeyHint> hints(AppContext app) => [
        const KeyHint('↑↓', 'Move'),
        const KeyHint('Tab', 'Switch column'),
        const KeyHint('Enter', 'Select node'),
        const KeyHint('t', 'Test latency'),
        const KeyHint('T', 'Test group'),
        KeyHint('s', 'Sort: ${_sort.label}'),
        const KeyHint('r', 'Refresh'),
      ];

  @override
  void onTick(AppContext app) {}

  /// Node names of [group] in the currently selected order.
  List<String> _orderedNames(ProxySnapshot snapshot, ProxyNode group) =>
      orderNodeNames(
        names: group.all,
        mode: _sort,
        nodes: snapshot.nodes,
        delays: _delays,
      );

  @override
  void draw(
    AppContext app,
    Painter painter,
    Rect area, {
    required bool focused,
  }) {
    final theme = app.theme;
    final snapshot = app.proxySnapshot;
    if (!app.apiOnline) {
      _drawNotice(
        app,
        painter,
        area,
        'Controller offline',
        [
          'Start the core in Overview and check external-controller.',
          if (app.activeInfo?.externalController == null)
            'The active config is missing external-controller.',
        ],
      );
      return;
    }
    if (snapshot == null) {
      _drawNotice(
          app, painter, area, 'Loading proxy groups', ['Press r to refresh.']);
      return;
    }
    if (snapshot.groups.isEmpty) {
      _drawNotice(app, painter, area, 'No proxy groups',
          ['The active configuration has no proxy-groups.']);
      return;
    }

    _groupList.bind(total: snapshot.groups.length, visible: _groupList.visible);
    final group = snapshot.groups[_groupList.selected];
    if (group.name != _displayedGroup) {
      _nodeList.reset();
      _displayedGroup = group.name;
    }
    final nodes = _orderedNames(snapshot, group);

    final leftWidth = (area.width * 0.28).round().clamp(18, 34);
    final leftRect = Rect(area.x, area.y, leftWidth, area.height);
    final rightRect = Rect(
      area.x + leftWidth + 1,
      area.y,
      area.width - leftWidth - 1,
      area.height,
    );

    final sortLabel = _sort == NodeSortMode.original ? '' : ' | ${_sort.label}';
    final rightTitle = _testingAll
        ? '${group.name} | Testing $_testDone/$_testTotal (Esc to cancel)'
        : '${group.name} | ${group.type} | ${nodes.length} Nodes$sortLabel';

    final listHeight = leftRect.height - 2;
    _groupList.bind(total: snapshot.groups.length, visible: listHeight);
    _groupList.ensureVisible();
    final visibleGroups =
        math.min(listHeight, snapshot.groups.length - _groupList.scroll);
    final highlight = theme.selection ??
        (theme.isLight ? Theme.light.selection : Theme.dark.selection);
    for (var row = 0; row < visibleGroups; row++) {
      final index = _groupList.scroll + row;
      final item = snapshot.groups[index];
      final isActiveGroup = index == _groupList.selected;
      final cursor = focused && _pane == 0 && isActiveGroup;
      final rowRect =
          Rect(leftRect.x + 1, leftRect.y + 1 + row, leftRect.width - 2, 1);
      final style = Style(
        fg: isActiveGroup ? theme.text : theme.muted,
        bg: cursor ? highlight : theme.panel,
        bold: isActiveGroup,
      );
      if (cursor) painter.fill(rowRect, style);
      // The `>` marker tracks the group currently shown on the right, so the
      // cursor stays visible while the node column is focused.
      painter.text(
        rowRect.x,
        rowRect.y,
        isActiveGroup ? '>' : ' ',
        Style(fg: theme.accent, bg: style.bg, bold: isActiveGroup),
      );
      painter.text(
        rowRect.x + 2,
        rowRect.y,
        truncate(item.name, rowRect.width - 4),
        style,
      );
    }

    final innerRight = Rect(
      rightRect.x + 1,
      rightRect.y + 1,
      rightRect.width - 2,
      rightRect.height - 2,
    );
    final nodeRows = innerRight.height;
    _nodeList.bind(total: nodes.length, visible: nodeRows);
    _nodeList.ensureVisible();
    final visibleNodes = math.min(nodeRows, nodes.length - _nodeList.scroll);
    final delayWidth = innerRight.width < 24 ? 6 : 9;
    for (var row = 0; row < visibleNodes; row++) {
      final index = _nodeList.scroll + row;
      final name = nodes[index];
      final node = snapshot.nodes[name];
      final isNow = group.now == name;
      final selected = focused && _pane == 1 && index == _nodeList.selected;
      final rowRect =
          Rect(innerRight.x, innerRight.y + row, innerRight.width, 1);
      final style = selected
          ? Style(fg: theme.text, bg: highlight, bold: true)
          : Style(fg: theme.text, bg: theme.panel);
      painter.fill(rowRect, style);
      painter.text(
        rowRect.x,
        rowRect.y,
        selected ? '>' : ' ',
        Style(fg: theme.accent, bg: style.bg),
      );
      painter.text(
        rowRect.x + 2,
        rowRect.y,
        isNow ? '*' : ' ',
        Style(fg: theme.green, bg: style.bg, bold: true),
      );
      painter.text(
        rowRect.x + 4,
        rowRect.y,
        truncate(name, rowRect.width - delayWidth - 4),
        Style(
          fg: isNow ? theme.green : (selected ? theme.text : theme.muted),
          bg: style.bg,
          bold: isNow || selected,
        ),
      );
      final delay = _delays.containsKey(name) ? _delays[name] : node?.delay;
      final delayText = _testing.contains(name)
          ? 'Testing'
          : delay == null
              ? (node?.alive == false ? 'Unavailable' : '-')
              : delay == 0
                  ? 'Timeout'
                  : '${delay}ms';
      final delayColor = _testing.contains(name)
          ? theme.yellow
          : delay == null
              ? theme.muted
              : delay == 0
                  ? theme.red
                  : delay < 200
                      ? theme.green
                      : delay < 500
                          ? theme.yellow
                          : theme.red;
      painter.text(
        rowRect.right - delayWidth,
        rowRect.y,
        padLeft(delayText, delayWidth - 1),
        Style(fg: delayColor, bg: style.bg),
      );
    }

    if (nodes.isEmpty) {
      painter.text(
        innerRight.x + 1,
        innerRight.y,
        'This group has no nodes.',
        Style(fg: theme.muted),
      );
    }
    // Frames last: rows can never punch through the borders.
    painter.drawBox(
      leftRect,
      focused: focused && _pane == 0,
      title: 'Proxy groups (${snapshot.groups.length})',
    );
    painter.drawBox(
      rightRect,
      focused: focused && _pane == 1,
      title: rightTitle,
    );
  }

  void _drawNotice(
    AppContext app,
    Painter painter,
    Rect area,
    String title,
    List<String> lines,
  ) {
    final theme = app.theme;
    final height = (lines.length + 4).clamp(5, area.height);
    final box = Rect(area.x, area.y, area.width, height);
    var y = box.y + 2;
    for (final line in lines) {
      if (y >= box.bottom - 1) break;
      painter.text(
        box.x + 3,
        y++,
        truncate(line, box.width - 6),
        Style(fg: theme.muted),
      );
    }
    painter.drawBox(box, title: title);
  }

  @override
  bool onKey(AppContext app, KeyEvent event) {
    if (event.isChar('r')) {
      unawaited(app.refresh());
      return true;
    }
    final snapshot = app.proxySnapshot;
    if (snapshot == null || snapshot.groups.isEmpty) return false;
    _groupList.bind(total: snapshot.groups.length, visible: _groupList.visible);
    final group = snapshot.groups[_groupList.selected];
    final ordered = _orderedNames(snapshot, group);
    _nodeList.bind(total: ordered.length, visible: _nodeList.visible);
    if (event.kind == KeyKind.tab || event.kind == KeyKind.right) {
      _pane = _pane == 0 ? 1 : 0;
      if (event.kind == KeyKind.right) _pane = 1;
      return true;
    }
    if (event.kind == KeyKind.left) {
      _pane = 0;
      return true;
    }
    if (event.kind == KeyKind.down || event.isChar('j')) {
      if (_pane == 0) {
        _groupList.moveBy(1);
        _nodeList.reset();
      } else {
        _nodeList.moveBy(1);
      }
      return true;
    }
    if (event.kind == KeyKind.up || event.isChar('k')) {
      if (_pane == 0) {
        _groupList.moveBy(-1);
        _nodeList.reset();
      } else {
        _nodeList.moveBy(-1);
      }
      return true;
    }
    if (event.kind == KeyKind.home || event.isCharExact('g')) {
      if (_pane == 0) {
        _groupList.select(0);
      } else {
        _nodeList.select(0);
      }
      return true;
    }
    if (event.kind == KeyKind.end || event.isCharExact('G')) {
      if (_pane == 0) {
        _groupList.select(snapshot.groups.length - 1);
      } else {
        _nodeList.select(ordered.length - 1);
      }
      return true;
    }
    if (event.kind == KeyKind.pageDown) {
      if (_pane == 0) {
        _groupList.wheel(_groupList.visible - 1);
      } else {
        _nodeList.wheel(_nodeList.visible - 1);
      }
      return true;
    }
    if (event.kind == KeyKind.pageUp) {
      if (_pane == 0) {
        _groupList.wheel(-(_groupList.visible - 1));
      } else {
        _nodeList.wheel(-(_nodeList.visible - 1));
      }
      return true;
    }
    if (event.kind == KeyKind.enter) {
      if (_pane == 0) {
        _pane = 1;
        return true;
      }
      if (ordered.isEmpty) return true;
      final name = ordered[_nodeList.selected];
      unawaited(_select(app, group.name, name));
      return true;
    }
    if (event.isChar('s')) {
      _sort = _sort.next;
      _nodeList.reset();
      app.toast('Node order: ${_sort.label}');
      return true;
    }
    if (event.isCharExact('T')) {
      unawaited(_testAll(app));
      return true;
    }
    if (event.kind == KeyKind.escape && _testingAll) {
      _cancelTestAll = true;
      return true;
    }
    if (event.isCharExact('t')) {
      if (_pane == 0) {
        _pane = 1;
        return true;
      }
      if (ordered.isEmpty) return true;
      unawaited(_testDelay(app, ordered[_nodeList.selected]));
      return true;
    }
    return false;
  }

  Future<void> _select(AppContext app, String group, String node) async {
    final api = app.apiRef;
    if (api == null) return;
    try {
      await api.select(group, node);
      app.toast('Selected $node', level: ToastLevel.success);
      await app.refresh();
    } on ApiException catch (error) {
      app.toast('Switch failed: ${error.message}', level: ToastLevel.error);
    }
  }

  Future<void> _testDelay(AppContext app, String name) async {
    final api = app.apiRef;
    if (api == null || !_testing.add(name)) return;
    app.requestFrame();
    try {
      final delay = await api.delay(name);
      _delays[name] = delay ?? 0;
      app.toast(
        delay == null ? '$name latency test timed out' : '$name | ${delay}ms',
        level: delay == null ? ToastLevel.warning : ToastLevel.success,
      );
    } on ApiException catch (error) {
      app.toast('Test failed: ${error.message}', level: ToastLevel.error);
    } finally {
      _testing.remove(name);
      app.requestFrame();
    }
  }

  Future<void> _testAll(AppContext app) async {
    final snapshot = app.proxySnapshot;
    final api = app.apiRef;
    if (snapshot == null || api == null) {
      app.toast('Connect the controller to test latency.',
          level: ToastLevel.warning);
      return;
    }
    if (_testingAll) {
      _cancelTestAll = true;
      return;
    }
    final group = snapshot.groups[_groupList.selected];
    final names = _orderedNames(snapshot, group)
        .where((name) => snapshot.nodes[name]?.isGroup != true)
        .toList();
    if (names.isEmpty) {
      app.toast('This group has no testable nodes.', level: ToastLevel.warning);
      return;
    }
    _testingAll = true;
    _cancelTestAll = false;
    _testDone = 0;
    _testTotal = names.length;
    var index = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelTestAll) return;
        final current = index++;
        if (current >= names.length) return;
        final name = names[current];
        if (!_testing.add(name)) {
          _testDone++;
          continue;
        }
        app.requestFrame();
        try {
          final delay = await api.delay(name, timeoutMs: 3000);
          _delays[name] = delay ?? 0;
        } on ApiException {
          _delays[name] = 0;
        } finally {
          _testing.remove(name);
          _testDone++;
          app.requestFrame();
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < 6; i++) worker(),
    ]);
    final cancelled = _cancelTestAll || _testDone < names.length;
    _testingAll = false;
    _cancelTestAll = false;
    final ok = names.where((name) => (_delays[name] ?? 0) > 0).length;
    app.toast(
      cancelled
          ? 'Tests canceled ($_testDone/$_testTotal)'
          : '$ok/${names.length} nodes passed the latency test.',
      level: cancelled ? ToastLevel.warning : ToastLevel.success,
    );
    app.requestFrame();
  }

  @override
  bool onWheel(AppContext app, int delta) {
    if (_pane == 0) {
      _groupList.wheel(delta);
    } else {
      _nodeList.wheel(delta);
    }
    return true;
  }

  @override
  void reset() {
    _groupList.reset();
    _nodeList.reset();
    _pane = 0;
  }
}
