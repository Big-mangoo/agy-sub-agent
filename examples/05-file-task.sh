#!/usr/bin/env bash
# ============================================================
# 示例 05：让子代理写文件（授权 + 磁盘回检）
# ------------------------------------------------------------
# 三个关键点：
#   ① 用 --add-dir 做最简授权（不改共享配置）
#   ② prompt 里写死**绝对路径**（相对路径会被拒，且它的 cwd 不是你 shell 的 cwd）
#   ③ **事后必须磁盘回检** —— 它会声称"已创建"，也可能写到自己的 scratch/
#
# 🚫 本示例不含删除操作。删除不在本通道的能力范围内（见 docs/permissions.md）。
# ============================================================
set -euo pipefail

MODEL="${AGY_MODEL:-gemini-3.8-flash-high}"

# ------------------------------------------------------------
# 配置：请改为你自己的绝对路径
# ------------------------------------------------------------
WORK_DIR="${WORK_DIR:-$PWD/sandbox}"
OUT_DIR="${OUT_DIR:-./out}"
TARGET_FILE="$WORK_DIR/report.md"

mkdir -p "$WORK_DIR" "$OUT_DIR"

echo "[1/4] 工作目录：$WORK_DIR"

# ------------------------------------------------------------
# 步骤 1：把待处理内容放进工作目录（让子代理自读，比塞进 prompt 更省 token）
# ------------------------------------------------------------
cat > "$WORK_DIR/input.md" <<'EOF'
# 待处理内容

（把需要它处理的材料放在这里。可以是数据、草稿、代码片段等。）
EOF

echo "[2/4] 输入文件已就绪：$WORK_DIR/input.md"

# ------------------------------------------------------------
# 步骤 2：派发 —— 授权 + 绝对路径
# ------------------------------------------------------------
PROMPT="请阅读文件 ${WORK_DIR}/input.md，并据此撰写一份结构化报告。

要求：
1. 输出格式：§1 概要（3 句以内）／§2 要点（分点）／§3 结论。
2. 用 markdown 撰写。
3. **将完整报告写入文件**：${TARGET_FILE}
   （这是必须完成的动作，不要只在回复里贴出内容。）
4. 写入后，在回复中明确告知：是否成功、文件绝对路径、字符数。"

echo "[3/4] 派发中（授权目录：$WORK_DIR）..."

RESP_FILE="$OUT_DIR/05-result.json"
for attempt in 1 2 3; do
  if RESP=$(agy \
        -p "$PROMPT" \
        --model "$MODEL" \
        --add-dir "$WORK_DIR" \
        --output-format json 2>"$OUT_DIR/05-stderr.log"); then
    if python -c "
import json,sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get('usage',{}).get('total_tokens',0) > 0 else 1)
" <<< "$RESP" 2>/dev/null; then
      echo "$RESP" > "$RESP_FILE"
      break
    fi
  fi
  [ "$attempt" = "3" ] && { echo "[3/4] 三次均失败，请查 $OUT_DIR/05-stderr.log"; exit 1; }
done

# 展示它的自述
python - "$RESP_FILE" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print("  子代理自述：")
print("  " + d.get("response", "(空)").strip().replace("\n", "\n  ")[:600])
denied = d.get("denied_actions") or []
if denied:
    print(f"\n  ⚠️  存在被拒动作：{denied}")
    print("     → 授权未生效，请检查 --add-dir 路径是否为绝对路径")
PY

# ------------------------------------------------------------
# 步骤 3：★ 磁盘回检 —— 不采信自述
# ------------------------------------------------------------
echo ""
echo "[4/4] 磁盘回检（这一步不可跳过）"
echo "----------------------------------------------------------"

if [ -f "$TARGET_FILE" ]; then
  SIZE=$(wc -c < "$TARGET_FILE")
  echo "  ✅ 目标文件存在：$TARGET_FILE"
  echo "     大小：$SIZE 字节"
  echo "     前 5 行："
  head -5 "$TARGET_FILE" | sed 's/^/       /'
else
  echo "  ❌ 目标文件不存在 —— 自述与事实不符"
  echo ""
  echo "  排查方向："
  echo "    1. 检查是否写到了它的 scratch/ ："
  echo "       ls ~/.gemini/antigravity-cli/scratch/"
  echo "    2. 检查 denied_actions 是否为空（见上方输出）"
  echo "    3. 确认 --add-dir 给的是绝对路径"
  exit 1
fi

echo "----------------------------------------------------------"
echo ""
echo "⚠️  注意：写入成功 ≠ 内容正确。仍需人工或程序核对内容质量。"
echo "   另：如果本次回复为空但你确信它执行过写入，请回读文件 —— "
echo "       空回复可能是「假失败」（操作已执行）。"
