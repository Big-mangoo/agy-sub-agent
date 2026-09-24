#!/usr/bin/env bash
# ============================================================
# 示例 04：进程内并行 fan out（推荐的并发方式）
# ------------------------------------------------------------
# 为什么不用"启动多个 agy 进程"：
#   实测 2 路可行、3 路开始失败、5 路全败；
#   即便隔离工作目录仍会失败（竞态在全局层）。
#
# 正确做法：把可分解任务写进**一个** prompt，让它自己 fan out。
#
# 本脚本还会检查"是否真的 fan out 了"——纯凭自述不可信。
# ============================================================
set -euo pipefail

MODEL="${AGY_MODEL:-gemini-3.8-flash-high}"
OUT_DIR="${OUT_DIR:-./out}"
CONV_DIR="${CONV_DIR:-$HOME/.gemini/antigravity-cli/conversations}"
PROMPT_FILE="$OUT_DIR/04-prompt.txt"
RESULT_FILE="$OUT_DIR/04-result.json"

mkdir -p "$OUT_DIR"

# ------------------------------------------------------------
# 步骤 1：记录派发前的会话库状态（用于事后核对 fan out）
# ------------------------------------------------------------
BEFORE_LIST="$OUT_DIR/04-conv-before.txt"
ls -1 "$CONV_DIR"/*.db 2>/dev/null | sort > "$BEFORE_LIST" || true
BEFORE_COUNT=$(wc -l < "$BEFORE_LIST")
echo "[1/4] 派发前会话库：$BEFORE_COUNT 个"

# ------------------------------------------------------------
# 步骤 2：构造 prompt —— 三个独立子任务写进一个 prompt
# ------------------------------------------------------------
cat > "$PROMPT_FILE" <<'EOF'
请使用 subagent 机制**并行**完成以下三个相互独立的子任务，然后汇总。

子任务 A：<在此填写子任务 A>
子任务 B：<在此填写子任务 B>
子任务 C：<在此填写子任务 C>

要求：
1. 三个子任务必须**各自独立**完成，互不参考对方结果。
2. 每个子任务给出：结论（一句话）+ 依据（分点）。
3. 最终汇总格式严格如下（三行，每行以编号开头）：

A: <子任务 A 的结论>
B: <子任务 B 的结论>
C: <子任务 C 的结论>

注意：你没有文件写入权限，不要尝试创建或写入任何文件。完整回答直接写在回复里。
EOF

echo "[2/4] prompt 已落盘：$PROMPT_FILE"

# ------------------------------------------------------------
# 步骤 3：派发（单进程；串行重试 ≥3 次）
# ------------------------------------------------------------
PROMPT="$(cat "$PROMPT_FILE")"

for attempt in 1 2 3; do
  echo "[3/4] 派发中（第 $attempt 次，单进程）..."

  if RESP=$(agy -p "$PROMPT" --model "$MODEL" --output-format json 2>./out/04-stderr.log); then
    if python -c "
import json,sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get('usage',{}).get('total_tokens',0) > 0 else 1)
" <<< "$RESP" 2>/dev/null; then
      echo "$RESP" > "$RESULT_FILE"
      break
    fi
  fi

  [ "$attempt" = "3" ] && { echo "[3/4] 三次均失败，请查 ./out/04-stderr.log"; exit 1; }
done

echo "[3/4] 结果：$RESULT_FILE"

# ------------------------------------------------------------
# 步骤 4：核对"是否真的 fan out"
# ------------------------------------------------------------
AFTER_LIST="$OUT_DIR/04-conv-after.txt"
ls -1 "$CONV_DIR"/*.db 2>/dev/null | sort > "$AFTER_LIST" || true
NEW_DBS=$(comm -13 "$BEFORE_LIST" "$AFTER_LIST" | wc -l)

echo ""
echo "[4/4] Fan-out 审计"
echo "----------------------------------------------------------"
echo "  新增会话库文件：$NEW_DBS 个"
echo "  （预期：1 个主库 + N 个子库 = 3 路时应为 4 个）"

if [ "$NEW_DBS" -ge 2 ]; then
  echo "  ✅ 存在多个新库 → 支持"确实 fan out"的判断"
else
  echo "  ⚠️  只新增 1 个库 → 可能并未真的并行，而是顺序作答"
fi

echo ""
echo "  进一步核验（在主库中查 invoke_subagent 记录）："
LATEST=$(comm -13 "$BEFORE_LIST" "$AFTER_LIST" | head -1)
if [ -n "${LATEST:-}" ]; then
  python - "$LATEST" <<'PY'
import sqlite3, sys, json
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
found = 0
for (st, payload) in con.execute("SELECT step_type, step_payload FROM steps"):
    if st == 132 and payload and b"invoke_subagent" in payload:
        found += 1
print(f"  主库中含 invoke_subagent 的工具调用 step：{found} 个")
print("  ✅ 确认 fan out" if found else "  ⚠️ 未发现 fan out 证据")
PY
fi
