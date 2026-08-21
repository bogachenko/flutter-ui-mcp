import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart' as logging;
import 'package:mcp_dart/mcp_dart.dart';

typedef _ChromeProcess = ({int port, Uri? launchUri});
typedef _Target = ({String id, String url, Uri browserWebSocketUri});
typedef _Snapshot = ({String targetId, Map<String, dynamic> bounds});

/// Registers viewport controls for Flutter Web running in Chrome on Linux.
/// Chrome's random DevTools port is discovered automatically.
void registerWebViewportTools(McpServer server) {
  final viewport = _WebViewport();

  server
    ..registerTool(
      'set_viewport',
      description:
          'Sets the Flutter Web viewport to an exact width and height in CSS pixels. Linux only. Chrome must be launched by `flutter run -d chrome`; its random DevTools port is discovered automatically.',
      annotations: const ToolAnnotations(
        title: 'Set Web Viewport',
        idempotentHint: true,
      ),
      inputSchema: ToolInputSchema(
        properties: {
          'width': JsonSchema.number(
            description: 'Viewport width in CSS pixels.',
          ),
          'height': JsonSchema.number(
            description: 'Viewport height in CSS pixels.',
          ),
        },
        required: ['width', 'height'],
      ),
      callback: (args, extra) => viewport.run('set viewport', () async {
        final width = _dimension(args['width'], 'width');
        final height = _dimension(args['height'], 'height');
        await viewport.set(width, height);
        return 'Viewport set to ${width}x$height CSS px.';
      }),
    )
    ..registerTool(
      'reset_viewport',
      description:
          'Restores the Flutter Web Chrome window to the size and window state it had before the first set_viewport call. Linux only.',
      annotations: const ToolAnnotations(
        title: 'Reset Web Viewport',
        idempotentHint: true,
      ),
      inputSchema: const ToolInputSchema(properties: {}),
      callback: (args, extra) => viewport.run(
        'reset viewport',
        viewport.reset,
      ),
    );
}

int _dimension(Object? raw, String name) {
  if (raw is! num || !raw.isFinite || raw % 1 != 0) {
    throw ArgumentError.value(raw, name, 'must be an integer');
  }

  final value = raw.toInt();
  if (value < 1 || value > 10000000) {
    throw ArgumentError.value(raw, name, 'must be between 1 and 10000000');
  }
  return value;
}

final class _WebViewport {
  final _logger = logging.Logger('WebViewport');
  _Snapshot? _original;

  Future<CallToolResult> run(
    String operation,
    Future<String> Function() body,
  ) async {
    try {
      return CallToolResult(
        content: [TextContent(text: await body())],
      );
    } catch (err, st) {
      _logger.warning('Failed to $operation', err, st);
      return CallToolResult(
        isError: true,
        content: [TextContent(text: err.toString())],
      );
    }
  }

  Future<void> set(int width, int height) async {
    final target = await _discoverTarget(preferredId: _original?.targetId);
    final cdp = await _Cdp.connect(target.browserWebSocketUri);

    try {
      final window = await cdp.send(
        'Browser.getWindowForTarget',
        {'targetId': target.id},
      );
      final windowId = window['windowId'];
      final bounds = window['bounds'];
      if (windowId is! int || bounds is! Map) {
        throw StateError('Chrome did not return browser window information.');
      }

      final currentBounds = Map<String, dynamic>.from(bounds);
      if (_original == null || _original!.targetId != target.id) {
        _original = (
          targetId: target.id,
          bounds: _copyBounds(currentBounds),
        );
      }

      await _makeWindowNormal(
        cdp,
        windowId,
        currentBounds['windowState'] as String?,
      );
      await cdp.send(
        'Browser.setContentsSize',
        {'windowId': windowId, 'width': width, 'height': height},
      );
    } finally {
      await cdp.close();
    }
  }

