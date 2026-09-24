---
name: agy-sub-agent
description: Delegate a self-contained subtask to Antigravity (official `agy` CLI, headless) and retrieve a structured JSON result. Use when you need an independent second opinion, cross-vendor verification, web research, standalone script generation, or delegated analysis. Includes capability boundaries, least-privilege authorization, and a three-layer success criteria. 把自包含子任务外派给 Antigravity CLI（agy headless）并取回结构化结果；含能力边界、最小授权与三层成功判据。
---

# agy-sub-agent：把任务外派给 Antigravity CLI

> **性质**：`agy` 是**委派通道**，不是模型参数取值。它承接**可独立打包、可独立验收**的子任务。
> **优势**：免费层 $0/月；独立进程执行、不占用调用方上下文；跨厂商视角，适合做第二意见。
> **实测基线**：`agy` **1.2.9**。CLI 迭代较快，默认值会变 —— **与本文件冲突时以 `agy --help` 实列为准**。
> **红线**：本项目对本地文件**只做「读取 + 创建 + 修改」，不做删除**（见 §2.5③）。

---

## 一、怎么派任务

### 1.1 标准调用

```bash
# 受限网络环境（如中国大陆）需要：agy 只读环境变量代理，不读系统代理
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890

agy \
  -p "<自包含任务描述>" \
  --model gemini-3.8-flash-high \
  --output-format json
```

**四条硬要求**：

| # | 要求 | 说明 / 违反后果 |
|---|---|---|
| 1 | **受限网络环境必须带代理环境变量** | `agy` 只读环境变量代理 → 不通时表现为 `Eligibility check failed ... Bad Gateway` 或直接挂起 |
| 2 | **不要传 `--print-timeout`** | 默认即不限时长（`--help`：`0 waits until the turn completes`）。传非零值会截断长任务并产生「假成功」。挂死兜底 = 调用方自身超时 |
| 3 | **失败必须自动重试**（同一任务串行重试 ≥3 次） | 偶发 400（历史观测约 8%）—— 串行只降低概率、不免疫。不重试会把偶发失败误判为"通道报废" |
| 4 | **并发用「进程内 subagent」** | 外部多进程并行有概率性失败（见 §四） |

### 1.2 参数要点

| 参数 | 说明 |
|---|---|
| `--model <slug>` | 推荐 `gemini-3.8-flash-high`。⚠️ slug 已内嵌 effort，**不要再传 `--effort`**（报错 `conflicts with --effort=…`）。要单独控 effort：`--model gemini-3.8-flash --effort high` |
| `--output-format json` | 结构化返回（含 `structured_output` 字段，见 §3.2） |
| `--print-timeout` | **不要传**（默认 0 = 不限时长） |
| `--conversation <id>` / `-c` | 续接会话（用于取回中间态任务的最终产出，见 §3.1） |
| `--json-schema <schema>` | 强制结构化输出。**根节点必须是 OBJECT**（根级 `array` 直接 400） |
| `--add-dir <dir>` | 纳入工作区（可重复）—— 见 §2.8③，临时任务最简授权方式 |

其他见附录 B。

### 1.3 prompt 写法（决定成败）

子代理**看不到调用方的会话上下文** —— 写 prompt 时假定对方是刚进房间的同事：

1. **给全背景**：任务来源、范围、验收标准。
2. **给明确输出格式**（多段任务尤其重要，否则结构会散）：
   ```
   输出格式：§0 说明（列出实际使用的方法/检索式）／§1 核心发现（每条含名称+来源标题+URL）／§2 一句话结论。用 markdown。
   ```
3. **明确禁止项**：如"不要读写任何本地文件，只在最终回复给出正文"。
4. **多段产出必须写明段数与条数** —— 否则可能只给汇总项或提前收尾。
5. 需要文件内容时**优先把内容贴进 prompt**；成规模的文件/目录按 §2.2 授权让它自读。
6. **任务只需返回文本时，显式声明权限边界**：「你没有文件写入权限，不要尝试创建/写入/运行任何文件；完整内容以文本形式写入回复」—— 否则它会尝试写盘/跑命令 → headless 下被自动拒 → **主回合交空回复**（计费照扣、零产出，实测一次 20 万 token）。见附录 C-8。
7. **第二意见/评审类任务：先写下我方意见，再派发** —— prompt 中不得含我方任何判断（保证独立作答），交付后两栏对比。「我方意见在派出前独立写下」是独立性可审计的关键（prompt 文件可回查）。

