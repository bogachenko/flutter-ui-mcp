import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart' as logging;
import 'package:marionette_mcp/src/version.g.dart';
import 'package:marionette_mcp/src/vm_service/vm_service_context.dart';
import 'package:mcp_dart/mcp_dart.dart';

const _instructions = '''
Marionette MCP enables AI agents to interact with Flutter apps running in debug mode. It provides tools to inspect UI elements, tap buttons, enter text, scroll, take screenshots, retrieve logs, and perform hot reloads and hot restarts.

Usage:
1. When automatic VM service discovery is configured, start the Flutter app with `--vmservice-out-file` pointing to the configured file. Marionette connects and reconnects automatically.
2. Otherwise, use the "connect" tool with the Flutter VM service URI as a fallback.
3. Use "get_interactive_elements" to discover available UI elements.
4. Interact with elements using "tap", "enter_text", or "scroll_to" tools.
5. Use "take_screenshots" to see the current app state and "get_logs" to debug issues.
6. Use "hot_reload" after making code changes to reload the app without losing state.
7. Use "hot_restart" to fully restart the app from main() and reset all state — needed for changes a hot reload cannot pick up (e.g. main()/bootstrap edits, global singletons, or state shape). Requires the app to be running via `flutter run`.

Important: Elements are matched by their key (ValueKey<String>), Semantics identifier, or text content. Keys are the most reliable; a Semantics identifier (set via `Semantics(identifier: ...)`) is an equally stable alternative when adding a key is not practical. If you cannot locate a widget, you may need to add a ValueKey to it in the Flutter source code. For example: `ElevatedButton(key: ValueKey('submit_button'), ...)`.
''';

/// Runs the Marionette MCP server with the given configuration.
///
/// Sets up logging, creates the MCP server with tools, and runs it on either
/// stdio or Streamable HTTP transport depending on whether [httpPort] is provided.
Future<int> runMcpServer({
  required String logLevel,
  String? logFile,
  int? httpPort,
  String? vmServiceFile,
}) async {
  setupLogging(logLevel, logFile);

  final vmService = VmServiceContext();

  final server = McpServer(
    const Implementation(name: 'marionette-mcp', version: version),
    options: const McpServerOptions(
      // listChanged: true advertises that the tool set can change at
      // runtime — required for clients to refetch tools/list when an app
      // connects with custom extensions registered via
      // registerMarionetteExtension.
      capabilities: ServerCapabilities(
        tools: ServerCapabilitiesTools(listChanged: true),
      ),
      instructions: _instructions,
    ),
  );

  vmService.registerTools(server);

  StreamSubscription<FileSystemEvent>? vmServiceWatcher;
  if (vmServiceFile != null) {
    vmServiceWatcher = await _watchVmServiceFile(vmServiceFile, vmService);
  }

  try {
    if (httpPort != null) {
      return await _runHttpServer(server, httpPort);
    } else {
      return await _runStdioServer(server);
    }
  } finally {
    await vmServiceWatcher?.cancel();
  }
}

Future<StreamSubscription<FileSystemEvent>> _watchVmServiceFile(
  String path,
  VmServiceContext vmService,
) async {
  final logger = logging.Logger('VmServiceWatcher');
  final file = File(path).absolute;
  final directory = file.parent;
  String? lastConnectedUri;

  await directory.create(recursive: true);

  Future<void> connectFromFile() async {
    try {
      if (!await file.exists()) {
        return;
      }

      final uri = (await file.readAsString()).trim();
      if (uri.isEmpty || uri == lastConnectedUri) {
        return;
      }

      logger.info('VM service URI detected in ${file.path}');
      await vmService.connect(uri);
      lastConnectedUri = uri;
      logger.info('Automatically connected to Flutter app');
    } catch (err, st) {
      logger.warning(
        'Failed to automatically connect using ${file.path}',
        err,
        st,
      );
    }
  }

  await connectFromFile();

  Future<void> pending = Future.value();
  final subscription = directory.watch().listen((event) {
    if (File(event.path).absolute.path != file.path) {
      return;
    }

    pending = pending.then((_) => connectFromFile());
  });

  logger.info('Watching Flutter VM service file: ${file.path}');
  return subscription;
}

void setupLogging(String logLevelName, String? logFile) {
  final logLevel = logging.Level.LEVELS.firstWhere(
    (e) => e.name == logLevelName,
    orElse: () => logging.Level.INFO,
  );

  logging.Logger.root.level = logLevel;

  String formatRecord(logging.LogRecord record) {
    final buffer = StringBuffer(
      '[${record.level.name}][${record.loggerName}]'
      '[${_formatTime(record.time)}] ${record.message}',
    );

    if (record.error != null) {
      buffer.write('\n${record.error}');
    }
    if (record.stackTrace != null) {
      buffer.write('\n${record.stackTrace}');
    }

    return buffer.toString();
  }

  if (logFile != null) {
    final file = File(logFile)..createSync(recursive: true);
    logging.Logger.root.onRecord.listen((record) {
      file.writeAsStringSync(
        '${formatRecord(record)}\n',
        mode: FileMode.append,
      );
    });
  } else {
    logging.Logger.root.onRecord.listen((record) {
      stderr.writeln(formatRecord(record));
    });
  }
}