  Future<String> reset() async {
    final original = _original;
    if (original == null) {
      return 'Viewport is already at its original size.';
    }

    final target = await _discoverTarget(preferredId: original.targetId);
    if (target.id != original.targetId) {
      _original = null;
      return 'The original Flutter Web page is no longer running; viewport state was cleared.';
    }

    final cdp = await _Cdp.connect(target.browserWebSocketUri);
    try {
      final window = await cdp.send(
        'Browser.getWindowForTarget',
        {'targetId': target.id},
      );
      final windowId = window['windowId'];
      final bounds = window['bounds'];
      if (windowId is! int || bounds is! Map) {
        throw StateError('Chrome did not return browser window information.');
      }

      await _makeWindowNormal(
        cdp,
        windowId,
        bounds['windowState'] as String?,
      );

      final geometry = <String, dynamic>{};
      for (final key in const ['left', 'top', 'width', 'height']) {
        final value = original.bounds[key];
        if (value != null) {
          geometry[key] = value;
        }
      }
      if (geometry.isNotEmpty) {
        await cdp.send(
          'Browser.setWindowBounds',
          {'windowId': windowId, 'bounds': geometry},
        );
      }

      final state = original.bounds['windowState'] as String? ?? 'normal';
      if (state != 'normal') {
        await cdp.send(
          'Browser.setWindowBounds',
          {
            'windowId': windowId,
            'bounds': {'windowState': state},
          },
        );
      }

      _original = null;
      return 'Viewport reset to the original browser size.';
    } finally {
      await cdp.close();
    }
  }

  Future<void> _makeWindowNormal(
    _Cdp cdp,
    int windowId,
    String? currentState,
  ) async {
    final state = currentState ?? 'normal';
    if (state == 'normal') {
      return;
    }

    Future<void> normalize() async {
      await cdp.send(
        'Browser.setWindowBounds',
        {
          'windowId': windowId,
          'bounds': {'windowState': 'normal'},
        },
      );
    }

    await normalize();
    if (state == 'fullscreen') {
      await normalize();
    }
  }

  Future<_Target> _discoverTarget({String? preferredId}) async {
    if (!Platform.isLinux) {
      throw UnsupportedError(
        'set_viewport and reset_viewport currently support Flutter Web on Linux only.',
      );
    }

    final targets = <_Target>[];
    for (final chrome in _flutterChromeProcesses()) {
      targets.addAll(await _targets(chrome));
    }

    if (preferredId != null) {
      for (final target in targets) {
        if (target.id == preferredId) {
          return target;
        }
      }
    }
    if (targets.length == 1) {
      return targets.single;
    }
    if (targets.isEmpty) {
      throw StateError(
        'No Flutter-managed Chrome page found. Start it with `flutter run -d chrome`; no fixed Chrome debug port is required.',
      );
    }

    throw StateError(
      'Found multiple Flutter-managed Chrome pages: '
      '${targets.map((target) => target.url).join(', ')}. '
      'Keep only one `flutter run -d chrome` instance active before resizing.',
    );
  }

