#!/usr/bin/env bash
# ============================================================
# 示例 01：第二意见（独立性可审计）
# ------------------------------------------------------------
# 关键设计：**先写下我方意见，再派发**。
#   - 我方意见必须写在 prompt 之外（否则污染独立性）
#   - 交付后两栏对比
#   - prompt 文件可回查，用于证明"派出前我方判断未被泄露"
# ============================================================
set -euo pipefail

MODEL="${AGY_MODEL:-gemini-3.8-flash-high}"
OUT_DIR="${OUT_DIR:-./out}"
PROMPT_FILE="$OUT_DIR/01-prompt.txt"
OPINION_FILE="$OUT_DIR/01-my-opinion.md"
RESULT_FILE="$OUT_DIR/01-result.json"

mkdir -p "$OUT_DIR"

# ------------------------------------------------------------
# 步骤 1：先写下我方意见（不放进 prompt）
# ------------------------------------------------------------
cat > "$OPINION_FILE" <<'EOF'
## 我方意见（派出前独立写下）

结论：（这里写你的判断）

理由：
1.
2.

不确定之处：
-
EOF

echo "[1/4] 我方意见已落盘：$OPINION_FILE"

# ------------------------------------------------------------
# 步骤 2：构造自包含 prompt（不得包含我方任何判断）
# ------------------------------------------------------------
cat > "$PROMPT_FILE" <<'EOF'
请你独立评估以下技术问题，给出你的判断与理由。

问题：
<在此描述待评估的问题>

要求：
1. 给出明确结论，并说明依据。
2. 列出至少两条反例或不适用场景。
3. 如果你认为问题本身的表述有问题，请直接指出。
4. 输出格式：
   §1 结论（一句话）
   §2 理由（分点）
   §3 反例 / 不适用场景（分点）
   §4 你的不确定之处

注意：你没有文件写入权限，不要尝试创建或写入任何文件。完整回答直接写在回复里。
EOF

echo "[2/4] prompt 已落盘：$PROMPT_FILE（可回查，证明独立性）"

# ------------------------------------------------------------
# 步骤 3：派发（串行重试 ≥3 次）
# ------------------------------------------------------------
PROMPT="$(cat "$PROMPT_FILE")"

for attempt in 1 2 3; do
  echo "[3/4] 派发中（第 $attempt 次）..."

  if RESP=$(agy -p "$PROMPT" --model "$MODEL" --output-format json 2>./out/01-stderr.log); then
    # 三层判据之①：调用层硬信号
    if python -c "
import json,sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get('usage',{}).get('total_tokens',0) > 0 else 1)
" <<< "$RESP" 2>/dev/null; then
      echo "$RESP" > "$RESULT_FILE"
      echo "[3/4] 成功，结果：$RESULT_FILE"
      break
    else
      echo "[3/4] 硬信号未通过（total_tokens=0），重试"
    fi
  else
    echo "[3/4] 调用失败，重试"
  fi

  [ "$attempt" = "3" ] && { echo "[3/4] 三次均失败，请查 ./out/01-stderr.log"; exit 1; }
done

# ------------------------------------------------------------
# 步骤 4：两栏对比（人工核对）
# ------------------------------------------------------------
python - "$RESULT_FILE" <<'PY'
import json, sys, pathlib

d = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
resp = d.get("response", "")
print("[4/4] 外部第二意见：")
print("=" * 60)
print(resp)
print("=" * 60)
print(f"耗时: {d.get('duration_seconds', '?')}s | tokens: {d.get('usage', {}).get('total_tokens')}")
print()
print("▶ 现在打开 01-my-opinion.md 做两栏对比：")
print("  - 结论是否一致？")
print("  - 它指出的反例你是否考虑过？")
print("  - 它是否指出了问题本身的缺陷？")
PY
