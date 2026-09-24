/// Offline Quran broadcast recognition for Flutter applications.
///
/// Add a model asset to the host application, then call
/// [QuranBroadcastSdk.initialize]. The SDK owns the recognizer, microphone
/// session, local history, and translation engine until [QuranBroadcastSdk.dispose].
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'broadcast/application/broadcast_session_controller.dart';
import 'broadcast/broadcast_services.dart';
import 'broadcast/data/record_repository.dart';
import 'broadcast/domain/utterance_record.dart';
import 'broadcast/translation/offline_translation_engine.dart';
import 'broadcast/ui/broadcast_home_page.dart';

export 'broadcast/application/broadcast_session_controller.dart'
    show BroadcastPreview, BroadcastSessionStatus;
export 'broadcast/domain/utterance_record.dart'
    show TargetLanguage, UtteranceRecord, MatchStatus, TranslationSourceKind;
export 'broadcast/translation/offline_translation_engine.dart'
    show TranslationEngineStatus, TranslationException;

/// Thrown before opening the database when the host did not bundle its model.
class MissingModelAssetException implements Exception {
  const MissingModelAssetException(this.assetKey);

  /// Asset key requested by the caller.
  final String assetKey;

  @override
  String toString() =>
      'MissingModelAssetException: declare $assetKey under flutter/assets '
      'in the host pubspec.yaml and rebuild the app';
}

/// Owns one recognition session and its local resources.
///
/// Create one instance for an application. Call [dispose] when it is no longer
/// needed. A second live instance would compete for the microphone and the
/// fixed native ONNX channel.
class QuranBroadcastSdk {
  QuranBroadcastSdk._(this._services);

  static bool _initializing = false;
  static QuranBroadcastSdk? _activeInstance;
  final BroadcastServices _services;
  Future<void>? _disposeFuture;

  /// Creates the corpus, database, recognizer, and translation engine.
  ///
  /// [modelAssetKey] must be declared by the host application's `pubspec.yaml`.
  /// The default retains compatibility with this repository's demo app.
  static Future<QuranBroadcastSdk> initialize({
    String modelAssetKey = BroadcastServices.modelAssetKey,
  }) async {
    if (_initializing || _activeInstance != null) {
      throw StateError('QuranBroadcastSdk already has an active session');
    }
    _initializing = true;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      if (!manifest.listAssets().contains(modelAssetKey)) {
        throw MissingModelAssetException(modelAssetKey);
      }
      final services = await BroadcastServices.bootstrap(
        modelAssetKey: modelAssetKey,
      );
      return _activeInstance = QuranBroadcastSdk._(services);
    } finally {
      _initializing = false;
    }
  }

  /// The session is a [ChangeNotifier] with the live transcript and preview.
  /// Listen to it to render custom UI. Do not call `dispose` on this notifier;
  /// call [dispose] on the SDK instead.
  BroadcastSessionController get session => _services.session;

  /// Languages with a bundled, attributed QuranEnc translation edition.
  List<TargetLanguage> get availableLanguages =>
      List<TargetLanguage>.unmodifiable(_services.translationCatalog.languages);

  /// Starts microphone capture. Returns false when permission or capture fails;
  /// inspect [session.statusMessage] for the cause.
  Future<bool> start() => _services.session.start();

  /// Flushes the final utterance, then stops capture. Safe to call repeatedly.
  Future<void> stop() => _services.session.stop();

  /// Changes the target language while idle and persists the preference.
  /// Returns false if recognition is running.
  Future<bool> setTargetLanguage(TargetLanguage language) async {
    if (!_services.session.updateTargetLanguage(language)) return false;
    await _services.persistTargetLanguage(language);
    return true;
  }

  /// Returns the current status of the offline machine translation model.
  Future<TranslationEngineStatus> translationStatus() =>
      _services.engine.statusFor(_services.session.targetLanguage);

  /// Prepares a translation model only when the host explicitly permits a
  /// download. Bundled curated verse translations do not require this model.
  Future<TranslationEngineStatus> prepareTranslation({
    required bool allowDownload,
  }) => _services.engine.prepare(
    target: _services.session.targetLanguage,
    allowDownload: allowDownload,
  );

  /// Reads a page of locally stored utterances, newest first.
  Future<List<UtteranceRecord>> records({
    int limit = RecordRepository.defaultPageSize,
    int offset = 0,
  }) => _services.records.page(limit: limit, offset: offset);

  /// Ready-made three-column page with capture, translation, and history UI.
  Widget homePage({Key? key, WidgetBuilder? diagnosticPageBuilder}) =>
      BroadcastHomePage(
        key: key,
        services: _services,
        diagnosticPageBuilder: diagnosticPageBuilder,
      );

  /// Stops capture and releases the database, model, and translation engine.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    try {
      await _services.dispose();
    } finally {
      if (identical(_activeInstance, this)) _activeInstance = null;
    }
  }
}