String _formatTime(DateTime time) {
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

Future<int> _runStdioServer(McpServer server) async {
  final logger = logging.Logger('main');

  final transport = StdioServerTransport();
  final exitSignal = ExitSignal();
  final stdinClosed = Completer<void>();

  // Install the close handler before connecting. An immediate stdin EOF
  // (e.g. `</dev/null`) can close the transport during or right after
  // connect(); registering afterwards risks missing that close and hanging
  // until a signal. Fires when the transport closes — including stdin EOF,
  // i.e. the MCP host went away without sending a signal. Per the stdio
  // lifecycle the server should shut down then, not wait for SIGINT/SIGTERM.
  server.server.onclose = () {
    if (!stdinClosed.isCompleted) stdinClosed.complete();
  };

  try {
    logger.fine('Running MCP server on stdio');
    await server.connect(transport);
    logger.info('Server started');
  } catch (e, st) {
    logger.severe('Error when starting the Stdio transport', e, st);
    exitSignal.dispose();
    return 1;
  }

  // Stop on whichever happens first: an OS signal or the transport closing.
  // Only the first cause is logged — closing the server below re-triggers
  // `onclose`, which would otherwise log a misleading second reason.
  var stopping = false;
  void logStop(String reason) {
    if (stopping) return;
    stopping = true;
    logger.info('$reason, stopping');
  }

  await Future.any([
    exitSignal.wait.then((signal) => logStop('Received ${signal.name}')),
    stdinClosed.future.then((_) => logStop('stdin closed')),
  ]);

  // Release the signal subscriptions so the event loop can drain and the
  // process actually exits on the stdin-EOF path.
  exitSignal.dispose();
  await server.close();
  await transport.close();
  logger.info('Stopped');
  return 0;
}

Future<int> _runHttpServer(McpServer server, int httpPort) async {
  final logger = logging.Logger('main');
  final transport = StreamableHTTPServerTransport(
    options: StreamableHTTPServerTransportOptions(
      sessionIdGenerator: () => null,
      enableJsonResponse: true,
      enableDnsRebindingProtection: true,
      allowedHosts: {'127.0.0.1', 'localhost'},
    ),
  );
  final exitSignal = ExitSignal();

  try {
    await server.connect(transport);

    final httpServer = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      httpPort,
    );

    logger.info(
      'MCP Streamable HTTP server listening on '
      'http://127.0.0.1:$httpPort/mcp',
    );

    unawaited(
      exitSignal.wait.then((signal) {
        logger.info('Received ${signal.name}, stopping');
        unawaited(httpServer.close());
      }),
    );

    await for (final request in httpServer) {
      if (request.uri.path == '/healthz') {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('ok\n');
        await request.response.close();
        continue;
      }

      if (request.uri.path != '/mcp') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found');
        await request.response.close();
        continue;
      }

      unawaited(transport.handleRequest(request));
    }

    logger.info('Stopping');
    await server.close();
    await transport.close();
  } catch (e, st) {
    logger.severe('Error when running Streamable HTTP server', e, st);
    return 1;
  } finally {
    exitSignal.dispose();
  }

  logger.info('Stopped');
  return 0;
}

/// Waits for SIGINT or SIGTERM to signal graceful shutdown.
class ExitSignal {
  ExitSignal() {
    if (!Platform.isWindows) {
      _sigtermSubscription = ProcessSignal.sigterm.watch().listen(
            _handleSignal,
          );
    }
    _sigintSubscription = ProcessSignal.sigint.watch().listen(_handleSignal);
  }

  final _completer = Completer<ProcessSignal>();
  StreamSubscription<ProcessSignal>? _sigtermSubscription;
  late final StreamSubscription<ProcessSignal> _sigintSubscription;
  bool _disposed = false;

  Future<ProcessSignal> get wait => _completer.future;

  /// Cancels the signal subscriptions so they no longer keep the event loop
  /// alive. Safe to call multiple times — in normal operation it runs once
  /// from [_handleSignal] and again from the shutdown path.
  void dispose() => _cleanup();

  void _handleSignal(ProcessSignal signal) {
    if (!_completer.isCompleted) {
      _completer.complete(signal);
      _cleanup();
    }
  }

  void _cleanup() {
    if (_disposed) return;
    _disposed = true;
    _sigtermSubscription?.cancel();
    _sigintSubscription.cancel();
  }
}
