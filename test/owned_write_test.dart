import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

const service = '0000180d-0000-1000-8000-00805f9b34fb';
const characteristic = '00002a39-0000-1000-8000-00805f9b34fb';

Future<bool> owned({bool Function()? current, bool withoutResponse = false}) =>
    UniversalBle.writeOwned(
      'synthetic',
      service,
      characteristic,
      Uint8List.fromList([1]),
      canDispatch: current ?? () => true,
      withoutResponse: withoutResponse,
    );

void main() {
  late _Platform platform;
  setUp(() {
    UniversalBle.clearQueue();
    UniversalBle.queueType = QueueType.global;
    UniversalBle.timeout = const Duration(seconds: 10);
    platform = _Platform();
    UniversalBle.setInstance(platform);
  });
  tearDown(() => UniversalBle.clearQueue());

  test('withdrawn owned command never invokes the platform', () async {
    expect(await owned(current: () => false), isFalse);
    expect(platform.calls, isEmpty);
  });

  test('dispatch guard is checked after a slow legacy predecessor', () async {
    var current = true;
    final predecessor = UniversalBle.write(
      'synthetic',
      service,
      characteristic,
      Uint8List(1),
    );
    final cancelled = owned(current: () => current);
    await pumpEventQueue();
    expect(platform.calls, hasLength(1));
    current = false;
    platform.calls.single.result.complete();
    await predecessor;
    expect(await cancelled, isFalse);
    expect(platform.calls, hasLength(1));
  });

  test(
    'owned write shares FIFO with legacy commands without dropping their order',
    () async {
      final first = owned();
      final command = UniversalBle.write(
        'synthetic',
        service,
        characteristic,
        Uint8List.fromList([2]),
      );
      await pumpEventQueue();
      expect(platform.calls, hasLength(1));
      platform.calls[0].result.complete();
      expect(await first, isTrue);
      await pumpEventQueue();
      expect(platform.calls, hasLength(2));
      expect(platform.calls[1].value, [2]);
      platform.calls[1].result.complete();
      await command;
    },
  );

  test('owned timeout is not inherited from global command timeout', () {
    fakeAsync((time) {
      UniversalBle.timeout = const Duration(seconds: 1);
      bool? firstResult, secondResult;
      owned().then((v) => firstResult = v);
      owned().then((v) => secondResult = v);
      time.flushMicrotasks();
      expect(platform.calls, hasLength(1));
      time.elapse(const Duration(seconds: 11));
      expect(firstResult, isNull);
      expect(secondResult, isNull);
      expect(platform.calls, hasLength(1));
      platform.calls[0].result.complete();
      time.flushMicrotasks();
      expect(firstResult, isTrue);
      expect(platform.calls, hasLength(2));
      platform.calls[1].result.complete();
      time.flushMicrotasks();
      expect(secondResult, isTrue);
    });
  });

  test(
    'platform failure propagates once and the following command keeps its turn',
    () async {
      final first = owned();
      final expectedError = expectLater(first, throwsStateError);
      final next = owned();
      await pumpEventQueue();
      platform.calls[0].result.completeError(StateError('synthetic failure'));
      await expectedError;
      await pumpEventQueue();
      expect(platform.calls, hasLength(2));
      platform.calls[1].result.complete();
      expect(await next, isTrue);
    },
  );

  test(
    'guard exception occurs before native dispatch and does not poison FIFO',
    () async {
      await expectLater(
        owned(current: () => throw StateError('synthetic guard')),
        throwsStateError,
      );
      expect(platform.calls, isEmpty);
      final next = owned();
      await pumpEventQueue();
      platform.calls.single.result.complete();
      expect(await next, isTrue);
    },
  );

  for (final withoutResponse in [false, true]) {
    test(
      'preserves ${withoutResponse ? 'withoutResponse' : 'withResponse'} mode and platform completion boundary',
      () async {
        var completed = false;
        final result = owned(withoutResponse: withoutResponse).then((v) {
          completed = true;
          return v;
        });
        await pumpEventQueue();
        expect(completed, isFalse);
        expect(
          platform.calls.single.mode,
          withoutResponse
              ? BleOutputProperty.withoutResponse
              : BleOutputProperty.withResponse,
        );
        platform.calls.single.result.complete();
        expect(await result, isTrue);
      },
    );
  }

  test('legacy write still uses its configured timeout', () {
    fakeAsync((time) {
      var timedOut = false;
      UniversalBle.write(
        'synthetic',
        service,
        characteristic,
        Uint8List(1),
        timeout: const Duration(seconds: 1),
      ).catchError((Object error) {
        timedOut = error is TimeoutException;
      });
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 1));
      expect(timedOut, isTrue);
      platform.calls.single.result.complete();
      time.flushMicrotasks();
    });
  });
}

class _Call {
  _Call(this.mode, Uint8List value) : value = Uint8List.fromList(value);
  final BleOutputProperty mode;
  final Uint8List value;
  final result = Completer<void>();
}

class _Platform extends UniversalBlePlatform {
  final calls = <_Call>[];
  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) {
    final call = _Call(bleOutputProperty, value);
    calls.add(call);
    return call.result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
