#!/usr/bin/env python3
"""统计既有真机日志里预览候选与终稿的关系。

背景（见 docs/live-three-column-sync.md 与 evidence/live-three-column-android-2026-09-23.md）：
短窗口预览会给出跨章候选（尤其开头的太斯米与多章共享短语），而「同一节引用连续
两轮」只能说明候选稳定，不能保证候选正确。真正要回答的是：

1. 预览候选与同一片段的**终稿**经文范围有多少重叠；
2. 有多少预览候选落在**其它章**（跨章误提示），其中又有多少是「连续两轮相同」的
   稳定候选 —— 稳定却错误的候选会把错误章节的译文显示出来；
3. 候选**抖动**有多频繁（同一片段内候选切换次数）。

用法：
```bash
python3 tool/analyze_preview_evidence.py \
  --log docs/evidence/live-three-column-android-2026-09-23.txt \
  --expected-chapter 12 \
  --json-out docs/evidence/preview-candidate-stats-2026-09-23.json
```

脚本只读日志文本，不改代码也不参与匹配决策。
"""

from __future__ import annotations

import argparse
import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

# 终稿记录：记录 #N 已保存（<范围>，<状态>/<范围类型>，...）
RECORD_RE = re.compile(r"\[Broadcast\] 记录 #(\d+) 已保存（(.+?)）\s*$")
# 预览：预览 #N 窗口 Xs：状态 候选=... 覆盖=... 置信=... 匹配 Xms，整轮 Yms
PREVIEW_RE = re.compile(
    r"\[Broadcast\] 预览 #(\d+) 窗口 ([\d.]+)s：(\w+) 候选=(\S+) "
    r"覆盖=(\S+) 置信=(\S+) 匹配 (\d+)ms，整轮 (\d+)ms"
)
PREVIEW_FRAME_RE = re.compile(
    r"\[BroadcastLatency\] preview_frame revision=(\d+) audio_end=(\d+) "
    r"audio_to_frame_ms=(\d+)"
)
TRANSLATION_FRAME_RE = re.compile(
    r"\[BroadcastLatency\] translation_frame revision=(\d+) "
    r"candidate_generation=(\d+) stable_to_frame_ms=(\d+)"
)

EN_DASH = "\u2013"


@dataclass
class Ref:
    """一个经文范围引用。"""

    chapter: int
    start: int
    end: int

    def ayahs(self) -> set[tuple[int, int]]:
        return {(self.chapter, a) for a in range(self.start, self.end + 1)}

    def __str__(self) -> str:
        if self.start == self.end:
            return f"{self.chapter}:{self.start}"
        return f"{self.chapter}:{self.start}-{self.end}"


@dataclass
class Preview:
    revision: int
    window_seconds: float
    status: str
    ref_raw: str
    coverage: str
    confidence: str
    match_ms: int
    total_ms: int
    index: int

    @property
    def ref(self) -> Ref | None:
        return parse_ref(self.ref_raw)


@dataclass
class Utterance:
    """一个终稿片段及其间的全部预览。"""

    sequence: int | None = None
    summary: str = ""
    status_scope: str = ""
    previews: list[Preview] = field(default_factory=list)

    @property
    def final_ref(self) -> Ref | None:
        return parse_final_summary(self.summary)


def parse_ref(text: str) -> Ref | None:
    """解析 `12:8-9` / `12:8` 形式的引用；`-` 表示无候选。"""
    if not text or text == "-":
        return None
    text = text.replace(EN_DASH, "-").strip()
    match = re.fullmatch(r"(\d+):(\d+)(?:-(\d+))?", text)
    if match is None:
        return None
    chapter = int(match.group(1))
    start = int(match.group(2))
    end = int(match.group(3)) if match.group(3) else start
    return Ref(chapter, start, min(end, start) if end < start else end)


def parse_final_summary(summary: str) -> Ref | None:
    """解析终稿summary，如 `12:6–7`、`部分 12:9–10`、`未匹配`。"""
    cleaned = summary.replace("部分 ", "").strip()
    if cleaned.startswith("未匹配"):
        return None
    # 终稿摘要可能带节内词范围（`12:1 词 1–9`）： chapters/ayah 才是经文位置，
    # 词范围只说明这一片段覆盖该节的哪些词，参与判定时忽略。
    cleaned = cleaned.split(" 词 ")[0].strip()
    return parse_ref(cleaned)


