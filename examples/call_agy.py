#!/usr/bin/env python3
"""
agy 子代理调用的最小封装。

设计目标：
  1. 把「四条硬要求」固化进代码 —— 重试、无超时参数、代理透传
  2. 把「三层判据」自动化 —— 调用层 / 交付层 / 内容层
  3. 解析顺序正确 —— 优先 structured_output，兜底 response 最后一行

用法（CLI）：
    python call_agy.py "你的任务描述"
    python call_agy.py "任务" --model gemini-3.8-flash-high
    python call_agy.py "任务" --add-dir /path/to/data --json-schema schema.json

用法（作为模块）：
    from call_agy import call_agy, check_three_layers
    r = call_agy("请独立评估……")
    print(r.text)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_MODEL = "gemini-3.8-flash-high"
DEFAULT_RETRIES = 3


# ---------------------------------------------------------------- 结果对象

@dataclass
class AgyResult:
    """一次调用的完整结果，含三层判据的检查结论。"""

    ok: bool                    # 整体是否通过（三层全过）
    text: str                   # 交付文本（structured_output 或 response）
    structured: dict | None     # structured_output 字段（若有）
    conversation_id: str = ""
    total_tokens: int = 0
    duration_seconds: float = 0.0
    denied_actions: list = field(default_factory=list)
    attempts: int = 0
    raw: dict = field(default_factory=dict)

    # 三层判据
    layer1_ok: bool = False     # 调用层：total_tokens > 0
    layer2_ok: bool = False     # 交付层：非空、非中间态
    layer3_ok: bool = False     # 内容层：结构完整

    error: str | None = None    # 失败原因

    def summary(self) -> str:
        marks = lambda b: "✅" if b else "❌"
        return (
            f"① 调用层 {marks(self.layer1_ok)} (tokens={self.total_tokens})  "
            f"② 交付层 {marks(self.layer2_ok)}  "
            f"③ 内容层 {marks(self.layer3_ok)}  "
            f"[尝试 {self.attempts} 次, {self.duration_seconds:.1f}s]"
        )


# ---------------------------------------------------------------- 三层判据

_MID_STATE_MARKERS = (
    "Waiting for", "waiting for", "to conclude",
)


def check_three_layers(payload: dict) -> tuple[bool, bool, bool, str]:
    """按三层判据检查返回载荷。

    返回 (layer1_ok, layer2_ok, layer3_ok, 说明)
    """
    usage = payload.get("usage") or {}
    response = payload.get("response") or ""
    structured = payload.get("structured_output")

    # ① 调用层：唯一硬指纹
    total_tokens = int(usage.get("total_tokens") or 0)
    layer1 = total_tokens > 0

    # ② 交付层：有内容，且不是停在中间态
    has_content = bool(structured) or bool(response.strip())
    looks_mid_state = (
        bool(response)
        and any(m in response for m in _MID_STATE_MARKERS)
        and len(response.strip()) < 200          # 中间态通常很短
    )
    layer2 = has_content and not looks_mid_state

    # ③ 内容层：围栏成对 + 末句完整
    if structured:
        layer3 = True                            # 已解析的结构化输出，视为完整
    else:
        fences_ok = response.count("```") % 2 == 0
        tail_ok = bool(response.strip()) and not response.rstrip().endswith(("，", ",", "、", "：", ":"))
        layer3 = fences_ok and tail_ok

    if not layer1:
        note = "调用层未通过：total_tokens=0，模型未真正执行"
    elif not layer2:
        note = "交付层未通过：回复为空或停在中间态"
    elif not layer3:
        note = "内容层未通过：结构可能被截断"
    else:
        note = "三层判据全部通过"

    return layer1, layer2, layer3, note


# ---------------------------------------------------------------- 主调用

def _parse(attempts_left: int, stdout: str) -> AgyResult:
    payload = json.loads(stdout)
    l1, l2, l3, note = check_three_layers(payload)

    structured = payload.get("structured_output")
    text = ""
    if structured:
        text = json.dumps(structured, ensure_ascii=False, indent=2)
    else:
        raw_resp = payload.get("response") or ""
        # 形态不固定：可能是「正文 + 末行 JSON」，也可能是单行纯 JSON —— 取最后一行兜底
        last = raw_resp.strip().splitlines()[-1] if raw_resp.strip() else ""
        try:
            parsed = json.loads(last)
            text = json.dumps(parsed, ensure_ascii=False, indent=2)
        except Exception:
            text = raw_resp

    return AgyResult(
        ok=(l1 and l2 and l3),
        text=text,
        structured=structured,
        conversation_id=payload.get("conversation_id", ""),
        total_tokens=int((payload.get("usage") or {}).get("total_tokens") or 0),
        duration_seconds=float(payload.get("duration_seconds") or 0.0),
        denied_actions=payload.get("denied_actions") or [],
        layer1_ok=l1, layer2_ok=l2, layer3_ok=l3,
        raw=payload,
        error=None if (l1 and l2 and l3) else note,
    )


def call_agy(
    prompt: str,
    model: str = DEFAULT_MODEL,
    add_dirs: list[str] | tuple[str, ...] = (),
    schema: str | None = None,
    retries: int = DEFAULT_RETRIES,
    proxy: str | None = None,
    timeout: int | None = None,
    verbose: bool = True,
) -> AgyResult:
    """派发一个自包含任务给 agy。

    注意（四条硬要求已内化）：
      - **不传 --print-timeout**（默认即不限时长）
      - **失败自动串行重试 ≥3 次**
      - **代理经环境变量透传**
      - 并发请由调用方控制：外部多进程最多 2 路
    """
    exe = shutil.which("agy") or "agy"

    env = os.environ.copy()
    if proxy:
        env["HTTPS_PROXY"] = proxy
        env["HTTP_PROXY"] = proxy

    cmd = [exe, "-p", prompt, "--model", model, "--output-format", "json"]
    for d in add_dirs:
        cmd += ["--add-dir", str(d)]
    if schema:
        cmd += ["--json-schema", schema]
    # 刻意不传 --print-timeout —— 默认即不限时长

    last = AgyResult(ok=False, text="", structured=None, error="未执行")

    for attempt in range(1, retries + 1):
        last.attempts = attempt
        if verbose:
            print(f"[agy] 第 {attempt}/{retries} 次调用 …", file=sys.stderr)

        t0 = time.time()
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True,
                encoding="utf-8", errors="replace",
                env=env, timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            last.error = f"调用方超时（{timeout}s）"
            if verbose:
                print(f"[agy] 超时，准备重试", file=sys.stderr)
            continue
        except FileNotFoundError:
            last.error = "找不到 agy 可执行文件，请确认已安装并加入 PATH"
            return last

        if proc.returncode != 0:
            last.error = f"退出码 {proc.returncode}；stderr 摘要：{(proc.stderr or '')[:200]}"
            if verbose:
                print(f"[agy] 退出码非 0，准备重试", file=sys.stderr)
            continue

        if not (proc.stdout or "").strip():
            last.error = "stdout 为空"
            if verbose:
                print("[agy] stdout 为空，准备重试", file=sys.stderr)
            continue

        try:
            result = _parse(attempt, proc.stdout)
        except json.JSONDecodeError as e:
            last.error = f"返回体不是合法 JSON：{e}"
            if verbose:
                print("[agy] JSON 解析失败，准备重试", file=sys.stderr)
            continue

        if not result.duration_seconds:
            result.duration_seconds = time.time() - t0

        if result.ok:
            if verbose:
                print(f"[agy] {result.summary()}", file=sys.stderr)
            return result

        last = result
        last.error = last.error or "三层判据未通过"
        if verbose:
            print(f"[agy] {result.summary()} —— {last.error}；准备重试", file=sys.stderr)

        # 交付层失败（中间态）：可用 --conversation 续接，此处仅提示
        if result.layer1_ok and not result.layer2_ok and result.conversation_id:
            if verbose:
                print(
                    f"[agy] 提示：疑似中间态，可续接会话："
                    f"--conversation {result.conversation_id}",
                    file=sys.stderr,
                )

    return last


# ---------------------------------------------------------------- CLI

def main() -> int:
    ap = argparse.ArgumentParser(
        description="派发自包含任务给 agy 子代理（含三层判据自动检查）"
    )
    ap.add_argument("prompt", help="自包含的任务描述")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--add-dir", action="append", default=[], dest="add_dirs",
                    help="纳入工作区（可重复）")
    ap.add_argument("--json-schema", dest="schema", default=None,
                    help="强制结构化输出的 schema（字符串或文件路径）")
    ap.add_argument("--retries", type=int, default=DEFAULT_RETRIES)
    ap.add_argument("--proxy", default=None, help="如 http://127.0.0.1:7890")
    ap.add_argument("--timeout", type=int, default=None,
                    help="**调用方**自身的兜底超时（非 agy 的参数）")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("-o", "--output", default=None, help="把结果另存为文件")
    args = ap.parse_args()

    r = call_agy(
        args.prompt,
        model=args.model,
        add_dirs=args.add_dirs,
        schema=args.schema,
        retries=args.retries,
        proxy=args.proxy,
        timeout=args.timeout,
        verbose=not args.quiet,
    )

    print(r.text)
    print("\n" + "-" * 60, file=sys.stderr)
    print(r.summary(), file=sys.stderr)
    if r.denied_actions:
        print(f"⚠️  被拒动作：{r.denied_actions}", file=sys.stderr)
        print("   → 授权未生效，检查路径是否为绝对路径、规则名是否为 write_file（非 write_to_file）",
              file=sys.stderr)
    if r.error:
        print(f"⚠️  {r.error}", file=sys.stderr)

    if args.output:
        Path(args.output).write_text(r.text, encoding="utf-8")
        print(f"已写入：{args.output}", file=sys.stderr)

    return 0 if r.ok else 1


if __name__ == "__main__":
    sys.exit(main())
