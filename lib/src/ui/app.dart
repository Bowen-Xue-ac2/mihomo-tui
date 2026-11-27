/// The application shell: layout, input dispatch, state and background work.
library;

import 'dart:async';
import 'dart:io';

import '../model/profile.dart';
import '../model/profile_info.dart';
import '../model/settings.dart';
import '../service/autostart.dart';
import '../service/core_updater.dart';
import '../service/exporter.dart';
import '../service/mihomo_api.dart';
import '../service/mihomo_core.dart';
import '../service/paths.dart';
import '../service/profile_repo.dart';
import '../service/runtime.dart';
import '../service/system_proxy.dart';
import '../term/keys.dart';
import '../term/screen.dart';
import '../term/style.dart';
import '../term/terminal.dart';
import '../term/width.dart';
import '../util/clipboard.dart';
import '../util/format.dart';
import '../util/shell.dart';
import '../version.dart';
import 'app_context.dart';
import 'overlay.dart';
import 'painter.dart';
import 'theme.dart';
import 'views/dashboard_view.dart';
import 'views/logs_view.dart';
import 'views/profiles_view.dart';
import 'views/proxies_view.dart';
import 'views/settings_view.dart';
import 'views/view.dart';

class App implements AppContext {
  App({
    required this.terminal,
    required Settings settings,
    String? configDir,
    String? mihomoHome,
    String? binaryOverride,
    String? editorOverride,
  })  : _settings = settings,
        _configDirOverride = configDir,
        _mihomoHomeOverride = mihomoHome,
        _binaryOverride = binaryOverride,
        _editorOverride = editorOverride {
    _initServices(settings);
  }

  @override
  final TerminalBackend terminal;

  final String? _configDirOverride;
  final String? _mihomoHomeOverride;
  final String? _binaryOverride;
  final String? _editorOverride;

  Theme _theme = Theme.dark;
  bool? _lightBackground;
  String? _hoverId;

  @override
  Theme get theme => _theme;

  @override
  String? get hoverId => _hoverId;

  @override
  late AppPaths paths;

  @override
  late ProfileRepository repo;

  @override
  late MihomoCore core;

  Settings _settings;

  @override
  Settings get settings => _settings;

  late Screen _screen;
  final ScreenRenderer _renderer = ScreenRenderer();
  List<Hit> _hits = const [];
  Overlay? _paintedOverlay;
  bool _dirty = true;
  bool _exiting = false;
  bool _editing = false;

  Timer? _frameTimer;
  Timer? _tickTimer;
  final Completer<void> _quitCompleter = Completer<void>();
  StreamSubscription<TermEvent>? _eventSubscription;
  final List<StreamSubscription<ProcessSignal>> _signalSubscriptions = [];

  final View dashboard = DashboardView();
  final View profiles = ProfilesView();
  final View proxies = ProxiesView();
  final View logs = LogsView();
  final View settingsView = SettingsView();
  late final List<View> views = [
    dashboard,
    profiles,
    proxies,
    logs,
    settingsView
  ];
  int _viewIndex = 0;
  bool _sidebarFocused = false;

  final List<Overlay> _overlays = [];

  String? _toastMessage;
  ToastLevel _toastLevel = ToastLevel.info;
  DateTime? _toastUntil;

  bool _busy = false;
  String? _busyLabel;
  int _spinnerFrame = 0;
  DateTime _lastSpinner = DateTime.fromMillisecondsSinceEpoch(0);

  CoreStatus? _coreStatus;
  DateTime? _coreStartedAt;
  AutostartState _autostartState = AutostartState.unknown;
  DateTime _autostartChecked = DateTime.fromMillisecondsSinceEpoch(0);
  SystemProxyState _systemProxyState = SystemProxyState.unknown;
  DateTime _systemProxyChecked = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lanAddress;
  DateTime _lanAddressChecked = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, MirrorProbe> _mirrorProbes = {};
  final Set<String> _mirrorProbing = {};
  CoreRelease? _releaseCache;
  DateTime _releaseCachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _mirrorProbedAt = DateTime.fromMillisecondsSinceEpoch(0);

  MihomoApi? _api;
  String? _apiKey;
  bool _apiOnline = false;
  String? _apiVersion;
  ApiConfig? _apiConfig;
  ProxySnapshot? _proxySnapshot;
  ConnectionsInfo? _connections;
  ProfileInfo? _activeInfo;
  String? _activeInfoKey;

  Future<void>? _serviceRefresh;
  bool _refreshRequested = false;

  // ---------------------------------------------------------------- lifecycle

  void _initServices(Settings settings) {
    final runtime = Runtime.build(
      settings: settings,
      configDir: _configDirOverride,
      mihomoHome: _mihomoHomeOverride,
      binaryOverride: _binaryOverride,
      editorOverride: _editorOverride,
    );
    paths = runtime.paths;
    repo = runtime.repo;
    core = runtime.core;
    repo.ensureLayout();
  }

  @override
  CoreStatus? get coreStatus => _coreStatus;

  @override
  MihomoApi? get apiRef => _apiOnline ? _api : null;

  @override
  AutostartState get autostartState => _autostartState;

  @override
  SystemProxyState get systemProxyState => _systemProxyState;

  @override
  String? get lanAddress => _lanAddress;

  @override
  bool get apiOnline => _apiOnline;

  @override
  String? get apiVersion => _apiVersion;

  @override
  ApiConfig? get apiConfig => _apiConfig;

  @override
  ProxySnapshot? get proxySnapshot => _proxySnapshot;

  @override
  ConnectionsInfo? get connections => _connections;

  @override
  ProfileInfo? get activeInfo => _activeInfo;

  @override
  DateTime? get coreStartedAt => _coreStartedAt;

  @override
  bool get busy => _busy;

  @override
  String? get busyLabel => _busyLabel;

