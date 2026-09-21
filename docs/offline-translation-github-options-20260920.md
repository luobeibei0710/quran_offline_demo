# Quran 离线翻译 GitHub 调研（历史归档）

> **最新决策：机器翻译使用ML Kit。本文候选研究不再是实施任务。** 新功能采用独立下载的三章新库，旧功能和旧库保留。以[当前实施方案](broadcast-transcription-translation-plan-20260920.md)和[三章资源清单](new-corpus-fatiha-ikhlas-20260920.md)为准。

核验日期：2026-09-20。范围：阿拉伯语→简体中文/英语，Flutter Android+iOS，全程端侧推理。本轮核验官方仓库、模型卡、许可证及部分实现；没有下载大模型、构建候选引擎或执行翻译真机测试。全文的推荐是待验证选型，不是性能验收结论。

## 历史候选证据

用户已确定ML Kit，不再执行Hy-MT2或其他引擎POC。以下仅保留之前查到的项目能力和限制，表中的候选定位均为当时研究结论。

| GitHub 项目 | 可利用能力 | 本项目定位 | 主要限制 |
|---|---|---|---|
| [Tencent-Hunyuan/Hy-MT2](https://github.com/Tencent-Hunyuan/Hy-MT2) | 专用多语言翻译模型，含阿/中/英，官方 GGUF | **优先质量候选** | 1.8B Q4约1.13GB；未验证本项目手机速度和译文质量 |
| [leehack/llamadart](https://github.com/leehack/llamadart) | Flutter/Dart 的 llama.cpp 本地推理绑定 | **优先双端适配探针** | 是运行时，不是翻译模型；当前文档iOS≥16.4，需验证模型兼容和原生依赖 |
| [niedev/RTranslator](https://github.com/niedev/RTranslator/tree/v3.00) | 实际 Android 离线翻译应用，Bergamot 路径 | **轻量自持模型的 Android 参考** | Android-only；阿→中仍经英语；模型包许可需逐项核验 |
| [OpenNMT/CTranslate2](https://github.com/OpenNMT/CTranslate2) | 高效 NMT 推理、Marian/OPUS转换、量化 | 长期自建引擎候选 | 没有可直接承诺的官方 Flutter 双端 SDK，需原生构建和 tokenizer 接入 |
| [HoSStiA/mnn-opus-mt-toolkit](https://github.com/HoSStiA/mnn-opus-mt-toolkit) | OPUS→ONNX→MNN，Android C++测试链路 | 源码参考 | 无发布版，tokenizer需重点核验，无阿语质量验收，不宜直接当产品依赖 |
| [netdur/llama_cpp_dart](https://github.com/netdur/llama_cpp_dart) | 另一套 Flutter 原生 llama.cpp 封装 | 绑定备选 | 当前main为0.9.0-dev.12，要求Flutter≥3.44，高于本项目3.41.8 |

## 1. Hy-MT2：值得优先实测，但不能先宣称优于 ML Kit

[官方 README](https://github.com/Tencent-Hunyuan/Hy-MT2/blob/main/README.md)列出33种语言，包含 Arabic、Chinese、English，并提供面向翻译的提示格式。[1.8B官方模型卡](https://huggingface.co/tencent/Hy-MT2-1.8B)与[官方GGUF列表](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/tree/main)可用于版本锁定。常规Q4_K_M文件约1.13GB；这是磁盘文件大小，**不是运行峰值内存**，还需叠加KV cache、计算缓冲及现有ASR模型。

仓库[LICENSE.txt](https://github.com/Tencent-Hunyuan/Hy-MT2/blob/main/LICENSE.txt)及[GGUF权重许可证](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/blob/main/LICENSE.txt)均为Apache-2.0。实施时固化具体revision、SHA256、LICENSE/NOTICE，不把这一结论外推到旧Hy-MT版本或任意第三方量化权重。

相较ML Kit值得验证的价值：可自持与预置模型；模型支持目标语言直接翻译，不受ML Kit明确的非英语经英语中转设计约束；翻译模板可固定。但这些特性不等于已证明阿语古兰经质量更好。厂商通用评测也不能替代本项目带ASR错误的广播语料。

官方另有[约440MB的1.25bit版本](https://huggingface.co/tencent/Hy-MT2-1.8B-1.25Bit-GGUF)，涉及[STQ内核实现](https://github.com/ggml-org/llama.cpp/pull/22836)。选用前须核验该能力是否进入所固定的llama.cpp版本、CPU/Metal后端是否支持及Flutter原生包是否包含相应内核。本轮未确认这些条件，也未将桌面M4 Pro数据当作手机性能。首轮采用常规Q4，避免同时引入新模型、新绑定、新量化内核三个变量。

## 2. Flutter 双端运行时选择

优先试[llamadart README](https://github.com/leehack/llamadart/blob/main/README.md)。当前文档要求Flutter≥3.38、iOS≥16.4；[pubspec](https://github.com/leehack/llamadart/blob/main/pubspec.yaml)当前main为0.8.23，Dart要求^3.10.7；[源码许可](https://github.com/leehack/llamadart/blob/main/LICENSE)为MIT。本项目Flutter3.41.8/Dart3.11.5在声明范围内，但当前iOS target15.1需提升，且必须实测既有ORT/CocoaPods与Apple原生资产接入的兼容性。仓库main不能自动视为pub.dev已发布可用版本。

适配器只负责模型生命周期、模板、推理和取消，不修改ASR。必须逐项验证Hy-MT2架构、tokenizer、聊天模板、量化格式及结束token；“支持GGUF”不能替代具体模型加载测试。推理放到后台执行，翻译与ASR争用CPU/GPU时测延迟和热降频。

[llama_cpp_dart的pubspec](https://github.com/netdur/llama_cpp_dart/blob/main/pubspec.yaml)当前要求Flutter≥3.44，不能在本工程直接按main接入。若改用它，应选经验证的兼容发布版或单独评估SDK升级，禁止为了试翻译顺手破坏已通过的ASR基线。其[MIT许可证](https://github.com/netdur/llama_cpp_dart/blob/main/LICENSE)不覆盖任意模型许可证。

## 3. RTranslator / Bergamot：更轻的 Android 参考路线

[v3 README](https://github.com/niedev/RTranslator/blob/v3.00/README.md)提供真实离线翻译应用，首次下载资源后运行，支持阿/中/英；该分支仍标为beta。[构建配置](https://github.com/niedev/RTranslator/blob/v3.00/app/build.gradle)为minSdk28、arm64-v8a、Java/JNI，因此复用其完整应用会提高本项目Android最低版本，提取单独引擎的最低版本则需重新核验；它没有证明Flutter/iOS可直接运行。

[BergamotTranslator.cpp](https://github.com/niedev/RTranslator/blob/v3.00/app/src/main/cpp/src/bergamot_translator/BergamotTranslator.cpp)对非英语间翻译调用pivotMultiple：ar→zh经ar→en→zh，不能宣传为避免英语中转。[语言资源表](https://github.com/niedev/RTranslator/blob/v3.00/app/src/main/res/raw/mozilla_supported_languages.xml)与[模型发布页](https://github.com/niedev/OnnxModelsEnhancer/releases/tag/v1.0.0-beta)对应阿语zip约50.8MB、中文zip约86.7MB，合计约137.5MB；这是压缩下载量，不是完整App大小或运行内存。README的6GB RAM建议针对整个应用，不可当作纯翻译引擎内存实测。

许可分层：[App Apache-2.0](https://github.com/niedev/RTranslator/blob/v3.00/LICENSE.txt)、[Bergamot fork MPL-2.0](https://github.com/niedev/bergamot-translator/blob/main/LICENSE)、每个模型自己的条款。发布页的“复制自Mozilla模型库”说明不足以替代zip内LICENSE/NOTICE核验。本轮未下载解包，正式预装分发前补齐。

结论：若Hy-MT2在Redmi上占用过高，优先验证该路径的Android单翻译模块。要满足当前双端目标，仍需独立补iOS构建、模型加载和Flutter接口，不能只复制Android页面便算完成。

## 4. OPUS / CTranslate2 / MNN

[CTranslate2](https://github.com/OpenNMT/CTranslate2)为MIT推理引擎，有[Marian转换](https://opennmt.net/CTranslate2/conversion.html)及[量化支持](https://opennmt.net/CTranslate2/quantization.html)。官方桌面工具成熟不等于官方Flutter移动SDK就绪。自行集成需覆盖SentencePiece、beam search、特殊token、量化算子、双端native构建和模型授权。

[MNN OPUS toolkit README](https://github.com/HoSStiA/mnn-opus-mt-toolkit/blob/main/README.md)展示Android原生测试流程；[构建脚本](https://github.com/HoSStiA/mnn-opus-mt-toolkit/blob/main/prepare_mnn.sh)固定MNN3.6.0、arm64、API24。当前是测试二进制方案，没有现成Flutter/iOS SDK或稳定release。[tokenizer实现](https://github.com/HoSStiA/mnn-opus-mt-toolkit/blob/main/transformer.cpp)的贪心子串路径不能直接视作完整SentencePiece等价实现，须先对照官方tokenizer测阿语与带音标输入。没有该验收就不能比较翻译质量。

可研究[Helsinki-NLP/opus-mt-ar-en](https://huggingface.co/Helsinki-NLP/opus-mt-ar-en)和[opus-mt-en-zh](https://huggingface.co/Helsinki-NLP/opus-mt-en-zh)两段模型，两个官方卡标注Apache-2.0。工具README对模型许可的泛称不应覆盖具体模型卡；锁定revision并检查随附许可。这仍是英语中转方案，没有证据表明比ML Kit更准确。

不优先采用[NLLB-200-distilled-600M](https://huggingface.co/facebook/nllb-200-distilled-600M)：官方为CC-BY-NC-4.0，并说明研究用途而非生产发布。不能因使用MIT/Apache推理引擎而把模型权重当成可商用。 [ExecuTorch encoder-decoder文档](https://github.com/pytorch/executorch/blob/main/docs/source/llm/export-custom-llm.md)要求自建runner等适配，当前也不是阿语翻译的即插即用替代品。

## 5. 对 ML Kit 的公平定位

[官方概览](https://developers.google.com/ml-kit/language/translation)明确端侧运行、非英语之间经英语中转，定位普通翻译；应分别评测ar→en和ar→zh。[安装矩阵](https://developers.google.com/ml-kit/tips/installation-paths)对Translation只列动态下载，因此与自持GGUF的首次离线预装能力不同。[Flutter社区桥](https://pub.dev/packages/google_mlkit_translation)不是Google官方Flutter SDK，其iOS最低要求15.5与当前llamadart的16.4也不同。

ML Kit仍值得做同语料基线：集成成本较低、模型更轻，但初次下载在目标网络/设备是否可用须单独测试。没有实测时，不能先把它淘汰，也不能称其最佳。输入端侧处理与SDK完全不发生网络通信是不同承诺，严格离线验收以资源就绪后的飞行模式运行证明。

## 6. 当前实施入口

此前多引擎POC及Hy-MT2优先路线已取消。CodeBuddy仅实施ML Kit，按[最新计划](broadcast-transcription-translation-plan-20260920.md)验证模型准备、双端离线推理、ar→zh/en质量与ASR共存；新库来源见[三章清单](new-corpus-fatiha-ikhlas-20260920.md)。本研究没有提供任何候选已在项目真机优于ML Kit的证据。
