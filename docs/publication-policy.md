# 公开仓库内容边界

本仓库的 GitHub 远端是公开仓库。提交前逐项检查文件内容和来源；`.gitignore` 只阻止尚未被跟踪的文件进入索引，不会清除已经公开的历史。

| 内容 | 公开处理 | 原因或条件 |
| --- | --- | --- |
| Flutter SDK、Android/iOS 插件源码、示例应用、测试、构建与资源生成脚本 | 提交 | 其他 Flutter 工程需要这些文件集成和复现构建；不得包含本机地址、凭据或个人标识。 |
| 经文原文、token 表、62 种译本、词表 | 提交 | SDK 的运行时数据；保留 `NOTICE.txt`、`manifest.json` 和译本 `index.json` 中的来源、版本、出版方及许可字段。更新资源时重新核对上游条款，不能修改要求逐字保留的正文。 |
| 已脱敏的技术文档与汇总指标 JSON/CSV | 提交 | 说明实现和验收口径；只保留必要设备型号、系统版本、统计值及可核验的素材摘要。 |
| ONNX 等模型权重、整章诵读音频、麦克风 PCM/WAV、数据库 | 不提交 | 体积大，可能涉及独立授权或个人录音；由集成方按 SDK 文档在本地获取和配置。 |
| 原始 ADB/Xcode/应用日志、逐事件转写、崩溃转储 | 不提交 | 可能含设备地址、标识符、绝对路径和实际收音文本；仅在本地保留，公开脱敏摘要。 |
| 签名证书、描述文件、私钥、`.env`、服务配置与本机构建产物 | 不提交 | 凭据和设备/环境专属文件不能发布。`*.example` 或 `.env.sample` 只能放占位符。 |

## 发布前检查

在仓库根目录执行：

```bash
git status --short
git ls-files docs/evidence
git check-ignore -v docs/evidence/live-three-column-android-2026-09-23.txt
git diff --check
```

检查所有即将加入索引的新增文件，并对 `git diff --cached` 再做凭据、私有地址、设备 ID、绝对路径和音频转写抽查。`git add -f` 会绕过忽略规则，不应用于上述本地文件。若意外将凭据提交到已公开历史，先撤销并轮换凭据；仅添加 `.gitignore` 不会使历史内容消失。

## 上游资源

- Tanzil 原文：<https://tanzil.net/docs/Text_License>；本仓库保留其原文版权声明和来源链接。
- QuranEnc 译本：<https://quranenc.com/en/home/api>；每种译本的出版方、版本、来源和授权字段见 `packages/quran_broadcast_sdk/assets/broadcast_quran/full/translations/index.json`。

公开代码的许可见仓库根目录 `LICENSE`。第三方数据与模型依各自条款处理，不能因为代码许可而推定可自由改写或再分发。