  Future<void> run() async {
    _screen = Screen(terminal.size.columns, terminal.size.rows);
    _renderer
      ..trueColor = terminal.supportsTrueColor
      ..refreshColorMode();
    try {
      terminal.start();
      terminal.setTitle('$appName $appVersion');
      _eventSubscription = terminal.events.listen(_onEvent);
      _watchSignals();
      await _detectTerminalBackground();
      _rebuildTheme();
      _render();
      unawaited(_refreshServices());
      _frameTimer =
          Timer.periodic(const Duration(milliseconds: 16), (_) => _onFrame());
      _tickTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
        unawaited(_onTick());
      });
      await _quitCompleter.future;
    } finally {
      _frameTimer?.cancel();
      _tickTimer?.cancel();
      await _eventSubscription?.cancel();
      for (final subscription in _signalSubscriptions) {
        await subscription.cancel();
      }
      _api?.dispose();
      terminal.stop();
    }
    final farewell = _farewell;
    if (farewell != null) {
      stdout.writeln(farewell);
      await stdout.flush();
    }
  }

  void _watchSignals() {
    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ...[
        ProcessSignal.sigterm,
        ProcessSignal.sighup,
      ],
    ]) {
      try {
        _signalSubscriptions.add(signal.watch().listen((_) {
          quit();
        }));
      } catch (_) {
        // Signals are not supported on all platforms.
      }
    }
  }

  String? _farewell;

  void quit() {
    if (_exiting) return;
    _exiting = true;
    if (!_quitCompleter.isCompleted) _quitCompleter.complete();
  }

  @override
  void hideToBackground() {
    final pid = _coreStatus?.pid;
    _farewell = '$appName is now in the background'
        '${pid == null ? '' : '. Mihomo is still running (PID $pid)'}'
        '. Run $appName again to reopen the interface.';
    quit();
  }

  void _rebuildTheme() {
    final light = switch (_colorMode()) {
      'light' => true,
      'dark' => false,
      _ => _lightBackground ?? false,
    };
    _theme = Theme.build(
      light: light,
      accent: _settings.accent ?? 'blue',
    );
    _dirty = true;
  }

  String _colorMode() => _settings.colorMode ?? 'auto';

  Future<void> _detectTerminalBackground() async {
    final background =
        await terminal.probeBackgroundColor() ?? _backgroundFromEnv();
    _lightBackground =
        background == null ? null : Theme.luminance(background) > 0.55;
  }

  /// Fallback for terminals that do not answer OSC 11 but export COLORFGBG
  /// (e.g. `15;0` for white on black).
  int? _backgroundFromEnv() {
    final raw = Platform.environment['COLORFGBG'];
    if (raw == null || raw.trim().isEmpty) return null;
    final index = int.tryParse(raw.split(';').last.trim());
    if (index == null || index < 0 || index >= Theme.ansiPalette.length) {
      return null;
    }
    return Theme.ansiPalette[index];
  }

  // ------------------------------------------------------------------ drawing

  void _onFrame() {
    if (_editing || _exiting) return;
    final now = DateTime.now();
    if (_busy && now.difference(_lastSpinner).inMilliseconds > 90) {
      _lastSpinner = now;
      _spinnerFrame = (_spinnerFrame + 1) % 8;
      _dirty = true;
    }
    if (_toastUntil != null && now.isAfter(_toastUntil!)) {
      _toastUntil = null;
      _toastMessage = null;
      _dirty = true;
    }
    if (_dirty) _render();
  }

  void _render() {
    _dirty = false;
    _overlays.removeWhere((overlay) => overlay.isDismissed);
    _paintedOverlay = _overlays.lastOrNull;
    final p = Painter(_screen, theme);
    final width = _screen.width;
    final height = _screen.height;
    _screen.fillRect(0, 0, width, height, Style(bg: theme.background));
    if (width < 40 || height < 10) {
      p.text(1, 1, 'Terminal too small (minimum 40x10)', Style(fg: theme.red));
      _hits = List<Hit>.unmodifiable(p.hits);
      terminal.write(_renderer.render(_screen));
      return;
    }

    _drawTopBar(p, width);
    final compact = width < 76;
    final sidebarWidth = width < 100 ? 20 : 24;
    final sidebarRect = Rect(1, 1, sidebarWidth, height - 2);
    final contentRect = Rect(
      sidebarWidth + 2,
      1,
      width - sidebarWidth - 3,
      height - 2,
    );
    if (compact) {
      _drawTabs(p, width);
      _drawContent(p, Rect(1, 2, width - 2, height - 3));
    } else {
      _drawSidebar(p, sidebarRect);
      _drawContent(p, contentRect);
    }
    _drawBottomBar(p, width, height);

    final modal = _paintedOverlay;
    if (modal != null) {
      p.hits.clear();
      modal.draw(p);
    }

    _hits = List<Hit>.unmodifiable(p.hits);
    terminal.write(_renderer.render(_screen));
  }

  void _drawTopBar(Painter p, int width) {
    p.fill(Rect(0, 0, width, 1), Style(bg: theme.header));
    final statusStyle = Style(fg: _statusColor(), bg: theme.header, bold: true);
    final status = truncate(_statusText(), width ~/ 3);
    final statusX = width - textWidth(status) - 1;
    p.text(statusX, 0, status, statusStyle);
    final nameWidth = p.text(
        1, 0, 'X', Style(fg: theme.accent, bg: theme.header, bold: true));
    final x = nameWidth + 3;
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧'];
    final label = _busy
        ? '${frames[_spinnerFrame]} ${_busyLabel ?? 'Working...'}'
        : repo.activeName ?? 'v$appVersion';
    p.text(x, 0, truncate(label, statusX - x - 1),
        Style(fg: _busy ? theme.yellow : theme.muted, bg: theme.header));
  }

  void _drawTabs(Painter p, int width) {
    for (var index = 0; index < views.length; index++) {
      final left = index * width ~/ views.length;
      final right = (index + 1) * width ~/ views.length;
      final rect = Rect(left, 1, right - left, 1);
      final style = index == _viewIndex
          ? Style(fg: theme.chipText, bg: theme.accent, bold: true)
          : Style(fg: theme.muted, bg: theme.panel);
      p.fill(rect, style);
      p.textAligned(rect, '${index + 1} ${views[index].label}', style,
          center: true);
      p.hit(rect, id: 'nav$index', onPress: () => openView(index));
    }
  }

  String _statusText() {
    final status = _coreStatus;
    if (status == null) return 'Checking';
    if (!status.running) return 'Stopped';
    final version = status.version == null ? '' : ' ${status.version}';
    return 'Running$version';
  }

  int _statusColor() {
    final status = _coreStatus;
    if (status == null) return theme.muted;
    if (!status.running) return theme.red;
    if (!_apiOnline) return theme.yellow;
    return theme.green;
  }

  void _drawSidebar(Painter p, Rect rect) {
    p.drawBox(rect, focused: _sidebarFocused, title: 'Navigation');
    final innerX = rect.x + 2;
    final innerWidth = rect.width - 4;
    var y = rect.y + 1;
    for (var index = 0; index < views.length; index++) {
      final view = views[index];
      final selected = index == _viewIndex;
      final rowRect = Rect(rect.x + 1, y, rect.width - 2, 1);
      final hoveringNav = _hoverId != null && _hoverId!.startsWith('nav');
      final hovered = _hoverId == 'nav$index';
      final style = Style(
        fg: selected ? theme.accentSoft : (hovered ? theme.text : theme.muted),
        bg: theme.panel,
        bold: selected || hovered,
      );
      // The '>' marker follows the mouse while hovering the sidebar, but the
      // displayed page only changes on click.
      final cursor = hoveringNav ? hovered : selected;
      if (cursor) {
        p.text(rect.x + 1, y, '>', Style(fg: theme.accent, bg: theme.panel));
      }
      p.text(innerX + 1, y, truncate(view.label, innerWidth), style);
      p.text(
        rect.right - 3,
        y,
        '${index + 1}',
        Style(fg: selected ? theme.muted : theme.border, bg: style.bg),
      );
      p.hit(
        rowRect,
        id: 'nav$index',
        // Hover only highlights the entry; it must not switch pages.
        onHover: () {},
        onPress: () {
          _viewIndex = index;
          _sidebarFocused = false;
          _syncView();
        },
      );
      y++;
    }

    // Bottom summary: core and profile state.
    final summary = <(String, String, Style)>[
      (
        'Status',
        _coreStatus?.running == true ? 'Running' : 'Stopped',
        Style(fg: _statusColor(), bg: theme.panel, bold: true),
      ),
      (
        'Version',
        _coreStatus?.version ?? '-',
        Style(fg: theme.muted, bg: theme.panel)
      ),
      (
        'Config',
        repo.activeName ?? 'None',
        Style(fg: theme.accentSoft, bg: theme.panel)
      ),
      (
        'Controller',
        _apiOnline
            ? 'Connected'
            : (_activeInfo?.externalController == null ? '-' : 'Offline'),
        Style(fg: _apiOnline ? theme.green : theme.muted, bg: theme.panel),
      ),
    ];
    var summaryY = rect.bottom - 1 - summary.length;
    if (summaryY > y + 1) {
      p.text(rect.x + 1, summaryY - 1, '─' * (rect.width - 2),
          Style(fg: theme.border, bg: theme.panel));
      for (final item in summary) {
        if (summaryY >= rect.bottom - 1) break;
        p.text(rect.x + 2, summaryY, item.$1,
            Style(fg: theme.muted, bg: theme.panel));
        p.text(
          rect.x + 10,
          summaryY,
          truncate(item.$2, rect.width - 12),
          item.$3,
        );
        summaryY++;
      }
    }
  }

  void _drawContent(Painter p, Rect rect) {
    final view = views[_viewIndex];
    // Views draw their own top-level borders so that nesting never produces
    // doubled border columns.
    view.draw(this, p, rect, focused: !_sidebarFocused);
  }

  void _drawBottomBar(Painter p, int width, int height) {
    final y = height - 1;
    final help = width < 56
        ? '? Help  q Quit'
        : _sidebarFocused
            ? 'Tab Content  ? Help  q Quit'
            : 'Esc Navigation  ? Help  q Quit';
    final helpX = width - textWidth(help) - 1;
    p.fill(Rect(0, y, width, 1), Style(bg: theme.header));
    var x = 1;
    p.text(helpX, y, help, Style(fg: theme.muted, bg: theme.header));
    final message = _toastMessage;
    if (message != null) {
      final color = switch (_toastLevel) {
        ToastLevel.info => theme.accent,
        ToastLevel.success => theme.green,
        ToastLevel.warning => theme.yellow,
        ToastLevel.error => theme.red,
      };
      p.text(x, y, truncate(message, helpX - x - 1),
          Style(fg: color, bg: theme.header, bold: true));
      return;
    }
    final view = views[_viewIndex];
    final hints = _sidebarFocused
        ? const [
            KeyHint('↑↓', 'Select'),
            KeyHint('Enter', 'Open'),
            KeyHint('Tab', 'Content'),
          ]
        : view.hints(this);
    for (final hint in hints) {
      if (x + textWidth(hint.keys) + textWidth(hint.label) + 5 > helpX) {
        break;
      }
      x += p.keyHint(x, y, hint.keys, hint.label);
    }
  }

  // ------------------------------------------------------------------- events

  void _onEvent(TermEvent event) {
    if (_editing || _exiting) return;
    switch (event) {
      case ResizeEvent(:final columns, :final rows):
        _hits = const [];
        _screen.resize(columns, rows);
        _renderer.invalidate();
        _dirty = true;
      case KeyEvent():
        _handleKey(event);
      case MouseEvent():
        _handleMouse(event);
      case ColorReportEvent(
          red: final red,
          green: final green,
          blue: final blue,
          isBackground: true
        ):
        final background = (red << 16) | (green << 8) | blue;
        _lightBackground = Theme.luminance(background) > 0.55;
        _rebuildTheme();
      case ColorReportEvent():
        break;
    }
  }

  void _handleKey(KeyEvent event) {
    _overlays.removeWhere((overlay) => overlay.isDismissed);
    if (_overlays.isNotEmpty) {
      _overlays.last.handleKey(event);
      _dirty = true;
      return;
    }
    if (event.isCtrl('c')) {
      quit();
      return;
    }
    if (event.isChar('q')) {
      quit();
      return;
    }
    if (event.isChar('?')) {
      _showHelp();
      return;
    }
    if (event.isChar('h') && !_sidebarFocused) {
      hideToBackground();
      return;
    }
    if (event.kind == KeyKind.char &&
        !event.ctrl &&
        !event.alt &&
        event.char != null &&
        '12345'.contains(event.char!)) {
      _viewIndex = int.parse(event.char!) - 1;
      _sidebarFocused = false;
      _syncView();
      return;
    }
    if (_sidebarFocused) {
      if (event.kind == KeyKind.down || event.isChar('j')) {
        _viewIndex = (_viewIndex + 1) % views.length;
        _syncView();
        return;
      }
      if (event.kind == KeyKind.up || event.isChar('k')) {
        _viewIndex = (_viewIndex - 1 + views.length) % views.length;
        _syncView();
        return;
      }
      if (event.kind == KeyKind.enter ||
          event.kind == KeyKind.right ||
          event.kind == KeyKind.tab) {
        _sidebarFocused = false;
        _dirty = true;
        return;
      }
      return;
    }
    final view = views[_viewIndex];
    if (view.onKey(this, event)) {
      _dirty = true;
      return;
    }
    if (event.kind == KeyKind.escape ||
        event.kind == KeyKind.tab ||
        event.kind == KeyKind.left) {
      _sidebarFocused = true;
      _dirty = true;
    }
  }

  void _handleMouse(MouseEvent event) {
    final modal = _overlays.lastOrNull;
    if (modal != _paintedOverlay || modal?.isDismissed == true) return;

    if (event.kind == MouseKind.move) {
      _handleHover(event);
      return;
    }

    if (event.kind == MouseKind.wheel) {
      for (final hit in _hits.reversed) {
        if (hit.onWheel != null && hit.rect.contains(event.x, event.y)) {
          hit.onWheel!(event.wheelDelta);
          _dirty = true;
          return;
        }
      }
      if (modal == null) views[_viewIndex].onWheel(this, event.wheelDelta);
      _dirty = true;
      return;
    }
    if (event.kind == MouseKind.press && event.button == MouseButton.left) {
      for (final hit in _hits.reversed) {
        if (hit.onPress != null && hit.rect.contains(event.x, event.y)) {
          hit.onPress!();
          _dirty = true;
          return;
        }
      }
    }
    if (modal?.handleMouse(event) == true) _dirty = true;
  }

  void _handleHover(MouseEvent event) {
    Hit? target;
    for (final hit in _hits.reversed) {
      if (hit.onHover != null && hit.rect.contains(event.x, event.y)) {
        target = hit;
        break;
      }
    }
    if (target?.id == _hoverId) return;
    _hoverId = target?.id;
    target?.onHover?.call();
    _dirty = true;
  }

  /// Terminals can report a stale size right after a resize (or miss the
  /// signal entirely); re-checking keeps the frame in sync with the window,
  /// otherwise long lines wrap and look like broken borders.
  void _syncTerminalSize() {
    final size = terminal.size;
    if (size.columns == _screen.width && size.rows == _screen.height) return;
    _screen.resize(size.columns, size.rows);
    _renderer.invalidate();
    _dirty = true;
  }

  void _syncView() {
    _hoverId = null;
    _tickView();
    _dirty = true;
    unawaited(_refreshServices());
  }

  void _tickView() {
    try {
      views[_viewIndex].onTick(this);
    } catch (_) {
      // A failed file read must not interrupt input or status polling.
    }
  }

  void _showHelp() {
    final view = views[_viewIndex];
    showOverlay(HelpOverlay([
      (
        'Global',
        const [
          KeyHint('Tab', 'Switch focus between navigation and content'),
          KeyHint('1-5', 'Jump to a page'),
          KeyHint('?', 'Toggle keyboard shortcuts'),
          KeyHint('h', 'Hide the interface, keep the core running'),
          KeyHint('q', 'Quit the interface'),
          KeyHint('↑↓ / Wheel', 'Navigate or scroll'),
          KeyHint('Enter', 'Confirm or run'),
          KeyHint('Esc', 'Cancel or back'),
          KeyHint('Ctrl+C / V', 'Copy or paste in a text field'),
          KeyHint('Ctrl+A / X', 'Select all or cut'),
          KeyHint('Shift+Arrow', 'Select text in a field'),
        ],
      ),
      ('Current page | ${view.label}', view.hints(this)),
      (
        'Profiles',
        const [
          KeyHint('a', 'Add a profile with a URL and name'),
          KeyHint('Enter', 'Activate a profile as config.yaml'),
          KeyHint('u / U', 'Refresh the selected profile or all profiles'),
          KeyHint('r', 'Rename'),
          KeyHint('d', 'Delete'),
          KeyHint('e', 'Edit the profile name and URL'),
          KeyHint('E', 'Edit the YAML in profiles/<name>.yaml'),
          KeyHint('i', 'View profile details'),
          KeyHint('Double-click', 'Activate profile'),
        ],
      ),
      (
        'Proxies',
        const [
          KeyHint('Tab / ←→', 'Switch between group and node columns'),
          KeyHint('Enter', 'Select node'),
          KeyHint('t', 'Test selected node'),
          KeyHint('T', 'Test all nodes in the group (Esc to cancel)'),
        ],
      ),
      (
        'Overview',
        const [
          KeyHint('s', 'Start or stop the core'),
          KeyHint('R', 'Restart core'),
          KeyHint('r', 'Reload the config'),
          KeyHint('m', 'Cycle modes'),
          KeyHint('o', 'Open dashboard'),
          KeyHint('p', 'Toggle system proxy'),
        ],
      ),
      (
        'Logs',
        const [
          KeyHint('s', 'Switch between Standard and Compact'),
          KeyHint('Enter', 'Show details for the selected log entry'),
          KeyHint('f',
              'Toggle follow mode. The selection marker is hidden while following.'),
          KeyHint('r', 'Reload logs'),
          KeyHint('c', 'Clear logs'),
          KeyHint('g / G', 'Jump to beginning or end'),
        ],
      ),
      (
        'Settings',
        const [
          KeyHint('Enter', 'Edit a setting or change colors'),
          KeyHint('d', 'Detect the core again'),
          KeyHint('i', 'About'),
        ],
      ),
    ]));
  }

  // ------------------------------------------------------------------ actions

  @override
  void requestFrame() {
    _dirty = true;
  }

  @override
  void openView(int index) {
    if (index < 0 || index >= views.length) return;
    _viewIndex = index;
    _sidebarFocused = false;
    _syncView();
  }

  @override
  void showOverlay(Overlay overlay) {
    _hoverId = null;
    _overlays.add(overlay);
    _dirty = true;
  }

  @override
  void toast(String message, {ToastLevel level = ToastLevel.info}) {
    _toastMessage = message;
    _toastLevel = level;
    _toastUntil = DateTime.now().add(const Duration(seconds: 5));
    _dirty = true;
  }

  @override
  void confirm({
    required String title,
    required String message,
    List<String> detail = const [],
    String confirmLabel = 'Confirm',
    bool danger = false,
    required void Function() onConfirm,
  }) {
    showOverlay(ConfirmOverlay(
      title: title,
      message: message,
      detail: detail,
      confirmLabel: confirmLabel,
      danger: danger,
      onConfirm: onConfirm,
    ));
  }

  Future<void> _runBusy(
    String label,
    Future<void> Function() action,
  ) async {
    if (_busy) {
      toast('Wait for the current action to finish.',
          level: ToastLevel.warning);
      return;
    }
    _busy = true;
    _busyLabel = label;
    _dirty = true;
    try {
      await action();
    } catch (error) {
      toast('$error', level: ToastLevel.error);
    } finally {
      _busy = false;
      _busyLabel = null;
      _dirty = true;
    }
  }

  @override
  Future<void> refresh() async {
    await _refreshServices();
    _dirty = true;
  }

  Future<void> _refreshServices({bool periodic = false}) {
    if (_exiting) return Future.value();
    final pending = _serviceRefresh;
    if (pending != null) {
      if (!periodic) _refreshRequested = true;
      return pending;
    }
    return _serviceRefresh = _drainRefreshes();
  }

  Future<void> _drainRefreshes() async {
    try {
      do {
        _refreshRequested = false;
        await _refreshServiceSnapshot();
      } while (_refreshRequested && !_exiting);
    } catch (error) {
      if (!_exiting) {
        toast('Status refresh failed: $error', level: ToastLevel.error);
      }
    } finally {
      _serviceRefresh = null;
      _dirty = true;
    }
  }

  Future<void> _refreshServiceSnapshot() async {
    final status = await core.status();
    _coreStatus = status;
    _coreStartedAt = null;
    if (status.running && status.pidFromFile) {
      final pidFile = File(paths.pidFile);
      if (pidFile.existsSync()) {
        try {
          _coreStartedAt = pidFile.statSync().modified;
        } catch (_) {}
      }
    }

    await _refreshActiveInfo();
    await _refreshApi();
    await _refreshAutostart();
    await _refreshSystemProxy();
    await _refreshLanAddress();
  }

  Autostart? _autostartOrNull() {
    final binary = core.resolveBinary();
    if (binary == null) return null;
    return Autostart(paths: paths, binary: binary);
  }

  Future<void> _refreshSystemProxy({bool force = false}) async {
    if (!force &&
        DateTime.now().difference(_systemProxyChecked) <
            const Duration(seconds: 10)) {
      return;
    }
    _systemProxyChecked = DateTime.now();
    _systemProxyState = await SystemProxy.currentState();
  }

  /// First non-loopback IPv4 address, used for the "LAN proxy" summary row.
  Future<void> _refreshLanAddress() async {
    if (DateTime.now().difference(_lanAddressChecked) <
        const Duration(seconds: 30)) {
      return;
    }
    _lanAddressChecked = DateTime.now();
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      _lanAddress = null;
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          _lanAddress ??= address.address;
        }
      }
    } catch (_) {
      _lanAddress = null;
    }
  }

  @override
  Future<void> toggleAllowLan() async {
    final api = apiRef;
    if (api == null) {
      toast('Connect the controller to change the LAN proxy setting.',
          level: ToastLevel.warning);
      return;
    }
    final enabled = _apiConfig?.allowLan ?? false;
    try {
      await api.setAllowLan(!enabled);
      await _refreshServices();
      toast(
        !enabled ? 'LAN proxy enabled.' : 'LAN proxy disabled.',
        level: ToastLevel.success,
      );
    } on ApiException catch (error) {
      toast('Switch failed: ${error.message}', level: ToastLevel.error);
    }
  }

  Future<void> _refreshAutostart() async {
    if (DateTime.now().difference(_autostartChecked) <
        const Duration(seconds: 10)) {
      return;
    }
    _autostartChecked = DateTime.now();
    final autostart = _autostartOrNull();
    if (autostart == null) {
      _autostartState = AutostartState.unsupported;
      return;
    }
    _autostartState = await autostart.state();
    if (_autostartState == AutostartState.enabled) {
      // Adopt only the pid systemd reports for *our* unit: never adopt a
      // scanned process, it may belong to another tool (mihomo-party etc).
      final pid = await autostart.mainPid();
      if (pid != null) core.adoptPid(pid);
    }
  }

  @override
  Future<void> updateCore() async {
    final updater = CoreUpdater(
      mirror: mirrorById(_settings.mirror),
      proxy: _settings.downloadProxy,
    );
    final target = core.resolveBinary() ?? CoreUpdater.defaultInstallPath();
    CoreRelease? release;
    final current = _coreStatus?.version ?? await core.version();
    await _runBusy('Check for core updates', () async {
      try {
        _busyLabel = 'Looking up the latest version...';
        _dirty = true;
        release = await updater.latest();
      } on CoreUpdateException catch (error) {
        toast('Update check failed: ${error.message}', level: ToastLevel.error);
        return;
      }
    });
    final found = release;
    if (found == null) return;
    if (_sameVersion(current, found.tag)) {
      toast('Already on the latest version ${found.tag}',
          level: ToastLevel.success);
      return;
    }
    confirm(
      title: 'Update available',
      message: '${current ?? 'Not installed'} → ${found.tag}',
      detail: [
        'Platform/arch: ${CoreUpdater.platformLabel}',
        'Download source: ${updater.mirror.label}',
        'Target: $target',
        'The previous binary will be saved as .bak.',
      ],
      confirmLabel: 'Download and install',
      onConfirm: () => unawaited(_runCoreUpdate(updater, target, found)),
    );
  }

  static bool _sameVersion(String? current, String tag) {
    String normalize(String value) =>
        value.replaceFirst(RegExp(r'^[vV]'), '').split(' ').first.trim();
    if (current == null || current.isEmpty) return false;
    return normalize(current) == normalize(tag);
  }

  Future<void> _runCoreUpdate(
    CoreUpdater updater,
    String target,
    CoreRelease release,
  ) async {
    final before = _coreStatus?.version;
    final wasRunning = _coreStatus?.running ?? false;
    await _runBusy('Update core', () async {
      try {
        if (wasRunning) {
          // A running core keeps its binary busy; stop it first.
          _busyLabel = 'Stopping the core...';
          _dirty = true;
          await _disableSystemProxyForCore();
          await core.stop();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        _busyLabel = 'Download ${release.assetName}';
        _dirty = true;
        final result = await updater.install(
          release,
          targetPath: target,
          onProgress: (received, total) {
            _busyLabel = total == null
                ? 'Download ${formatBytes(received)}'
                : 'Download ${formatBytes(received)} / ${formatBytes(total)}';
            _dirty = true;
          },
        );
        if (wasRunning) {
          _busyLabel = 'Restarting the core...';
          _dirty = true;
          final started = await core.start();
          await _refreshServices();
          if (started.isSuccess) await _enableSystemProxyForCore();
        } else {
          await _refreshServices();
        }
        toast(
          'Core updated: ${before ?? 'Not installed'} -> ${result.version}',
          level: ToastLevel.success,
        );
      } on CoreUpdateException catch (error) {
        toast('Update failed: ${error.message}', level: ToastLevel.error);
      } catch (error) {
        toast('Update failed: $error', level: ToastLevel.error);
      }
    });
  }

  @override
  Map<String, MirrorProbe> get mirrorProbes => _mirrorProbes;

  @override
  bool isMirrorProbing(String id) => _mirrorProbing.contains(id);

  @override
  void showMirrorPicker() {
    showOverlay(MirrorOverlay(
      current: _settings.mirror ?? 'direct',
      probes: _mirrorProbes,
      probing: isMirrorProbing,
      onSelect: (id) {
        unawaited(applySettings(_settings.copyWith(mirror: id)));
        toast('Download mirror: ${mirrorById(id).label}',
            level: ToastLevel.success);
      },
      onRefresh: () => unawaited(_probeMirrors(force: true)),
    ));
    unawaited(_probeMirrors());
  }

  Future<void> _probeMirrors({bool force = false}) async {
    if (_mirrorProbing.isNotEmpty) return;
    if (!force &&
        _mirrorProbes.isNotEmpty &&
        DateTime.now().difference(_mirrorProbedAt) <
            const Duration(minutes: 5)) {
      return;
    }
    final updater = CoreUpdater(mirror: mirrorById(_settings.mirror));
    var release = _releaseCache;
    if (release == null ||
        DateTime.now().difference(_releaseCachedAt) >
            const Duration(minutes: 10)) {
      try {
        release = await updater.latest();
        _releaseCache = release;
        _releaseCachedAt = DateTime.now();
      } on CoreUpdateException catch (error) {
        for (final mirror in coreMirrors) {
          _mirrorProbes[mirror.id] = MirrorProbe.unavailable(error.message);
        }
        _mirrorProbedAt = DateTime.now();
        _dirty = true;
        return;
      }
    }
    final target = release;
    _mirrorProbedAt = DateTime.now();
    await Future.wait(coreMirrors.map((mirror) async {
      _mirrorProbing.add(mirror.id);
      _dirty = true;
      final probe = await CoreUpdater.probe(
        mirror,
        target,
        proxy: _settings.downloadProxy,
      );
      _mirrorProbes[mirror.id] = probe;
      _mirrorProbing.remove(mirror.id);
      _dirty = true;
    }));
  }

  @override
  Future<void> toggleAutostart() async {
    final autostart = _autostartOrNull();
    if (autostart == null) {
      toast('Set the Mihomo executable path before enabling autostart.',
          level: ToastLevel.warning);
      return;
    }
    if (_autostartState == AutostartState.enabled) {
      confirm(
        title: 'Disable autostart',
        message: 'Remove Mihomo from startup at sign-in.',
        confirmLabel: 'Disable autostart',
        danger: true,
        onConfirm: () => unawaited(_applyAutostart(autostart, false)),
      );
      return;
    }
    confirm(
      title: 'Enable autostart',
      message:
          'Start Mihomo at sign-in using a systemd user service or Windows Run entry.',
      detail: const [
        'The service reads the active config.yaml.',
        'To also start before sign-in on Linux, run sudo loginctl enable-linger \$USER',
        'After enabling autostart, let it manage the core process.',
      ],
      confirmLabel: 'Enable autostart',
      onConfirm: () => unawaited(_applyAutostart(autostart, true)),
    );
  }

  Future<void> _applyAutostart(Autostart autostart, bool enable) async {
    await _runBusy(enable ? 'Enable autostart' : 'Disable autostart', () async {
      final result =
          enable ? await autostart.enable() : await autostart.disable();
      _autostartChecked = DateTime.fromMillisecondsSinceEpoch(0);
      await _refreshAutostart();
      await _refreshSystemProxy();
      await _refreshLanAddress();
      toast(
        result.message,
        level: result.ok ? ToastLevel.success : ToastLevel.error,
      );
    });
  }

  Future<void> _refreshActiveInfo() async {
    final file = File(paths.mihomoConfigFile);
    if (!file.existsSync()) {
      _activeInfo = null;
      _activeInfoKey = null;
      return;
    }
    String key;
    try {
      final stat = file.statSync();
      key = '${stat.modified.toIso8601String()}:${stat.size}';
    } catch (_) {
      return;
    }
    if (key == _activeInfoKey) return;
    _activeInfoKey = key;
    try {
      _activeInfo = ProfileInfo.parse(file.readAsStringSync());
    } catch (_) {
      _activeInfo = null;
    }
  }

  Future<void> _refreshApi() async {
    final info = _activeInfo;
    final base = info?.apiBase;
    if (base == null) {
      _api?.dispose();
      _api = null;
      _apiKey = null;
      _apiVersion = null;
      _apiOnline = false;
      _apiConfig = null;
      _proxySnapshot = null;
      _connections = null;
      return;
    }
    final key = '$base|${info?.secret ?? ''}';
    if (_apiKey != key) {
      _api?.dispose();
      _api = MihomoApi(baseUrl: base, secret: info?.secret);
      _apiKey = key;
      _apiVersion = null;
      _proxySnapshot = null;
      _connections = null;
    }
    final api = _api!;
    try {
      _apiConfig = await api.configs();
    } on ApiException {
      _apiOnline = false;
      _apiConfig = null;
      _apiVersion = null;
      _proxySnapshot = null;
      _connections = null;
      return;
    }
    _apiOnline = true;
    _dirty = true;
    final viewIndex = _viewIndex;

    Future<void> fetchVersion() async {
      try {
        _apiVersion = await api.version();
      } on ApiException {
        _apiVersion = null;
      }
    }

    Future<void> fetchProxies() async {
      try {
        _proxySnapshot = await api.proxies();
      } on ApiException {
        _proxySnapshot = null;
      }
    }

    Future<void> fetchConnections() async {
      try {
        _connections = await api.connections();
      } on ApiException {
        _connections = null;
      }
    }

    await Future.wait([
      if (_apiVersion == null) fetchVersion(),
      if (viewIndex == 0 || viewIndex == 2) fetchProxies(),
      if (viewIndex == 0) fetchConnections(),
    ]);
  }

  Future<void> _onTick() async {
    if (_exiting) return;
    _syncTerminalSize();
    _tickView();
    await _refreshServices(periodic: true);
  }

  @override
  Future<void> startCore() async {
    if (core.resolveBinary() == null) {
      toast('Set the Mihomo executable path in Settings.',
          level: ToastLevel.error);
      return;
    }
    if (repo.activeName == null && !File(paths.mihomoConfigFile).existsSync()) {
      toast('Activate a profile first.', level: ToastLevel.warning);
      return;
    }
    final status = _coreStatus;
    if (status?.running == true) {
      final external = status?.pidFromFile == false;
      confirm(
        title: 'Mihomo is already running',
        message: 'Mihomo PID ${status?.pid}'
            '${external ? ' (started by another app)' : ''} must stop before starting a new instance.',
        detail: external
            ? const ['Stopping this process may affect its managing app.']
            : const [],
        confirmLabel: 'Stop and start',
        danger: true,
        onConfirm: () => unawaited(_startCoreNow(stopFirst: true)),
      );
      return;
    }
    await _startCoreNow();
  }

  Future<void> _startCoreNow({bool stopFirst = false}) async {
    await _runBusy('Start core', () async {
      if (stopFirst) {
        await core.stop();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      final result = await core.start();
      if (!result.isSuccess) {
        _reportCoreError('Start failed', result.error ?? 'Unknown error');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _refreshServices();
      if (_coreStatus?.running == true) {
        toast(
          'Mihomo started${_coreStatus?.pid == null ? '' : ', PID ${_coreStatus!.pid}'}',
          level: ToastLevel.success,
        );
        await _enableSystemProxyForCore();
      } else {
        toast('Mihomo exited after startup. Check Logs.',
            level: ToastLevel.error);
      }
    });
  }

  @override
  Future<void> stopCore() async {
    final status = _coreStatus;
    if (status?.running == true && !status!.pidFromFile) {
      confirm(
        title: 'Stop an external process',
        message: 'Mihomo PID ${status.pid} is managed by another app. Stop it?',
        detail: const [
          'Stopping it will interrupt the app using that process.'
        ],
        confirmLabel: 'Stop process',
        danger: true,
        onConfirm: () => unawaited(_stopCoreNow()),
      );
      return;
    }
    await _stopCoreNow();
  }

  Future<void> _stopCoreNow() async {
    await _runBusy('Stop core', () async {
      final stopped = await core.stop();
      if (stopped) await _disableSystemProxyForCore();
      await _refreshServices();
      if (stopped) {
        toast('Mihomo stopped.', level: ToastLevel.success);
      } else {
        toast('No running Mihomo process found.', level: ToastLevel.warning);
      }
    });
  }

  /// Turns the system proxy on together with the core (skipped when the core
  /// has no proxy port or the platform does not support it).
  Future<void> _enableSystemProxyForCore() async {
    final info = _activeInfo;
    final port = info?.preferredProxyPort;
    if (port == null) return;
    final result = await SystemProxy.enable(
      httpPort: info?.mixedPort ?? info?.port ?? port,
      socksPort: info?.socksPort ?? port,
    );
    if (!result.ok) return;
    _systemProxyState = SystemProxyState.enabled;
    _systemProxyChecked = DateTime.now();
    toast('System proxy enabled.', level: ToastLevel.success);
    _dirty = true;
  }

  /// Turns the system proxy off when the core stops — but only if it points at
  /// our own core (either we enabled it, or the port matches).
  Future<void> _disableSystemProxyForCore() async {
    final state = await SystemProxy.currentState();
    if (state != SystemProxyState.enabled) return;
    final ourPort = _activeInfo?.preferredProxyPort;
    final ours = ourPort != null && await SystemProxy.pointsToLoopback(ourPort);
    if (!ours) return;
    final result = await SystemProxy.disable();
    if (!result.ok) return;
    _systemProxyState = SystemProxyState.disabled;
    _systemProxyChecked = DateTime.now();
    toast('System proxy disabled.', level: ToastLevel.success);
    _dirty = true;
  }

  @override
  Future<void> restartCore() async {
    await _runBusy('Restart core', _restartCoreNow);
  }

  Future<void> _restartCoreNow() async {
    final wasRunning = core.detectPid() != null;
    if (!await core.stop() && wasRunning) {
      toast('Could not stop the running core.', level: ToastLevel.error);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final result = await core.start();
    await _refreshServices();
    if (result.isSuccess && _coreStatus?.running == true) {
      toast(
          'Mihomo restarted${_coreStatus?.pid == null ? '' : ', PID ${_coreStatus!.pid}'}',
          level: ToastLevel.success);
    } else {
      _reportCoreError(
          'Restart failed', result.error ?? 'Mihomo exited after startup.');
    }
  }

  void _reportCoreError(String title, String detail) {
    final lines = detail
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.length <= 1) {
      toast('$title: ${lines.isEmpty ? detail : lines.first}',
          level: ToastLevel.error);
      return;
    }
    showOverlay(InfoOverlay(
      title: title,
      lines: [
        ...lines,
        '',
        'Full logs: ${paths.logFile}',
        'Check the Mihomo executable path in Settings.',
      ],
    ));
  }

  @override
  Future<void> reloadConfig() async {
    final api = apiRef;
    if (api == null) {
      toast('Controller offline', level: ToastLevel.warning);
      return;
    }
    await _runBusy('Reload config', () async {
      try {
        await api.reload();
        toast('Configuration reloaded.', level: ToastLevel.success);
      } on ApiException catch (error) {
        toast('Reload failed: ${error.message}', level: ToastLevel.error);
      }
      await _refreshServices();
    });
  }

  @override
  Future<void> setMode(String mode) async {
    final api = apiRef;
    if (api == null) {
      toast('Controller offline', level: ToastLevel.warning);
      return;
    }
    try {
      await api.setMode(mode);
      await _refreshServices();
      toast('Mode set to $mode', level: ToastLevel.success);
    } on ApiException catch (error) {
      toast('Mode change failed: ${error.message}', level: ToastLevel.error);
    }
  }

  @override
  Future<void> activateProfile(Profile profile) async {
    final running = _coreStatus?.running ?? false;
    if (profile.name == repo.activeName && running) {
      toast('${profile.name} is already active.');
      return;
    }
    void apply() {
      try {
        repo.activate(profile);
        _activeInfoKey = null;
        _dirty = true;
        toast('Activated ${profile.name}', level: ToastLevel.success);
        if (running) {
          confirm(
            title: 'Restart core',
            message: 'Restart Mihomo to apply ${profile.name}?',
            confirmLabel: 'Restart',
            onConfirm: () => unawaited(restartCore()),
          );
        }
        unawaited(refresh());
      } catch (error) {
        toast('Activation failed: $error', level: ToastLevel.error);
      }
    }

    if (running) {
      confirm(
        title: 'Switch profile',
        message:
            'Mihomo is running. Switching profiles will replace config.yaml.',
        detail: [
          'Target file: ${paths.mihomoConfigFile}',
          'Restart to apply the profile. The previous config is kept as config.yaml.bak.',
        ],
        confirmLabel: 'Switch',
        onConfirm: apply,
      );
    } else {
      apply();
    }
  }

  @override
  Future<void> updateProfile(Profile profile) async {
    await _runBusy('Refreshing ${profile.name}', () async {
      try {
        await repo.update(
          profile,
          onProgress: (progress) {
            final percent = progress.fraction;
            _busyLabel = percent == null
                ? 'Refreshing ${profile.name} ${formatBytes(progress.received)}'
                : 'Refreshing ${profile.name} ${(percent * 100).round()}%';
            _dirty = true;
          },
        );
        repo.invalidateCache(profile.name);
        _activeInfoKey = null;
        toast('Refreshed ${profile.name}', level: ToastLevel.success);
        if (profile.name == repo.activeName &&
            File(paths.mihomoConfigFile).existsSync()) {
          repo.activate(profile);
          _activeInfoKey = null;
        }
        await _refreshServices();
      } on ProfileException catch (error) {
        toast('Update failed: ${error.message}', level: ToastLevel.error);
      }
    });
  }

  @override
  Future<void> addProfileInteractive() async {
    showOverlay(FormOverlay(
      onChanged: requestFrame,
      title: 'Add profile',
      description: const [
        'Enter a Mihomo subscription URL. The YAML and node count will be checked.',
      ],
      fields: [
        FormFieldSpec(
          key: 'url',
          label: 'ProfilesURL',
          hint: 'https://example.com/subscribe?token=...',
          required: true,
          validator: validateSubscriptionUrl,
        ),
        FormFieldSpec(
          key: 'name',
          label: 'Profile name',
          hint: 'Example: personal',
          required: true,
          validator: validateProfileName,
        ),
        FormFieldSpec(
          key: 'activate',
          label: 'Activate after download (replaces config.yaml)',
          kind: FieldKind.toggle,
          initialToggle: repo.activeName == null,
        ),
        FormFieldSpec(
          key: 'start',
          label: 'Restart the core after activation',
          kind: FieldKind.toggle,
          initialToggle: false,
        ),
      ],
      submitLabel: 'Download',
      onSubmit: (values) {
        final url = values['url']?.trim() ?? '';
        final name = values['name']?.trim() ?? '';
        final activate = values['activate'] == 'true';
        final start = values['start'] == 'true';
        unawaited(_addProfile(url, name, activate, start));
      },
    ));
  }

  Future<void> _addProfile(
    String url,
    String name,
    bool activate,
    bool start,
  ) async {
    await _runBusy('Download profile', () async {
      try {
        await repo.add(
          name: name,
          url: url,
          onProgress: (progress) {
            final percent = progress.fraction;
            _busyLabel = percent == null
                ? 'Download profile ${formatBytes(progress.received)}'
                : 'Download profile ${(percent * 100).round()}% | ${formatBytes(progress.received)}';
            _dirty = true;
          },
        );
        final profile = repo.byName(name);
        if (profile == null) {
          throw ProfileException('Could not save the profile.');
        }
        final nodes = repo.cachedInfo(name)?.nodeCount;
        toast(
          nodes == null ? 'Added $name' : 'Added $name with $nodes nodes.',
          level: ToastLevel.success,
        );
        if (activate) {
          repo.activate(profile);
          _activeInfoKey = null;
          toast('Activated $name', level: ToastLevel.success);
          if (start) {
            await _restartCoreNow();
          }
        }
        await _refreshServices();
      } on ProfileException catch (error) {
        toast('Could not add profile: ${error.message}',
            level: ToastLevel.error);
      }
    });
  }

  @override
  Future<void> editActiveConfig() async {
    final file = File(paths.mihomoConfigFile);
    if (!file.existsSync()) {
      toast('Activate a profile to create config.yaml.',
          level: ToastLevel.warning);
      return;
    }
    final edited = await _runEditor(file.path);
    if (edited == null) return;
    if (edited.isNotEmpty) {
      toast(edited, level: ToastLevel.error);
      return;
    }
    String? parseError;
    try {
      ProfileInfo.parse(file.readAsStringSync());
    } on FormatException catch (error) {
      parseError = error.message;
    }
    _activeInfoKey = null;
    await _refreshServices();
    if (parseError != null) {
      toast('Could not parse config.yaml: $parseError',
          level: ToastLevel.error);
      return;
    }
    toast('Saved ${paths.mihomoConfigFile}', level: ToastLevel.success);
    if (_apiOnline) {
      confirm(
        title: 'Reload config',
        message: 'Reload the updated config.yaml in the running core?',
        confirmLabel: 'Reload',
        onConfirm: () => unawaited(reloadConfig()),
      );
    }
  }

  /// Runs the configured editor on [file]. Returns null when nothing was
  /// saved, otherwise an error message (empty string means success).
  Future<String?> _runEditor(String file) async {
    final editor = paths.editor.trim();
    if (editor.isEmpty) {
      toast('Set an editor in Settings.', level: ToastLevel.warning);
      return null;
    }
    final parts = splitCommand(editor);
    if (parts.isEmpty) {
      toast('Set an editor command in Settings.', level: ToastLevel.warning);
      return null;
    }
    _editing = true;
    terminal.suspend();
    var failure = '';
    try {
      final process = await Process.start(
        parts.first,
        [...parts.skip(1), file],
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await process.exitCode;
      if (code != 0) failure = 'Editor exit code $code';
    } on ProcessException catch (error) {
      failure = 'Could not start the editor: ${error.message}';
    } finally {
      if (!_exiting) terminal.resume();
      _editing = false;
      _syncTerminalSize();
      _renderer.invalidate();
      _dirty = true;
    }
    return failure;
  }

  @override
  Future<void> editProfileMeta(Profile profile) async {
    showOverlay(FormOverlay(
      onChanged: requestFrame,
      title: 'Edit profile details',
      description: const [
        'Edit the name and subscription URL independently of the downloaded YAML.'
      ],
      fields: [
        FormFieldSpec(
          key: 'name',
          label: 'Name',
          initial: profile.name,
          required: true,
          validator: validateProfileName,
        ),
        FormFieldSpec(
          key: 'url',
          label: 'ProfilesURL',
          initial: profile.url,
          hint: 'https://example.com/subscribe?token=...',
          required: true,
          validator: validateSubscriptionUrl,
        ),
        FormFieldSpec(
          key: 'download',
          label: 'Download the profile again after saving',
          kind: FieldKind.toggle,
        ),
      ],
      submitLabel: 'Save',
      onSubmit: (values) {
        unawaited(_applyProfileMeta(profile, values));
      },
    ));
  }

  Future<void> _applyProfileMeta(
    Profile profile,
    Map<String, String> values,
  ) async {
    final name = values['name']?.trim() ?? '';
    final url = values['url']?.trim() ?? '';
    final download = values['download'] == 'true';
    Profile updated;
    try {
      updated = repo.updateMeta(profile, name: name, url: url);
    } catch (error) {
      toast('Save failed: $error', level: ToastLevel.error);
      return;
    }
    _activeInfoKey = null;
    toast('Updated profile details for ${updated.name}',
        level: ToastLevel.success);
    if (download) {
      await updateProfile(updated);
    } else {
      await _refreshServices();
    }
  }

  @override
  Future<void> editProfile(Profile profile) async {
    final edited = await _runEditor(repo.profileFile(profile.name));
    if (edited == null) return;
    repo.invalidateCache(profile.name);
    _activeInfoKey = null;
    if (edited.isNotEmpty) {
      toast(edited, level: ToastLevel.error);
      return;
    }
    final error = repo.cachedError(profile.name);
    if (error != null) {
      toast('Configuration parse failed: $error', level: ToastLevel.error);
      return;
    }
    toast('Saved ${profile.name}', level: ToastLevel.success);
    if (profile.name == repo.activeName) {
      confirm(
        title: 'Reapply profile',
        message: 'Apply the updated profile as config.yaml and restart?',
        detail: ['Target file: ${paths.mihomoConfigFile}'],
        confirmLabel: 'Apply',
        onConfirm: () {
          try {
            repo.activate(profile);
            _activeInfoKey = null;
            unawaited(restartCore());
          } catch (error) {
            toast('Apply failed: $error', level: ToastLevel.error);
          }
        },
      );
    }
    await _refreshServices();
  }

  @override
  void openUrl(String url) {
    try {
      final List<String> command;
      if (Platform.isWindows) {
        command = ['cmd', '/c', 'start', '', url];
      } else if (Platform.isMacOS) {
        command = ['open', url];
      } else {
        command = ['xdg-open', url];
      }
      unawaited(Process.start(
        command.first,
        command.skip(1).toList(),
        mode: ProcessStartMode.detached,
      ));
    } catch (error) {
      toast('Open failed: $error', level: ToastLevel.error);
    }
  }

  @override
  bool copyToClipboard(String text) {
    if (!Clipboard.canWrite) return false;
    unawaited(Clipboard.write(text));
    return true;
  }

  @override
  Future<void> applySettings(Settings next) async {
    final previous = _settings;
    next.save(paths.settingsFile);
    _settings = next;
    if (previous.mihomoBin != next.mihomoBin ||
        previous.mihomoHome != next.mihomoHome ||
        previous.editor != next.editor ||
        previous.downloadProxy != next.downloadProxy) {
      _initServices(next);
      _apiKey = null;
      _activeInfoKey = null;
      _apiOnline = false;
      _coreStatus = null;
    }
    _rebuildTheme();
    await _refreshServices();
    _dirty = true;
  }

  @override
  Future<void> cycleThemeAccent() async {
    final order = Theme.accentOrder;
    final current = _settings.accent ?? 'blue';
    final index = order.indexOf(current);
    final next = order[(index + 1) % order.length];
    await applySettings(_settings.copyWith(accent: next));
    toast('Accent color: ${Theme.accentLabel(next)}',
        level: ToastLevel.success);
  }

  @override
  Future<void> cycleColorMode() async {
    const modes = ['auto', 'dark', 'light'];
    final current = _colorMode();
    final next = modes[(modes.indexOf(current) + 1) % modes.length];
    if (next == 'auto') {
      await _detectTerminalBackground();
    }
    await applySettings(_settings.copyWith(colorMode: next));
    toast(
      switch (next) {
        'auto' =>
          'Colors: terminal default (${_theme.isLight ? 'light' : 'dark'})',
        'light' => 'Colors: light',
        _ => 'Colors: dark',
      },
      level: ToastLevel.success,
    );
  }

  @override
  Future<void> toggleSystemProxy() async {
    final state = await SystemProxy.currentState();
    if (state == SystemProxyState.unsupported) {
      toast('System proxy controls are unavailable on this platform.',
          level: ToastLevel.warning);
      return;
    }
    if (state == SystemProxyState.enabled) {
      final port = _activeInfo?.mixedPort ?? _activeInfo?.port;
      if (port == null || !await SystemProxy.pointsToLoopback(port)) {
        toast('Another app owns the system proxy.', level: ToastLevel.warning);
        return;
      }
      await _disableSystemProxy();
      return;
    }
    final info = _activeInfo;
    final port = info?.preferredProxyPort;
    if (port == null) {
      toast('The active config has no usable proxy port.',
          level: ToastLevel.warning);
      return;
    }
    final result = await SystemProxy.enable(
      httpPort: info?.mixedPort ?? info?.port ?? port,
      socksPort: info?.socksPort ?? port,
    );
    if (result.ok) {
      _systemProxyState = SystemProxyState.enabled;
      _systemProxyChecked = DateTime.now();
      _dirty = true;
    }
    toast(
      result.message,
      level: result.ok ? ToastLevel.success : ToastLevel.error,
    );
    await _refreshSystemProxy(force: true);
    _dirty = true;
  }

  Future<void> _disableSystemProxy() async {
    final result = await SystemProxy.disable();
    if (result.ok) {
      _systemProxyState = SystemProxyState.disabled;
      _systemProxyChecked = DateTime.now();
      _dirty = true;
    }
    toast(
      result.message,
      level: result.ok ? ToastLevel.success : ToastLevel.error,
    );
    await _refreshSystemProxy(force: true);
    _dirty = true;
  }

  @override
  Future<void> exportData() async {
    await _runBusy('Export data', () async {
      try {
        final exporter = DataExporter(paths: paths, settings: _settings);
        final result = await exporter.export();
        toast(
          'Exported ${result.entries.length} items (${formatBytes(result.bytes)}) to ${result.file.path}',
          level: ToastLevel.success,
        );
      } catch (error) {
        toast('Export failed: $error', level: ToastLevel.error);
      }
    });
  }
}