  List<_ChromeProcess> _flutterChromeProcesses() {
    final processes = <_ChromeProcess>[];
    for (final entity in Directory('/proc').listSync(followLinks: false)) {
      if (entity is! Directory ||
          int.tryParse(entity.path.split('/').last) == null) {
        continue;
      }

      try {
        final args = utf8
            .decode(
              File('${entity.path}/cmdline').readAsBytesSync(),
              allowMalformed: true,
            )
            .split('\u0000')
            .where((arg) => arg.isNotEmpty)
            .toList();

        String? debugPort;
        String? userDataDir;
        for (final arg in args) {
          if (arg.startsWith('--remote-debugging-port=')) {
            debugPort = arg;
          }
          if (arg.startsWith('--user-data-dir=')) {
            userDataDir = arg;
          }
        }
        if (debugPort == null ||
            userDataDir == null ||
            !userDataDir.contains('flutter_tools_chrome_device.')) {
          continue;
        }

        final port = int.tryParse(debugPort.split('=').last);
        if (port == null || port <= 0) {
          continue;
        }

        Uri? launchUri;
        for (final arg in args.reversed) {
          final uri = Uri.tryParse(arg);
          if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
            launchUri = uri;
            break;
          }
        }
        processes.add((port: port, launchUri: launchUri));
      } on FileSystemException {
        // A process can disappear while /proc is being scanned.
      }
    }
    return processes;
  }

  Future<List<_Target>> _targets(_ChromeProcess chrome) async {
    final http = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    try {
      final version = await _getJson(http, chrome.port, '/json/version');
      final browserWebSocketUrl = version is Map
          ? version['webSocketDebuggerUrl'] as String?
          : null;
      final browserWebSocketUri = browserWebSocketUrl == null
          ? null
          : Uri.tryParse(browserWebSocketUrl);
      if (browserWebSocketUri == null) {
        return const [];
      }

      final decoded = await _getJson(http, chrome.port, '/json/list');
      if (decoded is! List) {
        return const [];
      }

      final targets = <_Target>[];
      for (final raw in decoded) {
        if (raw is! Map || raw['type'] != 'page') {
          continue;
        }
        final id = raw['id'];
        final url = raw['url'];
        if (id is! String || url is! String) {
          continue;
        }

        final pageUri = Uri.tryParse(url);
        if (pageUri == null) {
          continue;
        }
        if (chrome.launchUri != null &&
            !_sameOrigin(pageUri, chrome.launchUri!)) {
          continue;
        }
        targets.add(
          (
            id: id,
            url: url,
            browserWebSocketUri: browserWebSocketUri,
          ),
        );
      }
      return targets;
    } catch (err) {
      _logger.fine('Could not inspect Chrome CDP port ${chrome.port}: $err');
      return const [];
    } finally {
      http.close(force: true);
    }
  }

  Future<Object?> _getJson(HttpClient http, int port, String path) async {
    final request = await http
        .getUrl(Uri.parse('http://127.0.0.1:$port$path'))
        .timeout(const Duration(seconds: 1));
    final response = await request.close().timeout(const Duration(seconds: 1));
    if (response.statusCode != HttpStatus.ok) {
      return null;
    }

    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 1));
    return jsonDecode(body);
  }
}

Map<String, dynamic> _copyBounds(Map<String, dynamic> bounds) => {
      for (final key in const ['left', 'top', 'width', 'height', 'windowState'])
        if (bounds[key] != null) key: bounds[key],
    };

bool _sameOrigin(Uri a, Uri b) =>
    a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
    _sameHost(a.host, b.host) &&
    _port(a) == _port(b);

bool _sameHost(String a, String b) {
  a = a.toLowerCase();
  b = b.toLowerCase();
  if (a == b) {
    return true;
  }
  const loopback = {'localhost', '127.0.0.1', '::1'};
  return loopback.contains(a) && loopback.contains(b);
}

int _port(Uri uri) =>
    uri.hasPort ? uri.port : (uri.scheme.toLowerCase() == 'https' ? 443 : 80);

final class _Cdp {
  _Cdp._(this._socket) : _messages = StreamIterator<dynamic>(_socket);

  final WebSocket _socket;
  final StreamIterator<dynamic> _messages;
  var _nextId = 0;

  static Future<_Cdp> connect(Uri uri) async => _Cdp._(
        await WebSocket.connect(uri.toString()).timeout(
          const Duration(seconds: 2),
        ),
      );

  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final id = ++_nextId;
    _socket.add(
      jsonEncode({
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );

    while (await _messages.moveNext().timeout(const Duration(seconds: 3))) {
      final raw = _messages.current;
      final text = raw is String
          ? raw
          : raw is List<int>
              ? utf8.decode(raw)
              : null;
      if (text == null) {
        continue;
      }

      final response = jsonDecode(text);
      if (response is! Map || response['id'] != id) {
        continue;
      }
      if (response['error'] != null) {
        throw StateError('CDP $method failed: ${response['error']}');
      }
      final result = response['result'];
      return result is Map ? Map<String, dynamic>.from(result) : const {};
    }
    throw StateError('Chrome DevTools connection closed unexpectedly.');
  }

  Future<void> close() async {
    await _messages.cancel();
    await _socket.close();
  }
}
