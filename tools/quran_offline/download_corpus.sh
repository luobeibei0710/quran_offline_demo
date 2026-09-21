#!/usr/bin/env bash
# 下载「多节连续诵读」语料，拼接成 16 kHz / 单声道 / 16-bit PCM 的 WAV。
#
# 音源：Quran.com 的逐节 MP3 CDN（https://verses.quran.com/<Reciter>/mp3/SSSAAA.mp3）。
# 产物放到 assets/quran_offline/corpus/，文件名即「章_起始节_结束节」——
# 应用侧由此推出展示名（章名 + 节区间）与原文（经文库标准经文），因此文件本身
# 不必入库（体积与许可原因，与模型一样排除在版本库外）。
#
# 用法：
#   bash tools/quran_offline/download_corpus.sh                 # 默认 3 段
#   RECITER=Abdul_Basit_Murattal RANGES="002 255 257" bash ...  # 换诵读人/区间
set -euo pipefail

RECITER="${RECITER:-Alafasy}"
# 参考标注与预测隔离。换音源时按实际音频设置 true/false，不按跑分择优。
INCLUDES_BISMILLAH="${INCLUDES_BISMILLAH:-false}"
case "$INCLUDES_BISMILLAH" in true|false) ;; *) echo 'INCLUDES_BISMILLAH must be true or false' >&2; exit 2;; esac
BASE_URL="${BASE_URL:-https://verses.quran.com}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="${REPO_ROOT}/assets/quran_offline/corpus"

# 默认三段：短节连读（36:1-5）、中长（55:1-13）、中长（67:1-11）
if [ -n "${RANGES:-}" ]; then
  # 多段用分号或换行分隔，例如 RANGES="002 255 257;055 1 13"
  IFS=';' read -r -a RANGE_LIST <<<"${RANGES//$'\n'/;}"
else
  RANGE_LIST=("036 001 005" "055 001 013" "067 001 011")
fi

mkdir -p "${DEST}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
MANIFEST_ENTRIES=()

for range in "${RANGE_LIST[@]}"; do
  read -r surah ayah_start ayah_end <<<"${range}"
  surah_num=$((10#${surah}))
  list=""
  for (( ayah = 10#${ayah_start}; ayah <= 10#${ayah_end}; ayah++ )); do
    key=$(printf '%03d%03d' "${surah_num}" "${ayah}")
    target="${TMP_DIR}/${key}.mp3"
    echo "下载：${key}.mp3"
    curl -fsSL --retry 3 -o "${target}" "${BASE_URL}/${RECITER}/mp3/${key}.mp3"
    list="${list}|${target}"
  done

  out="${DEST}/corpus_$(printf '%03d' "${surah_num}")_${ayah_start}_${ayah_end}.wav"
  ffmpeg -y -loglevel error -i "concat:${list#|}" -ar 16000 -ac 1 -c:a pcm_s16le "${out}"
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${out}")
  echo "生成：$(basename "${out}")（${duration}s，$(du -h "${out}" | cut -f1)）"

  MANIFEST_ENTRIES+=("{\"file\":\"$(basename "${out}")\",\"surah\":${surah_num},\"ayahStart\":$((10#${ayah_start})),\"ayahEnd\":$((10#${ayah_end})),\"includesBismillah\":${INCLUDES_BISMILLAH}}")
done

# 清单：应用启动时读取它来列出语料（音频本身不入版本库）
manifest="${DEST}/manifest.json"
printf '[\n  %s\n]\n' "$(IFS=$',\n  '; echo "${MANIFEST_ENTRIES[*]}")" >"${manifest}"
echo "生成：manifest.json（${#MANIFEST_ENTRIES[@]} 条）"
echo "完成：语料已就绪于 ${DEST}"