> **不值得派**：任务小但上下文大（每轮 ≈28.7k 固定输入开销）；依赖调用方会话隐式共识（摘要必丢关键约束，它给的结论**比不派更危险**）；含非公开信息（须先询问用户，见 §2.7）。

---

## 二、能力边界与授权

### 2.1 默认能做什么

| 能力 | 状态 |
|---|---|
| **联网搜索** | ✅ 稳定可用 —— 外派的主要价值 |
| **加载 Agent Skills** | ✅ 可用 —— 技能清单自动注入，**可在 prompt 中点名技能指导工作**（见 §2.3）。⚠️ 技能内的 `command`/写盘步骤仍需 §2.2 授权 |
| 输出长度 | ✅ 单次数万字符无压力 |
| 读取工作目录内文件 | ⚠️ 需授权：`--add-dir <目录>` 或 `read_file(<目录>/)` |
| **创建 / 修改文件** | ⚠️ 需授权，但**授权后确实能写**（见 §2.8） |
| **删除文件** | 🚫 **本项目不做**（红线）—— 见 §2.5③ |
| 读取工作目录外文件 | ❌ 需 `read_file` 授权 |
| 抓取网页正文 | ❌ 需 `read_url` —— **能搜索、默认抓不了正文** |
| 执行 shell 命令 | ❌ 需 `command` 授权 |

**结论**：**纯联网检索/分析类任务可直接派**；涉及本地文件的按 §2.2 授权后派。**只做「读取 + 创建 + 修改」，不做删除。**

### 2.2 需要授权时：按目录最小授权

配置：`~/.gemini/config/config.json` → `userSettings.globalPermissionGrants.allow`

| 权限类型 | 规则写法 | 粒度 |
|---|---|---|
| `read_file` | `read_file(/path/to/data/)` | **目录级**（末尾斜杠）／文件级 `read_file(/path/to/file.md)` |
| `write_file` | `write_file(/path/to/out/)` | 同上 |
| `read_url` | `read_url(https://example.com/page)` | 精确 URL |
| `command` | `command(git)` 或 `command(regex:<模式>)` | 见 §2.5 |

**操作步骤**：

```bash
# 1) 先备份（该文件与 Antigravity IDE 共享，改动会同时影响 IDE）
cp ~/.gemini/config/config.json ~/.gemini/config/config.json.bak-$(date +%Y%m%d)

# 2) 用 Python 追加规则（保证 JSON 合法）
python -c "
import json, pathlib
p = pathlib.Path.home() / '.gemini/config/config.json'
c = json.loads(p.read_text(encoding='utf-8'))
a = c['userSettings']['globalPermissionGrants']['allow']
r = 'read_file(/path/to/data/)'
if r not in a:
    a.append(r)
    p.write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding='utf-8')
print(a)"
```

**要点**：

1. **通配符无效** —— `read_file(/dir/*)` / `**` 都被拒；**目录级一律用末尾斜杠**。
2. **不要用 `--dangerously-skip-permissions`** —— 全权限放开（不限目录）。
3. **被拒时照抄报错格式** —— 报错会给出权限类型与建议写法：
   ```
   Add an allow-rule under permissions.allow in settings.json (e.g. write_file(<target>))
   ```

**推荐形态**：只授输入目录 + 一个专用输出目录（`read_file(/path/to/data/)` + `write_file(/path/to/data/_transfer/)`）。

### 2.3 用技能指导工作（Agent Skills）

`agy` 会加载已安装插件中的技能。**派任务时在 prompt 中点名技能**，它会按该技能的工作流执行 —— 这是让外派任务"按你的规范做"的主要手段。

**查看你这边有哪些技能可用**：

```bash
# 技能来自插件目录（不是 CLI 自己的目录）
ls ~/.gemini/config/plugins/*/skills/
```

**调用方式**：在 prompt 里点名 + 说明用途：

```
请使用 <技能名> 技能的方法论完成以下任务：……
```

**⚠️ 三个必须知道的边界**：

