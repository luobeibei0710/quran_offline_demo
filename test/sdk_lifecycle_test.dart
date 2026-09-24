import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quran_broadcast_sdk/broadcast/broadcast_services.dart';
import 'package:quran_broadcast_sdk/broadcast/application/microphone_source.dart';
import 'package:quran_broadcast_sdk/broadcast/data/app_database.dart';
import 'package:quran_broadcast_sdk/broadcast/translation/mlkit_translation_engine.dart';
import 'package:quran_broadcast_sdk/quran_offline/ctc_scorer.dart';
import 'package:quran_broadcast_sdk/quran_offline/ort_runner.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FailingRunner implements OrtRunner {
  bool disposed = false;

  @override
  Future<void> loadModel(String modelPath) async {
    throw StateError('invalid model');
  }

  @override
  Future<AcousticEvidence> run(Float32List samples) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async => disposed = true;
}

class _RecordingRunner implements OrtRunner {
  bool disposed = false;

  @override
  Future<void> loadModel(String modelPath) async {}

  @override
  Future<AcousticEvidence> run(Float32List samples) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async => disposed = true;
}

class _FailingCloseEngine extends MlKitTranslationEngine {
  @override
  Future<void> close() async => throw StateError('engine close failed');
}

class _IdleAudio implements AudioCaptureSource {
  @override
  Future<bool> ensurePermission({bool request = true}) async => true;

  @override
  Future<Stream<Float32List>> start() async => const Stream.empty();

  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('模型加载失败时关闭已打开的数据库和推理桥', () async {
    final database = await BroadcastDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final runner = _FailingRunner();

    await expectLater(
      BroadcastServices.bootstrap(database: database, runner: runner),
      throwsStateError,
    );
    expect(database.db.isOpen, isFalse);
    expect(runner.disposed, isTrue);
  });

  test('平台模型加载失败后仍调用原生 dispose', () async {
    final calls = <String>[];
    const channel = MethodChannel(PlatformOrtRunner.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'loadModel') {
        throw PlatformException(code: 'invalid_model');
      }
      return null;
    });
    try {
      final runner = PlatformOrtRunner(blankId: 0);
      await expectLater(
        runner.loadModel('broken.onnx'),
        throwsA(isA<PlatformException>()),
      );
      await runner.dispose();
      expect(calls, <String>['loadModel', 'dispose']);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('前序资源关闭失败时仍释放推理桥和数据库', () async {
    final database = await BroadcastDatabase.open(
      path: inMemoryDatabasePath,
      factory: databaseFactoryFfi,
    );
    final runner = _RecordingRunner();
    final services = await BroadcastServices.bootstrap(
      loadModel: false,
      database: database,
      runner: runner,
      engine: _FailingCloseEngine(),
      audio: _IdleAudio(),
    );

    await expectLater(services.dispose(), throwsStateError);
    expect(runner.disposed, isTrue);
    expect(database.db.isOpen, isFalse);
  });
}
