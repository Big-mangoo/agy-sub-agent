#!/usr/bin/env bash
# ============================================================
# 示例 02：检索类任务（含防造假纪律）
# ------------------------------------------------------------
# 为什么需要这个示例：
#   实测中，检索类任务抽查 6 条来源有 3 条不实（50%），
#   其中编造的 DOI 格式完整、卷期页齐全，肉眼无法分辨。
#
# 因此本示例做了两件事：
#   ① 把"禁止拼凑条款"原文写进 prompt（源头防护）
#   ② 派发后强制逐条实查 DOI（下游核验）
# ============================================================
set -euo pipefail

MODEL="${AGY_MODEL:-gemini-3.8-flash-high}"
OUT_DIR="${OUT_DIR:-./out}"
PROMPT_FILE="$OUT_DIR/02-prompt.txt"
RESULT_FILE="$OUT_DIR/02-result.json"

mkdir -p "$OUT_DIR"

# ------------------------------------------------------------
# 步骤 1：构造 prompt —— 主题请自行替换
# ------------------------------------------------------------
TOPIC="${1:-<在此填写检索主题>}"

cat > "$PROMPT_FILE" <<EOF
请完成一次文献/资料检索任务。

主题：${TOPIC}

要求：
1. 检索该方向近两年的主流方法与代表性工作。
2. 每条来源必须包含：作者、年份、期刊/会议、标题、可访问来源（DOI 或 arXiv ID 或 URL）。
3. 输出格式：
   §0 检索说明（列出你实际使用的检索式）
   §1 核心发现（每条含方法名称 + 来源标题 + 来源标识）
   §2 一句话总结

来源纪律（强制）：
- 严禁拼凑 DOI：每一个 DOI 必须是你确实检索到并能确认字符级正确的；不能确认就不写 DOI，
  改写为「作者+年份+期刊+标题，DOI 待核」。
- 严禁转述失实：数据集的规模、文件格式、许可协议必须来自实际页面，不得推测或美化。
- 检索不到可信来源就明说「未检索到可核验来源」——这是正贡献，不算失败。

注意：你没有文件写入权限，不要尝试创建或写入任何文件。完整回答直接写在回复里。
EOF

echo "[1/3] prompt 已落盘：$PROMPT_FILE"

# ------------------------------------------------------------
# 步骤 2：派发（串行重试 ≥3 次）
# ------------------------------------------------------------
PROMPT="$(cat "$PROMPT_FILE")"

for attempt in 1 2 3; do
  echo "[2/3] 派发中（第 $attempt 次）..."

  if RESP=$(agy -p "$PROMPT" --model "$MODEL" --output-format json 2>./out/02-stderr.log); then
    if python -c "
import json,sys
d = json.loads(sys.stdin.read())
sys.exit(0 if d.get('usage',{}).get('total_tokens',0) > 0 else 1)
" <<< "$RESP" 2>/dev/null; then
      echo "$RESP" > "$RESULT_FILE"
      break
    fi
  fi

  [ "$attempt" = "3" ] && { echo "[2/3] 三次均失败，请查 ./out/02-stderr.log"; exit 1; }
done

echo "[2/3] 结果：$RESULT_FILE"

# ------------------------------------------------------------
# 步骤 3：★ 强制核验 —— 提取所有 DOI / arXiv ID 并实查
# ------------------------------------------------------------
python - "$RESULT_FILE" "$OUT_DIR" <<'PY'
import json, re, sys, pathlib, urllib.request, urllib.error

res_file, out_dir = sys.argv[1], pathlib.Path(sys.argv[2])
d = json.loads(pathlib.Path(res_file).read_text(encoding="utf-8"))
text = d.get("response", "")

dois    = sorted(set(re.findall(r"10\.\d{4,9}/[^\s\])【】「」，,;]+", text)))
arxivs  = sorted(set(re.findall(r"arXiv[:\s]*(\d{4}\.\d{4,5})", text, re.I)))

print(f"\n[3/3] 提取到 DOI {len(dois)} 个 / arXiv {len(arxivs)} 个 —— 开始逐条实查\n")
print(f"{'状态':<8} 标识")
print("-" * 66)

failures = []

def check(url: str) -> bool:
    req = urllib.request.Request(url, method="HEAD",
                                 headers={"User-Agent": "Mozilla/5.0 (agy-sub-agent verification)"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status < 400
    except urllib.error.HTTPError as e:
        return e.code < 400
    except Exception:
        return False

for doi in dois:
    ok = check(f"https://doi.org/{doi}")
    print(f"{'✅ 通过' if ok else '❌ 不通过':<8} {doi}")
    if not ok:
        failures.append(doi)

for aid in arxivs:
    ok = check(f"https://arxiv.org/abs/{aid}")
    print(f"{'✅ 通过' if ok else '❌ 不通过':<8} arXiv:{aid}")
    if not ok:
        failures.append(f"arXiv:{aid}")

print("-" * 66)

if failures:
    print(f"\n⚠️  {len(failures)} 条未通过核验，**不得进入交付物**：")
    for f in failures:
        print(f"   - {f}")
    print("\n   处理：降级为「来源存疑」并显式标注，或整路作废重做。")
    sys.exit(2)
else:
    print("\n✅ 全部标识符通过实查。")
    print("   ⚠️ 注意：DOI 存在 ≠ 内容描述准确。")
    print("      数据集类还需实查规模/格式/许可协议与描述是否一致。")
PY