def parse_log(path: Path) -> tuple[list[Utterance], list[Preview], dict[str, list[int]]]:
    """按终稿记录把预览划分到所属片段。"""
    utterances: list[Utterance] = []
    current = Utterance()
    all_previews: list[Preview] = []
    frames = {"preview": [], "translation": []}

    for raw in path.read_text(encoding="utf-8").splitlines():
        record = RECORD_RE.search(raw)
        if record is not None:
            current.sequence = int(record.group(1))
            parts = [part.strip() for part in record.group(2).split("，")]
            current.summary = parts[0] if parts else ""
            current.status_scope = parts[1] if len(parts) > 1 else ""
            utterances.append(current)
            current = Utterance()
            continue

        preview = PREVIEW_RE.search(raw)
        if preview is not None:
            item = Preview(
                revision=int(preview.group(1)),
                window_seconds=float(preview.group(2)),
                status=preview.group(3),
                ref_raw=preview.group(4),
                coverage=preview.group(5),
                confidence=preview.group(6),
                match_ms=int(preview.group(7)),
                total_ms=int(preview.group(8)),
                index=len(all_previews),
            )
            all_previews.append(item)
            current.previews.append(item)
            continue

        frame = PREVIEW_FRAME_RE.search(raw)
        if frame is not None:
            frames["preview"].append(int(frame.group(3)))
            continue
        frame = TRANSLATION_FRAME_RE.search(raw)
        if frame is not None:
            frames["translation"].append(int(frame.group(3)))

    if current.previews:
        utterances.append(current)
    return utterances, all_previews, frames