1. **技能可用 ≠ 技能里的命令能跑** —— 技能**被加载/被读取**无需授权；但技能内部的 `command`／写盘步骤**仍受 §2.2 权限约束**（技能内容不会自动获得权限）。任务需要技能内的命令步骤时，必须在 prompt 里显式声明边界，或先按 §2.2 授权。
2. **`agy plugin list` 的判断会误导** —— 它只列 `agy plugin import` 迁入的插件，**不列**手工放入 `~/.gemini/config/plugins/` 的。输出「无」不代表技能不可用。
3. **`agy mcp list` 同样误导** —— 它只列 CLI 级 MCP；**插件级**（`~/.gemini/config/plugins/{插件}/mcp_config.json`）的服务器不在此列。判断插件级 MCP 是否生效，应直接查该文件并在任务中实测。

**技能来源**：`~/.gemini/config/plugins/{插件名}/skills/*/SKILL.md`
⚠️ **不是** `~/.gemini/antigravity-cli/skills/` —— 官方文档写的该路径在部分版本**不存在**，不要照文档路径去找。

### 2.4 不要做的事

| 做法 | 为什么 |
|---|---|
| `--dangerously-skip-permissions` | 全权限放开（读/写/命令，不限目录） |
| **授权删除类命令**（`rm` / `Remove-Item` / `del` / `shutil.rmtree` 等） | 🔴 **红线**：删除不可逆，且存在「已真删但回复为空」的假失败 —— 详见 §2.5③ |
| 把 `--mode plan` 当"只出方案"的保险 | ❌ 不保险：它会把写入重定向到自己 `scratch/` 执行，且**幻觉声称"已完成创建并校验"** |

### 2.5 shell 命令执行能力（🚫 删除一律禁止）

**定位**：本项目对文件**只做「读取 + 创建 + 修改」，不做删除**。shell 能力仅用于**创建/修改的辅助环节**（编译、跑测试、格式检查）。

**① 授权写法（两种，实测均有效）** —— 仅适用于创建/修改的辅助命令：

| 形式 | 写法 | 说明 |
|---|---|---|
| **精确串** | `command(git)` | 命令串需完全匹配（或按前缀） |
| **正则** | `command(regex:<模式>)` | 按命令串正则匹配；**写具体、避免 `.*` 泛匹配** |

**② 作用域按模式强制**：一个命令模式 **≠** 开放整个 shell —— 只授命令 A 时，它跑未授权的命令 B 会被**拒绝**。

**③ 🚫 删除红线（硬约束）**

**不做、不授权、不派发任何删除类操作。** 包括但不限于 `rm` / `rmdir` / `del` / `Remove-Item` / `shutil.rmtree` / `Move-Item`（覆盖语义）等。

**为什么设为红线（实测依据）**：

1. **删除走 shell，而 `command(regex:…)` 只匹配命令串、完全没有路径感知** —— 实测未锚定的 `command(regex:.*Remove-Item.*)` **成功删掉了授权目录之外的文件**。**正则只是减速带、不是安全边界。**
2. **存在「已真删但回复为空」的假失败**（见 ④）—— 调用方会误判"没执行"，而文件已经没了。
3. **删除不可逆**，风险与收益严重不成比例。

**确实需要删除时**：由**调用方在本地执行**，或改用**作用域受限、可追溯的专用工具**。**本通道不代理删除。**

**④ 通用教训：空回复 ≠ 失败（操作可能已执行）**

实测：某步骤**成功执行**，但紧随其后的**自检命令**不在 allow 内 → 被拒 → **整个回合返回空 `response`**。调用方据空回复会误判"什么都没发生"。

⇒ **任何有副作用的操作，成败一律由调用方在系统层核验**（`ls` / `test -f` / `git status`），**不采信回复** —— 空回复既不等于失败，也不等于成功。

### 2.6 权限审计口径

**权限面 ≠ 工具名白名单**，审计应按「**可达数据域 + 可达执行能力**」核算：

```
可达面 = 显式 allow 的等价能力
       ∪  每个已授权 MCP 的数据根（乘以其读写删等动作面）
       ∪  unsandboxed 条目
       ∪  受信工作区 / 工程资源目录
```

