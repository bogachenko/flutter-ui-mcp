import 'dart:io';

import 'package:args/args.dart';
import 'package:marionette_mcp/src/mcp_server_runner.dart';
import 'package:marionette_mcp/src/version.g.dart';

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag('version', negatable: false, help: 'Print the tool version.')
    ..addOption(
      'log-level',
      abbr: 'l',
      defaultsTo: 'INFO',
      help: 'Log level (FINEST, FINER, FINE, CONFIG, INFO, WARNING, SEVERE).',
    )
    ..addOption(
      'log-file',
      help: 'Path to log file. If not set, logs to stderr.',
    )
    ..addOption(
      'http-port',
      help:
          'Port for Streamable HTTP server. If not set, uses stdio transport.',
    )
    ..addOption(
      'vmservice-file',
      help: 'Path to a file containing the Flutter VM service URI. '
          'The server watches this file and connects automatically.',
    );
}

void printUsage(ArgParser argParser) {
  stderr
    ..writeln('Marionette MCP Server - Flutter app interaction for AI agents')
    ..writeln()
    ..writeln('Usage: marionette_mcp [options]')
    ..writeln()
    ..writeln('Options:')
    ..writeln(argParser.usage);
}

Future<int> main(List<String> arguments) async {
  final argParser = buildParser();
  try {
    final results = argParser.parse(arguments);

    if (results.flag('help')) {
      printUsage(argParser);
      return 0;
    }
    if (results.flag('version')) {
      stderr.writeln('marionette_mcp version: $version');
      return 0;
    }

    final logLevel = (results.option('log-level') ?? 'INFO').toUpperCase();
    final logFile = results.option('log-file');
    final httpPortStr = results.option('http-port');
    final httpPort = httpPortStr != null ? int.tryParse(httpPortStr) : null;
    final vmServiceFile = results.option('vmservice-file');

    return await runMcpServer(
      logLevel: logLevel,
      logFile: logFile,
      httpPort: httpPort,
      vmServiceFile: vmServiceFile,
    );
  } on FormatException catch (e) {
    stderr
      ..writeln(e.message)
      ..writeln();
    printUsage(argParser);
    return 1;
  } on Exception catch (e) {
    stderr.writeln(e.toString());
    return 1;
  }
}
