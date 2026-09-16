#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 Tilawa 声学模型改造成 ONNX Runtime 1.22（Android AAR 最新版）可加载的版本。

背景
----
原模型内含 57 个 ``ConvInteger`` 节点（int8 量化卷积）。该算子只有较新版本的
ONNX Runtime CPU EP 才实现，而 Android 侧 ``onnxruntime-android`` 最新仅到
1.22.0，加载时会报::

    NOT_IMPLEMENTED : Could not find an implementation for ConvInteger(10)

改造方式（数学等价）
--------------------
原始子图::

    x → DynamicQuantizeLinear → x_q(int8), x_scale, x_zp
      → ConvInteger(x_q, w_q, x_zp, w_zp) → y_int32
      → Cast(int32 → float32)
      → Mul(·, x_scale * w_scale) → y

替换为（在原节点位置就地替换，保证拓扑序不变）::

    x → DynamicQuantizeLinear → x_q, x_scale, x_zp
      → DequantizeLinear(x_q, x_scale, x_zp) → x_dq
      → Conv(x_dq, w_dequantized) → y           （直接复用 Mul 的输出名）

其中 ``w_dequantized = (w_q - w_zp) * w_scale`` 在离线阶段算好，作为常量写入。

代价与收益
----------
- 代价：该 57 个卷积权重由 int8 变 float32（模型体积增大），推理走 FP32 卷积
- 收益：模型在 ORT 1.22（Android/iOS 实际可用版本）上即可运行

用法::

    .venv/bin/python convert_for_ort122.py            # 转换并校验
    .venv/bin/python convert_for_ort122.py --check    # 仅校验产物是否可加载