- **授权一个 MCP ≈ 间接放开该 MCP 的数据根** —— 例：授权 `mcp(.../read_note)` 而该 server 以某目录为数据根 ⇒ **`read_file` 被拒 ≠ 该目录内容不可达**。
- 🔴 **`mcp(.../execute_command)` 等价于放开任意命令执行** —— 绕过直接 `command` 的拒绝，**风险高于文件读写授权**，须定期复核是否仍为必需。（实测取证：此类 server 常实现为 `subprocess.run(cmd, shell=True)` + 无命令白名单。）

### 2.7 派发前先问用户的三种情形

命中任一 → **先说明具体风险 → 询问用户是否外派 → 按答复执行**；**三者皆不命中 → 直接派发**：

| # | 情形 |
|---|---|
| ① | 内容含**非公开信息**（他人数据、凭据密钥、内部资料、未公开数据） |
| ② | 需**读取本地文件或写入产物**（涉及放开权限） |
| ③ | 预估**收益不抵成本**（每轮 ≈28.7k 固定开销、任务过小） |

> 另有两类属**效果问题**（不是规则限制，派了也没用）：依赖调用方会话隐式共识；任务极简而上下文极大。

### 2.8 本地文件：读取 / 创建 / 修改（🚫 不含删除）

**结论速查**：

| 操作 | 能否 | 工具 | 前置条件 |
|---|---|---|---|
| **读取** | ✅ | `view_file` | 目录在 `--add-dir` 或 `permissions.allow` 内 |
| **创建** | ✅ | `write_to_file` | 同上 |
| **修改（全量覆写）** | ✅ | `write_to_file` | 同上 |
| **修改（局部编辑）** | ✅ | `replace_file_content` | 同上 |
| **删除** | 🚫 **不做** | — | 红线，见 §2.5③ |

**① 原生文件工具**：`view_file`（读）／`write_to_file`（新建 + 全量覆写）／`replace_file_content`（局部编辑）。
**不存在 `delete` / `delete_file`** —— 原生层面就没有删除能力。⚠️ 技术上可绕过（走 shell），但**本项目禁用**。

**② 两条授权路径（均实测有效，任选其一）**

| 路径 | 键位 | 性质 |
|---|---|---|
| `~/.gemini/config/config.json` | `userSettings.globalPermissionGrants.allow` | 与 IDE 共享的 schema（§2.2 写法，对 CLI 同样生效） |
| `~/.gemini/antigravity-cli/settings.json` | `permissions.allow` | CLI 专属 schema —— 被拒时的报错指向它 |

**③ 最简授权：`--add-dir`（无需改配置文件）**

实测：清空所有 allow 规则后，仅加 `--add-dir <目录>`，即在该目录内成功创建文件。**临时任务优先用它**，避免动共享配置。

**④ 三个必须注意的坑**

1. **权限动作名 ≠ 工具名** —— 工具叫 `write_to_file`，但**规则里必须写 `write_file`**：
   ```
   write_file(/path/to/dir/)     ✅ 前斜杠 + 末尾斜杠
   ```
   写成 `write_to_file(...)` 不生效。
2. **必须给绝对路径** —— 相对路径被前置校验直接拒（`invalid_args: … must be an absolute path`）；且它的「当前目录」= 受信工作区根，**不是调用方 shell 的 cwd**。⇒ **派单时在 prompt 里写死绝对路径**，否则它会写到工作区根或自己的 `scratch/` 下。
3. **`agy` 会改写 `settings.json`** —— 实测一次运行后该文件被规范化重写。⚠️ **空数组 `"allow": []` 会被整体丢弃**，导致后续规则静默失效。**不要留空 allow；手改后务必复核文件内容。**

**⑤ 失败探测很贵** —— 被拒的轮次同样计费：实测单次 **3.0 万 ～ 18.2 万 token**。⇒ **派真任务前先做一次最低成本的桩验证**（用一句极短指令确认权限已生效），再投入重任务。

**⑥ 事后必做磁盘回检** —— 它会**声称**"已成功创建"，也可能把写入静默重定向到自己的 `scratch/`。**判成功一律以 `ls` / `cat` 目标绝对路径为准**。有副作用的操作尤甚（见 §2.5④）。

---

## 三、拿回结果后必做

### 3.1 三层成功判据