def percentile(values: Iterable[int], fraction: float) -> int | None:
    """最近秩百分位（与既有证据文档口径一致：排序后第 ceil(p×n) 项）。"""
    ordered = sorted(values)
    if not ordered:
        return None
    rank = max(1, math.ceil(fraction * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def stable_runs(previews: list[Preview]) -> list[tuple[str, int]]:
    """把连续相同的候选引用压成 (ref, 轮数)。"""
    runs: list[tuple[str, int]] = []
    for preview in previews:
        key = preview.ref_raw
        if runs and runs[-1][0] == key:
            runs[-1] = (key, runs[-1][1] + 1)
        else:
            runs.append((key, 1))
    return runs


def analyse(
    utterances: list[Utterance],
    previews: list[Preview],
    frames: dict[str, list[int]],
    expected_chapter: int,
) -> dict[str, object]:
    total_previews = len(previews)
    with_ref = [p for p in previews if p.ref is not None]
    cross_chapter = [p for p in with_ref if p.ref.chapter != expected_chapter]

    # 稳定但跨章：连续两轮以上相同引用的相邻预览对。
    stable_wrong_pairs = 0
    for index in range(1, len(previews)):
        prev, cur = previews[index - 1], previews[index]
        if cur.ref is None or prev.ref is None:
            continue
        if prev.ref_raw != cur.ref_raw:
            continue
        if cur.ref.chapter != expected_chapter:
            stable_wrong_pairs += 1

    per_utterance = []
    for utterance in utterances:
        final = utterance.final_ref
        final_ayahs = final.ayahs() if final else set()
        candidates = [p for p in utterance.previews if p.ref is not None]
        last_ref = utterance.previews[-1].ref if utterance.previews else None
        last_ref_raw = utterance.previews[-1].ref_raw if utterance.previews else None
        overlapping = [
            p for p in candidates if final_ayahs & p.ref.ayahs()  # type: ignore[union-attr]
        ] if final else []
        distinct = {p.ref_raw for p in utterance.previews}
        per_utterance.append(
            {
                "record": utterance.sequence,
                "summary": utterance.summary,
                "statusScope": utterance.status_scope,
                "finalRef": str(final) if final else None,
                "previewCount": len(utterance.previews),
                "candidateCount": len(candidates),
                "distinctCandidates": len(distinct),
                "lastPreviewRef": last_ref_raw,
                "lastPreviewOverlapsFinal": bool(
                    last_ref and final and bool(last_ref.ayahs() & final_ayahs)
                ),
                "previewsOverlappingFinal": len(overlapping),
                "overlapRate": (len(overlapping) / len(candidates)) if candidates else None,
                "crossChapterPreviews": sum(
                    1 for p in candidates if p.ref and p.ref.chapter != expected_chapter
                ),
                "crossChapterRate": (
                    sum(1 for p in candidates if p.ref and p.ref.chapter != expected_chapter)
                    / len(candidates)
                )
                if candidates
                else None,
            }
        )

    scored = [row for row in per_utterance if row["finalRef"]]
    mean_overlap = (
        sum(row["overlapRate"] for row in scored if row["overlapRate"] is not None)
        / len([r for r in scored if r["overlapRate"] is not None])
        if scored
        else None
    )
    last_overlap_hits = sum(1 for row in scored if row["lastPreviewOverlapsFinal"])

    return {
        "expectedChapter": expected_chapter,
        "utterances": len(per_utterance),
        "totalPreviews": total_previews,
        "previewsWithCandidate": len(with_ref),
        "crossChapterCandidatePreviews": len(cross_chapter),
        "crossChapterRate": (len(cross_chapter) / len(with_ref)) if with_ref else None,
        "stableConsecutiveCrossChapterPairs": stable_wrong_pairs,
        "stablePairRate": (stable_wrong_pairs / max(1, total_previews - 1)),
        "scoredUtterances": len(scored),
        "lastPreviewOverlapsFinal": last_overlap_hits,
        "lastPreviewOverlapRate": (last_overlap_hits / len(scored)) if scored else None,
        "meanPreviewOverlapRate": mean_overlap,
        "latency": {
            "previewFrame": {
                "n": len(frames["preview"]),
                "p50": percentile(frames["preview"], 0.50),
                "p95": percentile(frames["preview"], 0.95),
                "max": max(frames["preview"]) if frames["preview"] else None,
            },
            "translationFrame": {
                "n": len(frames["translation"]),
                "p50": percentile(frames["translation"], 0.50),
                "p95": percentile(frames["translation"], 0.95),
                "max": max(frames["translation"]) if frames["translation"] else None,
            },
        },
        "perUtterance": per_utterance,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--expected-chapter", type=int, default=12)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--md-out", type=Path)
    args = parser.parse_args()

    utterances, previews, frames = parse_log(args.log)
    report = analyse(utterances, previews, frames, args.expected_chapter)

    print("=== 预览候选与终稿对照 ===")
    print(f"片段数 {report['utterances']}，预览 {report['totalPreviews']} 次")
    print(
        f"有候选的预览 {report['previewsWithCandidate']} 次，"
        f"跨章候选 {report['crossChapterCandidatePreviews']} 次"
        f"（{report['crossChapterRate']:.1%}）"
    )
    print(
        f"连续两轮相同的跨章候选 {report['stableConsecutiveCrossChapterPairs']} 对"
        f"（占相邻预览对 {report['stablePairRate']:.1%}）"
    )
    print(
        f"有终稿范围的片段 {report['scoredUtterances']} 个，"
        f"末次预览与终稿重叠 {report['lastPreviewOverlapsFinal']} 个"
        f"（{report['lastPreviewOverlapRate']:.1%}），"
        f"片段内平均重叠率 {report['meanPreviewOverlapRate']:.1%}"
    )
    latency = report["latency"]  # type: ignore[index]
    print(
        "audio→UI帧 P50/P95 = "
        f"{latency['previewFrame']['p50']}/{latency['previewFrame']['p95']} ms"
        f"（n={latency['previewFrame']['n']}）"
    )
    print("\n=== 逐片段 ===")
    for row in report["perUtterance"]:  # type: ignore[index]
        print(
            f"记录 #{row['record']} {row['summary']} "
            f"[{row['statusScope']}] 终稿={row['finalRef']} "
            f"预览={row['previewCount']} 候选={row['candidateCount']} "
            f"不同候选={row['distinctCandidates']} "
            f"末次={row['lastPreviewRef']} "
            f"与终稿重叠={row['lastPreviewOverlapsFinal']} "
            f"片段内重叠率={row['overlapRate']}"
        )

    if args.json_out:
        args.json_out.write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"\nJSON 明细已写入 {args.json_out}")
    if args.md_out:
        args.md_out.write_text(render_markdown(report), encoding="utf-8")
        print(f"Markdown 已写入 {args.md_out}")


def render_markdown(report: dict[str, object]) -> str:
    per = report["perUtterance"]  # type: ignore[index]
    latency = report["latency"]  # type: ignore[index]
    rows = "\n".join(
        "| #{} | {} | {} | {} | {} | {} | {} | {} |".format(
            row["record"],
            row["summary"],
            row["statusScope"],
            row["finalRef"] or "—",
            row["previewCount"],
            row["distinctCandidates"],
            row["lastPreviewRef"] or "—",
            "是" if row["lastPreviewOverlapsFinal"] else "否",
        )
        for row in per
    )
    return (
        "# 预览候选对照统计（脚本生成）\n\n"
        f"- 片段数 {report['utterances']}，预览 {report['totalPreviews']} 次\n"
        f"- 有候选预览 {report['previewsWithCandidate']} 次，跨章候选 "
        f"{report['crossChapterCandidatePreviews']} 次"
        f"（{report['crossChapterRate']:.1%}）\n"
        f"- 连续两轮相同的跨章候选 {report['stableConsecutiveCrossChapterPairs']} 对"
        f"（占相邻预览对 {report['stablePairRate']:.1%}）\n"
        f"- 末次预览与终稿重叠 {report['lastPreviewOverlapsFinal']}/"
        f"{report['scoredUtterances']}（{report['lastPreviewOverlapRate']:.1%}）\n\n"
        "| 记录 | 摘要 | 状态/范围 | 终稿 | 预览数 | 不同候选 | 末次预览候选 | 与终稿重叠 |\n"
        "|---|---|---|---|---|---|---|---|\n"
        f"{rows}\n"
    )


if __name__ == "__main__":
    main()
