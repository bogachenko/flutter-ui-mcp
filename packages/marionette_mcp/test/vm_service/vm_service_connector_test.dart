import 'dart:async';

import 'package:marionette_mcp/src/vm_service/vm_service_connector.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

class _FakeVmService extends VmService {
  _FakeVmService({
    required this.hasMarionetteExtension,
    this.serviceStreamHangs = false,
    this.serviceStreamError,
  }) : super(const Stream<String>.empty(), (_) {});

  final bool hasMarionetteExtension;
  final bool serviceStreamHangs;
  final Object? serviceStreamError;

  bool disposed = false;
  int serviceStreamListenCount = 0;
  final extensionCalls = <String>[];

  @override
  Future<VM> getVM() async {
    return VM(
      isolates: [
        IsolateRef(
          id: 'isolates/1',
          number: '1',
          name: 'main',
          isSystemIsolate: false,
          isolateGroupId: 'isolateGroups/1',
        ),
      ],
    );
  }

  @override
  Future<Isolate> getIsolate(String isolateId) async {
    return Isolate(
      id: isolateId,
      number: '1',
      name: 'main',
      isSystemIsolate: false,
      isolateGroupId: 'isolateGroups/1',
      extensionRPCs: hasMarionetteExtension
          ? const ['ext.flutter.marionette.getLogs']
          : const [],
    );
  }