**不可只看 `status` / 退出码** —— 失败时它们同样返回 `SUCCESS` / `0`。

| 层 | 检查什么 | 判据 |
|---|---|---|
| **① 调用层（硬信号）** | 模型**真的跑过**吗 | **`usage.total_tokens > 0`** —— 唯一硬指纹；等于 0 即未真正执行（超时、异常均如此） |
| **② 交付层（完备性）** | 要求的东西**真的给全**了吗 | 要求的 N 段/结论**全部出现**。⚠️ 判据是「**含中间态字样 ∧ 要求的最终产出未出现**」—— **只见 `Waiting for…` 不等于失败**（可能同段既有 Waiting 又有最终结果）。⚠️ 另一种更彻底的层②失败是「**被拒空回复**」：硬信号全过但 `response` 为空串，见附录 C-8 |
| **③ 内容层（真实性）** | 给的东西**对吗、完整吗** | **围栏成对 + 末句完整**（⚠️ **括号配对不足以判定截断**）+ 来源核验（见 §3.3） |

**辅助信号（均不可单独作准）**：`response` 非空、`num_turns > 0`。

**失败补救**：
- ① 不通过 → **串行重试**（≥3 次）
- ② 不通过 → 用 **`--conversation <id>` 续接**，要求它输出最终产出
- ③ 不通过 → 重派，或降级为「部分交付」并**显式标注**

> **续接的语义（重要）**：续接**不是"取回子代理结果"** —— 子代理不跨进程存活，进程退出后已被停止。续接是让主 agent **自行重做/继续产出**。

### 3.2 结构化输出的解析顺序（`--json-schema`）

**优先读 `structured_output`** —— CLI 外层字段，是**已解析好的合规 dict**（无 `toolAction` / `toolSummary` 等元字段）：

```python
d = json.loads(stdout)
result = d.get("structured_output") or json.loads(d["response"].strip().splitlines()[-1])
```

| 解析路径 | 说明 |
|---|---|
| ⭐ `structured_output` | **最优** —— 已解析、零元字段 |
| `response` **最后一行** | **稳妥兜底** —— `response` 形态**不固定**（可能是"正文+末行JSON"，也可能是单行纯 JSON），取最后一行在两种形态下都正确 |
| 整段 `json.loads(response)` | ❌ **不可依赖** —— 形态不定，可能因前导正文而失败 |

**另注**：`items` 条数**由 prompt 决定** —— 不显式要求"N 条"时可能只给 1 条汇总项，真实明细留在正文。

### 3.3 核验内容真实性

- 它会**声称未发生的事**（实测：自称"已完成创建并校验"，而目标路径无文件）。
- 凡涉及"已创建/已修改/已完成"的自述 → **一律实际核验**。
- 检索类结果**抽样复核来源** —— 但见下方专项，抽样不够。

#### ⚠️ 专项：文献/数据检索类任务的高失真率（必须逐条核验）

**实测数据**：一次文献检索任务中，产出报告**抽查 6 条来源 → 3 条不实（50%）**：

| # | 形态 | 细节 |
|---|---|---|
| ① | **DOI 根本不存在** | 两个声称的 IEEE 论文 DOI，检索系统中查无此物。**格式毫无破绽、卷期页齐全，纯属拼凑，肉眼无法分辨** |
| ② | **DOI 真实但内容被整体改写** | 一个真实存在的数据集 DOI：实为 135 KB 工程文件，被描述成「12,852 组时序 + 50 维特征 + 已清洗矩阵」；许可也从 CC0 写成 CC BY |
| ③ | 对照：其他通道全真 | 同任务改用其他模型，抽查 3/3 全部真实，数值细节与原文逐字吻合 |

**结论**：**幻觉的 DOI 无法凭肉眼分辨**。这不是"工具不好用"，而是**它的失败模式在检索类任务上特别隐蔽** —— 通道可用，但**不可不做核验直接用**。

**强制要求**：

1. **凡引用必逐条核**（检索类不适用"抽样复核"口径）—— 实查 `https://doi.org/<doi>` / `https://arxiv.org/abs/<id>`，**未通过实查的条目不得进入任何交付物**，只能降级为「来源存疑」并显式标注。
2. **禁止拼凑条款必须原文写进 prompt**（模板见下）。
3. **数据集类须实查规模/文件格式/许可协议**，不得采信转述。
4. **失真率不可接受 → 整路作废重做**（换其他模型或通道）。

