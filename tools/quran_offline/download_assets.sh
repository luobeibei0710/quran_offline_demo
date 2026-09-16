#!/usr/bin/env bash
# 下载古兰经离线识别所需的模型资产（Tilawa v0.2.0）。
#
# 资产来源：https://github.com/yazinsai/tilawa （MIT；模型 CC-BY-4.0，基座
# nvidia/stt_ar_fastconformer_hybrid_large_pcd_v1.0）
#
# 用法：
#   bash tools/quran_offline/download_assets.sh
#
# 说明：模型 88 MB + token 表 12 MB 体积较大，未纳入版本库，构建前需执行本脚本。

set -euo pipefail

BASE_URL="https://github.com/yazinsai/tilawa/releases/download/v0.2.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST_DIR="${REPO_ROOT}/assets/quran_offline"
EXPECTED_SHA256="4767182cd92975869f81a7e32700b14ca2b04e8dc97a15ff220a8697f4639488"

mkdir -p "${DEST_DIR}"

for file in fastconformer_full_mixed.onnx quran_ctc_tokens.json quran.json vocab.json export_metadata.json; do
  target="${DEST_DIR}/${file}"
  if [ -s "${target}" ]; then
    echo "已存在，跳过：${file}"
    continue
  fi
  echo "下载：${file}"
  curl -L --retry 3 --progress-bar -o "${target}" "${BASE_URL}/${file}"
done

echo "校验模型 sha256..."
if command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "${DEST_DIR}/fastconformer_full_mixed.onnx" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${DEST_DIR}/fastconformer_full_mixed.onnx" | awk '{print $1}')"
else
  echo "缺少 sha256 工具（需要 shasum 或 sha256sum）" >&2
  exit 1
fi
if [ "${actual}" != "${EXPECTED_SHA256}" ]; then
  echo "校验失败：期望 ${EXPECTED_SHA256}，实际 ${actual}" >&2
  exit 1
fi
echo "完成：资产已就绪于 ${DEST_DIR}"