  @override
  Future<Success> streamListen(String streamId) {
    serviceStreamListenCount++;
    if (serviceStreamError != null) {
      return Future<Success>.error(serviceStreamError!);
    }
    if (serviceStreamHangs) {
      return Completer<Success>().future;
    }
    return Future.value(Success());
  }

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    extensionCalls.add(method);
    return Response()..json = {'ok': true};
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  group('VmServiceConnector.connect', () {
    test(
      'connects when the Service event stream never completes',
      () async {
        final service = _FakeVmService(
          hasMarionetteExtension: true,
          serviceStreamHangs: true,
        );
        final connector = VmServiceConnector(
          vmServiceConnector: (_) async => service,
        );

        await connector
            .connect('ws://test.invalid/ws')
            .timeout(const Duration(seconds: 2));

        expect(connector.isConnected, isTrue);
        expect(service.serviceStreamListenCount, 1);
        expect(service.disposed, isFalse);

        expect(await connector.getInteractiveElements(), {'ok': true});
        expect(await connector.tap({'key': 'button'}), {'ok': true});
        expect(await connector.takeScreenshots(), {'ok': true});
        expect(await connector.getLogs(), {'ok': true});
        expect(
          service.extensionCalls,
          containsAll([
            'ext.flutter.marionette.interactiveElements',
            'ext.flutter.marionette.tap',
            'ext.flutter.marionette.takeScreenshots',
            'ext.flutter.marionette.getLogs',
          ]),
        );

        await connector.disconnect();
        expect(service.disposed, isTrue);
        expect(connector.isConnected, isFalse);
      },
    );

    test('Service event stream errors are non-fatal after isolate discovery',
        () async {
      final service = _FakeVmService(
        hasMarionetteExtension: true,
        serviceStreamError: StateError('Service stream unavailable'),
      );
      final connector = VmServiceConnector(
        vmServiceConnector: (_) async => service,
      );

      await connector.connect('ws://test.invalid/ws');

      expect(connector.isConnected, isTrue);
      expect(service.serviceStreamListenCount, 1);
      expect(service.disposed, isFalse);

      await connector.disconnect();
    });

    test('isolate discovery failure cleans up connection state', () async {
      final service = _FakeVmService(hasMarionetteExtension: false);
      final connector = VmServiceConnector(
        vmServiceConnector: (_) async => service,
      );

      await expectLater(
        connector.connect('ws://test.invalid/ws'),
        throwsA(
          isA<Exception>().having(
            (error) => error.toString(),
            'message',
            contains('No isolate found with ext.flutter.marionette.getLogs'),
          ),
        ),
      );

      expect(connector.isConnected, isFalse);
      expect(service.serviceStreamListenCount, 0);
      expect(service.disposed, isTrue);
      await expectLater(
        connector.getLogs(),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test('can reconnect after a failed partial connection', () async {
      final failedService = _FakeVmService(hasMarionetteExtension: false);
      final connectedService = _FakeVmService(hasMarionetteExtension: true);
      var connectionCount = 0;
      final connector = VmServiceConnector(
        vmServiceConnector: (_) async {
          connectionCount++;
          return connectionCount == 1 ? failedService : connectedService;
        },
      );

      await expectLater(
        connector.connect('ws://failed.invalid/ws'),
        throwsA(isA<Exception>()),
      );
      await connector.connect('ws://connected.invalid/ws');

      expect(failedService.disposed, isTrue);
      expect(connectedService.disposed, isFalse);
      expect(connector.isConnected, isTrue);

      await connector.disconnect();
    });

    test('a repeated connect disposes the previous VM service', () async {
      final firstService = _FakeVmService(hasMarionetteExtension: true);
      final secondService = _FakeVmService(hasMarionetteExtension: true);
      var connectionCount = 0;
      final connector = VmServiceConnector(
        vmServiceConnector: (_) async {
          connectionCount++;
          return connectionCount == 1 ? firstService : secondService;
        },
      );

      await connector.connect('ws://first.invalid/ws');
      await connector.connect('ws://second.invalid/ws');

      expect(connectionCount, 2);
      expect(firstService.disposed, isTrue);
      expect(secondService.disposed, isFalse);
      expect(connector.isConnected, isTrue);

      await connector.disconnect();
    });
  });

  group('VmServiceExtensionException.fromRpcError', () {
    test('preserves application-side extension details', () {
      final exception = VmServiceExtensionException.fromRpcError(
        'custom.failure',
        RPCError.withDetails(
          'ext.flutter.custom.failure',
          -32000,
          'Server error',
          details: 'callback failed\napplication stack',
        ),
      );

      expect(exception.message, 'Extension custom.failure failed');
      expect(exception.errorCode, -32000);
      expect(exception.error, contains('callback failed'));
      expect(exception.error, contains('application stack'));
    });

    test('falls back to the protocol message without details', () {
      final exception = VmServiceExtensionException.fromRpcError(
        'custom.failure',
        RPCError('ext.flutter.custom.failure', -32000, 'Server error'),
      );

      expect(exception.error, 'Server error');
    });

    test('stringifies structured application-side details', () {
      final exception = VmServiceExtensionException.fromRpcError(
        'custom.failure',
        RPCError.withDetails(
          'ext.flutter.custom.failure',
          -32000,
          'Server error',
          details: <String, Object?>{
            'reason': 'callback failed',
            'retryable': false,
          },
        ),
      );

      expect(exception.error, contains('callback failed'));
      expect(exception.error, contains('retryable: false'));
    });
  });

  group('VmServiceConnector.callCustomExtension', () {
    late VmServiceConnector connector;

    setUp(() {
      connector = VmServiceConnector();
    });

    test('throws ArgumentError when extension name is empty', () {
      expect(
        () => connector.callCustomExtension(''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'throws ArgumentError when extension name contains ext.flutter. prefix',
      () {
        expect(
          () => connector.callCustomExtension('ext.flutter.myExtension'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('must not include the "ext.flutter." prefix'),
            ),
          ),
        );
      },
    );

    test('throws NotConnectedException when not connected', () async {
      await expectLater(
        connector.callCustomExtension('myExtension'),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test('accepts valid extension name with default empty args', () async {
      // Should throw NotConnectedException (not ArgumentError),
      // meaning validation passed.
      await expectLater(
        connector.callCustomExtension('deckNavigation.goToSlide'),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test('accepts valid extension name with custom args', () async {
      await expectLater(
        connector.callCustomExtension('deckNavigation.goToSlide', {
          'slideNumber': '3',
        }),
        throwsA(isA<NotConnectedException>()),
      );
    });
  });

  group('VmServiceConnector.doubleTap', () {
    late VmServiceConnector connector;

    setUp(() {
      connector = VmServiceConnector();
    });

    test('throws NotConnectedException with default delay', () async {
      await expectLater(
        connector.doubleTap({'key': 'my_button'}),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test('throws NotConnectedException with custom delay', () async {
      await expectLater(
        connector.doubleTap({'key': 'my_button'}, delayMs: 200),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test('throws NotConnectedException with coordinate matcher', () async {
      await expectLater(
        connector.doubleTap({'x': 100, 'y': 200}),
        throwsA(isA<NotConnectedException>()),
      );
    });
  });

  group('VmServiceConnector.longPress', () {
    late VmServiceConnector connector;

    setUp(() {
      connector = VmServiceConnector();
    });

    test('throws NotConnectedException with default duration', () async {
      await expectLater(
        connector.longPress({'key': 'my_button'}),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test('throws NotConnectedException with custom duration', () async {
      await expectLater(
        connector.longPress({'key': 'my_button'}, durationMs: 300),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test('throws NotConnectedException with coordinate matcher', () async {
      await expectLater(
        connector.longPress({'x': 100, 'y': 200}),
        throwsA(isA<NotConnectedException>()),
      );
    });
  });

  group('VmServiceConnector.enterText', () {
    late VmServiceConnector connector;

    setUp(() {
      connector = VmServiceConnector();
    });

    test(
      'accepts focused matcher and falls through to connection validation',
      () async {
        await expectLater(
          connector.enterText({'focused': true}, 'Hello'),
          throwsA(isA<NotConnectedException>()),
        );
      },
    );
  });

  group('VmServiceConnector.pinchZoom', () {
    late VmServiceConnector connector;

    setUp(() {
      connector = VmServiceConnector();
    });

    test('throws NotConnectedException when not connected', () async {
      await expectLater(
        connector.pinchZoom({'key': 'map'}, scale: 2.0),
        throwsA(isA<NotConnectedException>()),
      );
    });

    test(
      'throws NotConnectedException with coordinates and custom distance',
      () async {
        await expectLater(
          connector.pinchZoom(
            {'x': 100, 'y': 200},
            scale: 0.5,
            startDistance: 300,
          ),
          throwsA(isA<NotConnectedException>()),
        );
      },
    );

    group('VmServiceConnector.pressBackButton', () {
      late VmServiceConnector connector;

      setUp(() {
        connector = VmServiceConnector();
      });

      test('throws NotConnectedException when not connected', () async {
        await expectLater(
          connector.pressBackButton(),
          throwsA(isA<NotConnectedException>()),
        );
      });
    });
  });
}