**prompt 模板（照抄进检索类任务的 prompt 末尾）**：

```
来源纪律（强制）：
- 严禁拼凑 DOI：每一个 DOI 必须是你确实检索到并能确认字符级正确的；不能确认就不写 DOI，
  改写为「作者+年份+期刊+标题，DOI 待核」。
- 严禁转述失实：数据集的规模、文件格式、许可协议必须来自实际页面，不得推测或美化。
- 检索不到可信来源就明说「未检索到可核验来源」——这是正贡献，不算失败。
```

> **成本提示**：核验成本远低于返工成本 —— 若跳过核验，虚构来源会直接进入交付物。

- 结果并入交付时标注「**来源：agy 子代理通道**」，并按结论强度核对定级。

### 3.4 审计（可完整回溯）

| 路径 | 内容 |
|---|---|
| `~/.gemini/antigravity-cli/scratch/` | 默认工作目录（其自主产物落此，不污染调用方目录） |
| `~/.gemini/antigravity-cli/brain/<会话id>/` | `plan.md` / `walkthrough.md` |
| `~/.gemini/antigravity-cli/conversations/*.db` | **SQLite：每轮 prompt 原文 + 逐 step 工具调用 + 权限拒绝记录** |

```python
import sqlite3, pathlib

db = pathlib.Path.home() / ".gemini/antigravity-cli/conversations/<会话id>.db"
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
for idx, st, status, payload in con.execute(
        "SELECT idx, step_type, status, step_payload FROM steps ORDER BY idx"):
    print(idx, st, status, bytes(payload or b"")[:200])
```

**关键字段语义**：

| 项 | 含义 |
|---|---|
| `step_type=132` | **通用「工具调用」step**（载荷可能是 `invoke_subagent`、`search_web`、`run_command` 等） |
| `step_type=101` | **子代理/系统消息回传** —— 仅当主回合等到子代理回收时才出现在主库 ⇒「主库有无 N 条 101」可作**中间态的库层判据** |
| `step_type=14 / 15` | 用户输入 / 模型消息 |
| `status=7` + `error_details` | **被拒记录的落点** |

---

## 四、并发

**一句话**：**并发用「进程内 subagent」；外部多进程最多 2 路。**

| 方式 | 做法 | 结论 |
|---|---|---|
| **✅ 进程内 subagent（首选）** | 把可分解任务写进**一个** prompt，让它自己 fan out | 1 个进程内并行，**无状态竞态**、开销小、可审计。⚠️ 耗时较长（实测 3 路约 400s）—— 预估超过约 2 分钟时应考虑后台执行 |
| ⚠️ 外部多进程 | 同时启动多个 `agy` 进程 | **最多 2 路**；**≥3 路禁止** |
| ❌ 外部 ≥3 路 | —— | 概率性失败：**全局状态缓存写冲突** → 残缺工具 schema → 400 `INVALID_ARGUMENT`（`retryable:false`）；**隔离工作目录无法规避** |

```bash
# 进程内 subagent 示例
agy -p "请用 subagent 机制并行完成三个独立子任务后汇总：(1) …；(2) …；(3) …。最终用逗号分隔回答。"
```

**「确实 fan out」的可审计指纹**（纯凭自述不足以采信）：

- `conversations/` 下新增**多个 `.db`** —— 1 个主库 + 每个 subagent 一个独立子库
- 主库存在载荷含 **`invoke_subagent` + `Subagents` 数组**的 `type=132` step
- 子库各有**独立的工具调用轨迹**与各自的部署 prompt

> **注意**：受限的只是「多个 `agy` 进程同时跑」。**同一进程内的 fan out 与调用方自身的其他并行工作，是允许的。**

---

## 附录

### A. 返回字段

```json
{"conversation_id":"…","status":"SUCCESS|ERROR","response":"…","structured_output":{…},"json_schema":{…},
 "duration_seconds":N,"num_turns":1,
 "usage":{"input_tokens":N,"output_tokens":N,"thinking_tokens":N,"cache_read_tokens":N,"total_tokens":N},
 "denied_actions":[{"action":"read_file|write_file|command|read_url","display_name":"…"}]}
```

