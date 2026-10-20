#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BLE 抓包分析脚本（配套 BleFrameRecorder.swift）

用途：从录制的 TBOE 帧中逆向出协议结构 —— 这是移植路上最后一块拼图。

用法：
    python analyze_tboe.py capture.json

产出：
    1. 帧序列概览（时间轴 + 方向）
    2. 字段结构推断（尝试定位魔数/长度/序号/校验）
    3. 指令帧与应答帧配对
    4. 与车端配置（car_config.json）的编码比对
"""

import json
import sys
import os
from collections import Counter, defaultdict

# 车端特征 UUID
UUID_PRIMARY = "0000fff1-0000-1000-8000-00805f9b34fb"
UUID_SECONDARY = "0000fff2-0000-1000-8000-00805f9b34fb"


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def parse_frames(log):
    """把 JSON 帧转成便于分析的字典列表。"""
    out = []
    for f in log.get("frames", []):
        hex_str = f.get("hex", "").replace(" ", "")
        try:
            data = bytes.fromhex(hex_str) if hex_str else b""
        except ValueError:
            data = b""
        out.append({
            "index": f.get("index", 0),
            "rel": f.get("relativeTime", 0.0),
            "dir": f.get("direction", "?"),
            "uuid": f.get("characteristic", ""),
            "data": data,
            "ascii": f.get("ascii", ""),
        })
    return out


# ---------- 1. 序列概览 ----------

def overview(frames):
    print("=" * 72)
    print("帧序列概览")
    print("=" * 72)

    total = len(frames)
    tx = sum(1 for f in frames if f["dir"] == "TX")
    rx = sum(1 for f in frames if f["dir"] == "RX")
    print(f"总帧数 {total}   TX {tx}   RX {rx}")

    by_uuid = Counter(f["uuid"] for f in frames)
    print("\n按特征分布:")
    for uuid, n in by_uuid.most_common():
        short = "fff1(主)" if UUID_PRIMARY in uuid else \
                "fff2(次)" if UUID_SECONDARY in uuid else uuid[:18]
        print(f"  {short:>12}  {n:4d} 帧")

    lens = [len(f["data"]) for f in frames]
    if lens:
        print(f"\n帧长分布: min={min(lens)} max={max(lens)} avg={sum(lens)/len(lens):.1f}")
        print(f"长度直方图: {dict(sorted(Counter(lens).items())[:20])}")

    # 时间间隔
    rels = [f["rel"] for f in frames]
    if len(rels) > 1:
        gaps = [rels[i+1] - rels[i] for i in range(len(rels)-1)]
        print(f"\n帧间隔: min={min(gaps):.3f}s max={max(gaps):.3f}s")
        print(f"录制总时长: {rels[-1] - rels[0]:.2f}s")


# ---------- 2. 字段结构推断 ----------

def infer_structure(frames):
    print("\n" + "=" * 72)
    print("字段结构推断")
    print("=" * 72)

    # 按方向+长度分组，看哪些字节位置稳定（可能是魔数/版本）
    print("\n[2.1] 各字节位置的取值分布（寻找固定字段）")

    max_len = max((len(f["data"]) for f in frames), default=0)
    if max_len == 0:
        print("  无有效帧数据")
        return

    # 跨全部帧按偏移统计（长度不同也能发现共有的固定头）
    print("\n  --- 跨全部帧的偏移统计 ---")
    for pos in range(max_len):
        values = [f["data"][pos] for f in frames if len(f["data"]) > pos]
        if len(values) < len(frames):
            continue  # 跳过部分帧没有的偏移
        uniq = Counter(values)
        if len(uniq) == 1:
            print(f"    字节[{pos:2d}] 全部帧恒定 = 0x{values[0]:02X}   ← 强候选：魔数/版本/类型")
        elif len(uniq) <= 3 and len(frames) > 3:
            top = ", ".join(f"0x{v:02X}({c})" for v, c in uniq.most_common())
            print(f"    字节[{pos:2d}] 取值少: {top}")

    # 同长度分组内的逐帧变化
    groups = defaultdict(list)
    for f in frames:
        groups[(f["dir"], len(f["data"]))].append(f)

    for key in sorted(groups.keys(), key=lambda k: -len(groups[k]))[:5]:
        grp = groups[key]
        if len(grp) < 2:
            continue
        direction, length = key
        print(f"\n  --- 方向={direction} 长度={length} 共{len(grp)}帧 ---")

        for pos in range(length):
            values = [f["data"][pos] for f in grp if pos < len(f["data"])]
            uniq = Counter(values)
            if len(uniq) == 1:
                print(f"    字节[{pos:2d}] 恒定 = 0x{values[0]:02X}")
            elif len(grp) <= 4 and len(uniq) <= len(grp):
                vals = ", ".join(f"0x{v:02X}" for v in values)
                print(f"    字节[{pos:2d}] 逐帧变化: {vals}   ← 可能是计数器/时间戳")

    # 查找可能的校验和
    print("\n[2.2] 校验和假设检验")
    check_candidates = []

    for key, grp in groups.items():
        if len(grp) < 2 or key[1] < 4:
            continue

        direction, length = key

        # 假设末字节 = 前面所有字节异或（含帧头）
        xor_ok = True
        for f in grp:
            data = f["data"]
            if len(data) < 4:
                continue
            expect = data[-1]
            actual = 0
            for b in data[:-1]:
                actual ^= b
            if actual != expect:
                xor_ok = False
                break
        if xor_ok:
            check_candidates.append(
                f"方向={direction} 长度={length}: 末字节 = 前面所有字节异或")

        # 假设末字节 = 去掉帧头后剩余部分异或
        xor2_ok = True
        for f in grp:
            data = f["data"]
            if len(data) < 4:
                continue
            expect = data[-1]
            actual = 0
            for b in data[2:-1]:
                actual ^= b
            if actual != expect:
                xor2_ok = False
                break
        if xor2_ok and not xor_ok:
            check_candidates.append(
                f"方向={direction} 长度={length}: 末字节 = 去掉帧头后异或")

        # 假设末字节 = 前面所有字节之和 mod 256
        sum_ok = True
        for f in grp:
            data = f["data"]
            if len(data) < 4:
                continue
            expect = data[-1]
            actual = sum(data[:-1]) & 0xFF
            if actual != expect:
                sum_ok = False
                break
        if sum_ok:
            check_candidates.append(
                f"方向={direction} 长度={length}: 末字节 = 前面所有字节之和 mod 256")

    # 跨全部帧检验（同一协议通常对所有长度一致）
    if max_len >= 5:
        all_xor = True
        for f in frames:
            data = f["data"]
            if len(data) < 5:
                continue
            actual = 0
            for b in data[:-1]:
                actual ^= b
            if actual != data[-1]:
                all_xor = False
                break
        if all_xor:
            check_candidates.append("★ 全部帧一致: 末字节 = 前面所有字节异或")

    if check_candidates:
        for c in check_candidates:
            print(f"  ✓ {c}")
    else:
        print("  未发现简单校验和规则（可能是 CRC16，或载荷本身是加密密文）")
        print("  提示：若挑战码帧找不到校验和规则，说明该字段可能是签名/密文")

    # 前缀搜索
    print("\n[2.3] 常见协议头前缀检验")
    prefixes = {
        b"\xAA\xAA": "疑似 AA AA 帧头",
        b"\xAA\x55": "疑似 AA 55 帧头",
        b"\x55\xAA": "疑似 55 AA 帧头",
        b"\x5A\xA5": "疑似 5A A5 帧头",
        b"\x7E": "疑似 7E（常见串口协议）",
        b"\xA5": "疑似 A5",
    }
    found = Counter()
    for f in frames:
        for pre, desc in prefixes.items():
            if f["data"].startswith(pre):
                found[desc] += 1
    if found:
        for desc, n in found.most_common():
            print(f"  {desc}: {n} 帧命中")
    else:
        print("  未匹配常见帧头")


# ---------- 3. 指令应答配对 ----------

def pair_frames(frames):
    print("\n" + "=" * 72)
    print("指令应答配对")
    print("=" * 72)

    # 每个 TX 后紧跟的 RX 视为一次请求-响应
    pending = None
    pairs = []

    for f in frames:
        if f["dir"] == "TX":
            pending = f
        elif f["dir"] == "RX" and pending is not None:
            pairs.append((pending, f))
            pending = None

    print(f"共配对 {len(pairs)} 组 请求-应答")
    for i, (req, resp) in enumerate(pairs[:20], 1):
        print(f"\n  [{i}] t={req['rel']:.3f}s")
        print(f"      TX {len(req['data']):3d}B: {req['data'].hex(' ').upper()}")
        print(f"         可读: {req['ascii']}")
        print(f"      RX {len(resp['data']):3d}B: {resp['data'].hex(' ').upper()}")
        print(f"         可读: {resp['ascii']}")
        print(f"      延迟: {(resp['rel'] - req['rel']) * 1000:.0f}ms")


# ---------- 4. 与车端配置比对 ----------

def compare_with_config(frames, car_config_path=None):
    print("\n" + "=" * 72)
    print("与车端配置比对")
    print("=" * 72)

    if not car_config_path or not os.path.exists(car_config_path):
        print("  未提供 car_config.json，跳过")
        return

    with open(car_config_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    cmds = cfg.get("commandList", [])
    hex_to_cmd = {}
    for c in cmds:
        val = c.get("value")
        if val:
            hex_to_cmd[val.upper()] = (c.get("description", ""), c.get("android", ""), c.get("commandAndroid"))

    print(f"  车端配置共 {len(cmds)} 条指令")

    # 在帧中查找以指令编码开头的
    matched = []
    for f in frames:
        data_hex = f["data"].hex().upper()
        for val, info in hex_to_cmd.items():
            if val in data_hex:
                matched.append((f, val, info))

    if matched:
        print(f"\n  命中 {len(matched)} 处指令编码：")
        seen = set()
        for f, val, (desc, name, idx) in matched:
            key = (val, f["dir"])
            if key in seen:
                continue
            seen.add(key)
            print(f"    [{f['dir']}] {val} → #{idx} {desc} ({name})")
    else:
        print("  未在帧中找到已知指令编码")
        print("  说明：指令可能是二进制编码而非 ASCII，或用了不同的编码方案")


# ---------- 5. 主入口 ----------

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        print("\n用法: python analyze_tboe.py <capture.json> [car_config.json]")
        sys.exit(1)

    capture = sys.argv[1]
    car_config = sys.argv[2] if len(sys.argv) > 2 else None

    log = load(capture)
    frames = parse_frames(log)

    if not frames:
        print("抓包文件为空或无有效帧")
        sys.exit(1)

    print(f"\n设备: {log.get('device')} iOS {log.get('systemVersion')}")
    print(f"对端: {log.get('peer')} ({log.get('peerIdentifier')})")
    print(f"导出时间: {log.get('exportedAt')}")
    print()

    overview(frames)
    infer_structure(frames)
    pair_frames(frames)
    compare_with_config(frames, car_config)

    print("\n" + "=" * 72)
    print("下一步")
    print("=" * 72)
    print("""
  1. 若找到固定字节位置 → 那是魔数/版本/类型，写进 TboeTransport.swift
  2. 若发现校验和规则 → 加入帧编解码
  3. 用指令观察法定位字段：
     - 开后备箱 vs 关后备箱，两帧异或 → 差异位即动作码
     - 同一指令连续两次 → 差异位可能是序号或时间戳
  4. 挑战码：连接后车端首帧的 RX，标注意见其可读内容
  5. 补完协议规格.md 里的 [未知] 项
""")


if __name__ == "__main__":
    main()