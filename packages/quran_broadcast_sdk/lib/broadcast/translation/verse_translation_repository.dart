/// 校订经文译本的查询接口。
///
/// 校订译本不是机器翻译引擎：它是按章、节查询的本地只读数据，一旦命中即为
/// [TranslationSourceKind.curatedEdition]，**不得**再经过机器翻译。
///
/// 当前项目**没有**已核实可分发的中英校订译本（译者/出版社许可未确认），
/// 因此默认实现 [NoCuratedEditionRepository] 恒定返回 null，全部走 ML Kit
/// 机器翻译路径。接口与来源标签保留，后续拿到授权数据即可直接接入，
/// 不需要改动上层逻辑，更不允许伪造译本或译本 ID。
library;

import '../domain/utterance_record.dart';

/// 一节（或节的一部分）的校订译本。
class VerseTranslation {
  /// 构造译本条目。
  ///
  /// @param editionId 译本标识（如 `ma-jian-zh`）
  /// @param translator 译者
  /// @param version 版本说明
  /// @param language 目标语言
  /// @param verseKey `surah:ayah`
  /// @param text 译文
  const VerseTranslation({
    required this.editionId,
    required this.translator,
    required this.version,
    required this.language,
    required this.verseKey,
    required this.text,
  });

  /// 译本标识。
  final String editionId;

  /// 译者。
  final String translator;

  /// 版本说明。
  final String version;

  /// 目标语言。
  final TargetLanguage language;

  /// `surah:ayah`。
  final String verseKey;

  /// 译文。
  final String text;

  /// 来源展示文案。
  String get label => '$translator（$editionId · $version）';
}

/// 校订译本仓储。
///
/// 语言可有可无：调用方先问 [editionIdFor]，返回 null 就说明该语言没有可用译本，
/// 应回退到机器翻译。
abstract interface class VerseTranslationRepository {
  /// 某语言使用的译本标识；该语言无译本时返回 null。
  ///
  /// @param language 目标语言
  /// @return 译本标识或 null
  String? editionIdFor(TargetLanguage language);

  /// 查询某节某语言的完整译本。
  ///
  /// @param verseKey `surah:ayah`
  /// @param language 目标语言
  /// @return 完整节译本；不存在时返回 null
  Future<VerseTranslation?> find({
    required String verseKey,
    required TargetLanguage language,
  });

  /// 列出某语言已覆盖的节键。
  ///
  /// @param language 目标语言
  /// @return 节键集合；无该语言译本或范围未知时返回 null
  Set<String>? availableVerseKeys(TargetLanguage language);
}

/// 没有可分发校订译本时的空实现。
///
/// 恒返回 null，让所有译文都走机器翻译并带 `machineCanonical` / `machineAsr`
/// 来源标记，不会出现「假装是校订译本」的情况。测试与无数据场景使用。
class NoCuratedEditionRepository implements VerseTranslationRepository {
  /// 构造空实现。
  const NoCuratedEditionRepository();

  @override
  String? editionIdFor(TargetLanguage language) => null;

  @override
  Future<VerseTranslation?> find({
    required String verseKey,
    required TargetLanguage language,
  }) async => null;

  @override
  Set<String>? availableVerseKeys(TargetLanguage language) => null;
}