- `status=ERROR` → 看 `error` 字段；stderr 有诊断详情（stdout 干净）
- 出现 `denied_actions` → 按 §2.2 补授权后重派

### B. 其他 flag

`--add-dir <dir>`（可重复）· `--json-schema <schema>` · `--input-format stream-json`（stdin 逐行灌 NDJSON，每行一 turn）· `--agent <名称>` · `--sandbox`（终端受限）
子命令：`agy models` 列模型 · `agy agents` 列 agent · `agy mcp list` 看 CLI 级 MCP

### C. 已知坑

0. **版本敏感**：`agy` 迭代快、**默认值会变**，网传资料多已过时。**与本文件冲突时以 `agy --help` 实列为准**；升级后重跑一次 `--help` 核对 §1.1 四条硬要求。（已确证一处变更：headless 默认超时 ≤1.2.5 为 5 分钟 → 1.2.6 起不限时长）
1. **headless 冷启动要等插件 MCP 就绪**。若某 MCP 起不来会拖几分钟 —— 宁可本地安装固化，不要在派发路径上用 `npx` 型命令（常因网络卡死）。
2. **未认证时 `agy -p` 会挂起**（不是快速失败）。超时被杀且无输出时，先查 `~/.gemini/antigravity-cli/log/cli-*.log` 最新文件。
3. **网络层自检**：`POST https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` 经代理返回 401/404 = 网络通（仅缺认证头）。
4. **`config.json` 与 Antigravity IDE 共享** —— 改插件开关或权限都会影响 IDE，改前备份。
5. **偶发 400 `INVALID_ARGUMENT`**（`tools[…].properties[period].enum[0]: cannot be empty`，`retryable:false`）：源于全局状态缓存写冲突，**串行也会偶发**（历史约 8%）⇒ 必须自动重试（§1.1 第 3 条）。
6. **`--print-timeout` 超时「假成功」**（仅误传非零值时出现）：`total_tokens=0`，但 `status=SUCCESS` + `exit=0` ⇒ 判失败。**不要传该参数**。
7. **`--json-schema` 根节点必须 OBJECT**（根级 `array` → 400 `only allowed for OBJECT type`）；输出会附加 schema 未声明的元字段（**优先读 `structured_output` 可避开**，见 §3.2）。
8. **headless 权限被拒 → 整体空回复**：prompt 要求写文件/跑命令时，headless 无法弹授权 → 该动作被自动拒绝（`denied_actions` 非空；stderr 出现 `no output produced — a tool required the ... permission … auto-denied`），此时 `status=SUCCESS`、`total_tokens>0`、`exit=0` **硬信号全过，但 `response` 为空串**、计费照扣。补救分两路：①**只需文本** → 在 prompt 显式声明「你没有文件写入权限，不要尝试创建/写入/运行任何文件」，重派（实测重派 1 次即恢复）；②**确需写盘** → 按 §2.2/§2.8 精确授权 `write_file(<目录>/)`（**不要**用 `--dangerously-skip-permissions`）。**不要**为删除类需求授权 `command(...)`（§2.5③）。⚠️ 注意「空回复」也可能是**假失败**（§2.5④），务必系统层回检。

### D. 账号、额度与模型

- **免费层**：Individual $0/月、无需信用卡；额度为「basic weekly rate limits」（按周刷新）；Gemini 系共享配额池，Claude 系独立限额
- **不支持** BYOK / 自备端点；模型清单随账号变化，**以 `agy models` 实列为准**
- **模型选型**：推荐 `gemini-3.8-flash-high`。同池其他模型（`gemini-3.7/3.6-flash`、`gemini-3.1-pro`、`claude-*`）**能力档位低于前者**，用于强推理/高精度裁决前须先评估是否够用
- **成本**：常规短任务每轮 ≈28.7k 固定输入开销（系统提示 + 插件注入）；**重任务单次 input 可达 12–18 万**，subagent 多路任务可达 **70 万+** —— **只派值得付这个底价的重任务**
- **时效风险**：免费层属重定价风险项，具体限额数值不可视为恒定

### E. 不适用场景

需要任务出现在 **Antigravity IDE 窗口会话**里的，不属于本通道。