"""

from __future__ import annotations

import argparse
import os
import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.abspath(os.path.join(HERE, "..", "..", "assets", "quran_offline"))
SRC_PATH = os.path.join(ASSETS, "fastconformer_full_mixed.onnx")
DST_PATH = os.path.join(ASSETS, "fastconformer_full_mixed_ort122.onnx")


def prune_dead_code(model: onnx.ModelProto) -> int:
    """清理改造后不再被引用的 initializer 与节点（原 int8 权重、scale 计算链等）。

    Args:
        model: 待清理的模型（原地修改）。

    Returns:
        移除的元素数量（initializer + 节点）。
    """
    graph = model.graph

    def used_names(nodes) -> set[str]:
        names = set()
        for node in nodes:
            for name in node.input:
                if name:
                    names.add(name)
        for out in graph.output:
            names.add(out.name)
        return names

    # 迭代删除无消费者的节点，直到收敛
    nodes = list(graph.node)
    while True:
        used = used_names(nodes)
        kept = [n for n in nodes if any(o in used for o in n.output)]
        if len(kept) == len(nodes):
            break
        nodes = kept

    used = used_names(nodes)
    kept_init = [item for item in graph.initializer if item.name in used]
    removed = (len(graph.initializer) - len(kept_init)) + (len(graph.node) - len(nodes))

    del graph.node[:]
    graph.node.extend(nodes)
    del graph.initializer[:]
    graph.initializer.extend(kept_init)
    return removed


def convert(src: str, dst: str) -> dict:
    """执行图改造（ConvInteger → DequantizeLinear + Conv）。

    Args:
        src: 原始模型路径。
        dst: 输出模型路径。

    Returns:
        统计信息（转换节点数、新增权重体积、体积变化）。
    """
    model = onnx.load(src)
    graph = model.graph

    initializers = {item.name: item for item in graph.initializer}
    producer = {out: node for node in graph.node for out in node.output}
    consumers: dict[str, list] = {}
    for node in graph.node:
        for name in node.input:
            consumers.setdefault(name, []).append(node)

    #: 一趟扫描：收集每个 ConvInteger 的替换方案
    plans: dict[str, dict] = {}
    skipped = 0
    for node in graph.node:
        if node.op_type != "ConvInteger":
            continue

        x_q, w_q = node.input[0], node.input[1]
        dql = producer.get(x_q)
        if dql is None or dql.op_type != "DynamicQuantizeLinear":
            print(f"[SKIP] {node.name}: 输入不是 DynamicQuantizeLinear 输出")
            skipped += 1
            continue

        base = w_q.replace("_quantized", "")
        w_scale_name = f"{base}_scale"
        w_zero_name = f"{base}_zero_point"
        if w_q not in initializers or w_scale_name not in initializers:
            print(f"[SKIP] {node.name}: 缺少权重 {w_q} / {w_scale_name}")
            skipped += 1
            continue

        cast_list = [n for n in consumers.get(node.output[0], []) if n.op_type == "Cast"]
        if len(cast_list) != 1:
            print(f"[SKIP] {node.name}: 下游 Cast 数量异常")
            skipped += 1
            continue
        cast = cast_list[0]

        mul_list = [n for n in consumers.get(cast.output[0], []) if n.op_type == "Mul"]
        if len(mul_list) != 1:
            print(f"[SKIP] {node.name}: 下游 Mul 数量异常")
            skipped += 1
            continue
        mul = mul_list[0]

        # 反量化权重：w = (w_q - w_zp) * w_scale
        w_int = numpy_helper.to_array(initializers[w_q]).astype(np.float32)
        w_scale = numpy_helper.to_array(initializers[w_scale_name]).astype(np.float32)
        w_zero = (
            numpy_helper.to_array(initializers[w_zero_name]).astype(np.float32)
            if w_zero_name in initializers
            else np.zeros((), dtype=np.float32)
        )
        w_float = (w_int - w_zero) * w_scale

        plans[node.name] = {
            "x_q": x_q,
            "x_scale": dql.output[1],
            "x_zero_point": dql.output[2],
            "w_float_name": f"{w_q}_dequantized",
            "w_float": w_float.astype(np.float32),
            "out_name": mul.output[0],
            "attrs": {a.name: helper.get_attribute_value(a) for a in node.attribute},
            "drop": {cast.name, mul.name},
        }

    #: 二趟重建：在原 ConvInteger 位置插入 DequantizeLinear + Conv，移除 Cast/Mul
    dropped = {name for plan in plans.values() for name in plan["drop"]}
    rebuilt = []
    new_initializers = []
    added_bytes = 0

    for node in graph.node:
        plan = plans.get(node.name)
        if plan is not None:
            new_initializers.append(numpy_helper.from_array(plan["w_float"], plan["w_float_name"]))
            added_bytes += plan["w_float"].nbytes
            x_dq_name = f"{plan['x_q']}_dequantized"
            rebuilt.append(
                helper.make_node(
                    "DequantizeLinear",
                    [plan["x_q"], plan["x_scale"], plan["x_zero_point"]],
                    [x_dq_name],
                    name=f"{node.name}_dequant",
                )
            )
            rebuilt.append(
                helper.make_node(
                    "Conv",
                    [x_dq_name, plan["w_float_name"]],
                    [plan["out_name"]],
                    name=f"{node.name}_float",
                    **plan["attrs"],
                )
            )
            continue
        if node.name in dropped:
            continue
        rebuilt.append(node)

    del graph.node[:]
    graph.node.extend(rebuilt)
    graph.initializer.extend(new_initializers)

    removed = prune_dead_code(model)
    onnx.checker.check_model(model)
    onnx.save(model, dst)

    return {
        "converted": len(plans),
        "skipped": skipped,
        "removed": removed,
        "added_weight_mb": added_bytes / 1024 / 1024,
        "src_size_mb": os.path.getsize(src) / 1024 / 1024,
        "dst_size_mb": os.path.getsize(dst) / 1024 / 1024,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="为 ORT 1.22 改造模型（ConvInteger → DequantizeLinear + Conv）"
    )
    parser.add_argument("--src", default=SRC_PATH, help="原始模型路径")
    parser.add_argument("--dst", default=DST_PATH, help="输出模型路径")
    parser.add_argument("--check", action="store_true", help="仅校验产物是否可加载")
    args = parser.parse_args()

    if args.check:
        import onnxruntime as ort

        session = ort.InferenceSession(args.dst, providers=["CPUExecutionProvider"])
        print(f"[OK] 可加载: {args.dst}")
        print(f"     输入: {[(i.name, i.shape) for i in session.get_inputs()]}")
        print(f"     输出: {[(o.name, o.shape) for o in session.get_outputs()]}")
        return 0

    stats = convert(args.src, args.dst)
    print(f"[完成] 转换 {stats['converted']} 个 ConvInteger，跳过 {stats['skipped']} 个")
    print(f"       反量化权重新增 {stats['added_weight_mb']:.1f} MB")
    print(f"       体积 {stats['src_size_mb']:.1f} MB → {stats['dst_size_mb']:.1f} MB")
    print(f"       输出: {args.dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
