#!/usr/bin/env bash
# ============================================================
# 示例 03：编码类任务（只要代码文本）
# ------------------------------------------------------------
# 关键点：**显式声明权限边界**。
#
# 如果不声明，它会尝试用 shell 写盘 / 跑命令 →
# headless 下无法弹授权 → 该动作被自动拒绝 →
# **整个回合返回空回复，但计费照扣**（实测一次 20 万 token）。
#
# 所以：任务只需返回文本时，必须写明"你没有写权限"。
# ============================================================
set -euo pipefail

MODEL="${AGY_MODEL:-gemini-3.8-flash-high}"
OUT_DIR="${OUT_DIR:-./out}"
PROMPT_FILE="$OUT_DIR/03-prompt.txt"
RESULT_FILE="$OUT_DIR/03-result.json"

mkdir -p "$OUT_DIR"

# ------------------------------------------------------------
# 步骤 1：构造 prompt
# ------------------------------------------------------------
REQUIREMENT="${1:-<在此填写编码需求>}"

cat > "$PROMPT_FILE" <<EOF
请编写一段代码完成以下需求。

需求：
${REQUIREMENT}

要求：
1. 只使用标准库（除非需求明确要求第三方库）。
2. 代码需可直接运行，包含必要的输入校验与错误处理。
3. 在代码后附一段简短说明：设计取舍、边界情况。

输出格式：
§1 代码（完整，放在一个代码块里）
§2 说明（不超过 200 字）

注意：你没有文件写入权限，不要尝试创建、写入或运行任何文件。
完整代码请以文本形式写在回复里，我会自行落盘。
EOF

echo "[1/3] prompt 已落盘：$PROMPT_FILE"

# ------------------------------------------------------------
# 步骤 2：派发（串行重试 ≥3 次）
# ------------------------------------------------------------
PROMPT="$(cat "$PROMPT_FILE")"

for attempt in 1 2 3; do
  echo "[2/3] 派发中（第 $attempt 次）..."

  if RESP=$(agy -p "$PROMPT" --model "$MODEL" --output-format json 2>./out/03-stderr.log); then
    if python -c "
import json,sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get('usage',{}).get('total_tokens',0) > 0 else 1)
" <<< "$RESP" 2>/dev/null; then
      echo "$RESP" > "$RESULT_FILE"
      break
    fi
  fi

  [ "$attempt" = "3" ] && { echo "[2/3] 三次均失败，请查 ./out/03-stderr.log"; exit 1; }
done

echo "[2/3] 结果：$RESULT_FILE"

# ------------------------------------------------------------
# 步骤 3：三层判据检查
# ------------------------------------------------------------
python - "$RESULT_FILE" <<'PY'
import json, sys, pathlib, re

d = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
resp = d.get("response", "")
usage = d.get("usage", {})

print("\n[3/3] 三层判据")
print("-" * 58)

# ① 调用层
tok = usage.get("total_tokens", 0)
print(f"① 调用层  total_tokens = {tok}   {'✅' if tok > 0 else '❌ 未真正执行'}")

# ② 交付层
has_code = "```" in resp
mid_state = bool(re.search(r"Waiting for .* to conclude", resp)) and not has_code
print(f"② 交付层  含代码块 = {has_code}   "
      f"{'❌ 疑似中间态' if mid_state else '✅'}")

# ③ 内容层
fences = resp.count("```")
fences_ok = fences % 2 == 0
tail = resp.rstrip()[-120:].replace("\n", " ")
print(f"③ 内容层  围栏成对 = {fences_ok} ({fences} 个)   "
      f"{'✅' if fences_ok else '❌ 可能截断'}")
print(f"   末句：…{tail}")

print("-" * 58)
print("\n完整回复：")
print("=" * 58)
print(resp)
PY
