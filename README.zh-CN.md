# agy-sub-agent

> 把任务外派给 Antigravity CLI，作为一个**独立的子代理通道**使用。
> 与具体客户端、框架、编排系统无关 —— 任何能执行 shell 的软件或 agent 都可以调用。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-compatible-blue.svg)](SKILL.md)

[English](README.md) · **简体中文**

---

## 这是什么

[Antigravity](https://antigravity.google/) 是 Google 推出的 AI 编码助手，提供官方命令行工具 `agy`，支持 headless（非交互）运行。

本项目把它当作**子代理通道**使用：将可独立打包、可独立验收的子任务外派给 `agy` 执行，取回结构化 JSON 结果。

```
你的主程序 / 主 Agent
        │
        │  外派子任务（自包含 prompt）
        ▼
   agy 子代理进程  ──→  独立执行（检索 / 编码 / 分析 / 评审）
        │
        │  JSON 结果（含 usage、conversation_id、denied_actions）
        ▼
   调用方核验  ──→  并入交付
```

## 为什么用

| 价值 | 说明 |
|---|---|
| **零成本算力** | Individual 免费层 $0/月，无需绑定信用卡 |
| **不占用主上下文** | 子任务在独立进程内完成，主 Agent 只接收结果 |
| **跨厂商独立性** | Gemini 系模型视角，适合做**第二意见**与交叉验证 |
| **可并行** | 与主 Agent 的其他工作并行；单进程内还可 fan out 多个 subagent |

## 快速开始

### 1. 安装与登录

```bash
# 按官方指引安装 agy CLI，然后首次需交互式登录一次
agy
```

### 2. 派发任务

```bash
agy -p "<自包含任务描述>" \
  --model gemini-3.8-flash-high \
  --output-format json
```

### 3. 解析结果

```python
import json, subprocess

out = subprocess.run(
    ["agy", "-p", prompt, "--model", "gemini-3.8-flash-high", "--output-format", "json"],
    capture_output=True, text=True,
).stdout

d = json.loads(out)

# 唯一硬信号：模型真的跑过
assert d["usage"]["total_tokens"] > 0, "未真正执行"

# 优先读已解析的结构化字段，兜底取 response 最后一行
result = d.get("structured_output") or json.loads(d["response"].strip().splitlines()[-1])
```

## 四条硬要求

> 这四条是本项目最主要的经验浓缩。违反任一条都会导致难以诊断的失败。

| # | 要求 | 违反了会怎样 |
|---|---|---|
| 1 | **受限网络环境必须配置代理** | `agy` 只读**环境变量**代理，不读系统代理 → 请求失败或直接挂起 |
| 2 | **不要传 `--print-timeout`** | 默认即"不限时长"；显式设非零值会截断长任务，并产生"状态成功但实际未完成"的假成功 |
| 3 | **失败必须自动重试（串行 ≥3 次）** | 历史上存在约 8% 的偶发失败 → 不重试会把偶发问题误判为"通道不可用" |
| 4 | **并发用「进程内 subagent」** | 外部多进程并行 ≥3 路会因状态竞争概率性失败，且隔离工作目录无法规避 |

详见 [`docs/`](docs/)。

## 能力边界速查

| 能力 | 默认状态 |
|---|---|
| 联网搜索 | ✅ 稳定可用 —— 外派的主要价值 |
| 加载 Agent Skills | ✅ 可用（加载与读取不需授权） |
| 长文本输出 | ✅ 单次数万字符无压力 |
| 读取 / 创建 / 修改本地文件 | ⚠️ **需授权**（目录级最小授权，见 [`docs/permissions.md`](docs/permissions.md)） |
| 抓取网页正文 | ❌ 需 `read_url` 授权 ——**能搜索、默认抓不了正文** |
| 执行 shell 命令 | ❌ 需 `command` 授权（**本项目不建议用于删除类操作**） |

## 结果验收：三层判据

**不可只看 `status` / 退出码** —— 执行失败时它们同样返回 `SUCCESS` / `0`。

| 层 | 检查什么 | 判据 |
|---|---|---|
| **① 调用层** | 模型真的跑过吗 | `usage.total_tokens > 0` —— 唯一硬指纹 |
| **② 交付层** | 要求的内容给全了吗 | 要求的 N 段/结论全部出现；注意"中间态"（停在 `Waiting for…` 且最终产出缺失） |
| **③ 内容层** | 给的东西对吗 | 结构完整 + **来源核验** |

## ⚠️ 最重要的警示：检索类任务必须逐条核验

实测数据（详见 [`EVIDENCE.md`](EVIDENCE.md)）：在一次文献检索任务中**抽查 6 条来源，3 条不实**——

- **2 个 DOI 在检索系统中根本不存在**，但格式完整、卷期页齐备，**肉眼无法分辨**；
- **1 个 DOI 真实存在，但内容描述被整体改写**（数据集规模、文件格式、许可协议全部不符）。

**结论**：这不是"工具不好用"，而是**它的失败模式在检索类任务上特别隐蔽**。通道可用，但**不可不做核验直接用**。

凡涉及引用，必须按下述纪律执行：

1. **凡引用必逐条核**（检索类不适用抽样口径）—— 实查 `https://doi.org/<doi>`、`https://arxiv.org/abs/<id>`；
2. **把禁止拼凑条款原文写进 prompt**（模板见 [`docs/verification.md`](docs/verification.md)）；
3. **数据集类须实查规模 / 格式 / 许可**，不得采信转述；
4. **核验后不可接受 → 整路作废重做**，换用其他模型或通道。

## 接入方式（与客户端无关）

本项目提供多种接入形式，按你使用的工具选择：

| 形式 | 文件 | 适用 |
|---|---|---|
| **Agent Skill** | [`SKILL.md`](SKILL.md) | 支持 Agent Skills 规范的 AI 编程工具 —— 放进 skills 目录即可被自动加载 |
| **Agent 指令** | [`AGENTS.md`](AGENTS.md) | 支持 `AGENTS.md` 约定的工具 —— 作为项目级指令被读取 |
| **Shell 脚本** | [`examples/`](examples/) | 任何能执行命令的软件、CI、调度系统 |
| **Python 封装** | [`examples/call_agy.py`](examples/call_agy.py) | 程序化调用、集成进已有流水线 |

> 本项目的设计与任何特定客户端、编排框架、专家系统解耦。你只需要能执行一条命令。

## 项目结构

```
agy-sub-agent/
├── README.md                     # English（GitHub 默认展示）
├── README.zh-CN.md               # 本文件
├── CONTRIBUTING.md               # 贡献规范
├── SKILL.md                      # Agent Skills 规范格式（通用技能文件）
├── AGENTS.md                     # AGENTS.md 约定格式
├── EVIDENCE.md                   # 实测证据与数据（结论的可追溯来源）
├── LICENSE
├── docs/
│   ├── permissions.md            # 权限模型与本地文件操作
│   ├── verification.md           # 结果验收与内容核验
│   ├── concurrency.md            # 并发策略
│   └── troubleshooting.md        # 排障手册
└── examples/
    ├── 01-second-opinion.sh      # 第二意见（独立性可审计）
    ├── 02-research-task.sh       # 检索类任务（含防造假 prompt 模板）
    ├── 03-code-task.sh           # 编码类任务
    ├── 04-parallel-fanout.sh     # 进程内并行 fan out
    └── call_agy.py               # Python 封装
```

## 设计原则

1. **可独立打包、可独立验收** —— 只外派满足这两条的子任务。
2. **prompt 必须自包含** —— 子代理看不到调用方的会话上下文。
3. **不采信自述，只认核验** —— 有副作用的操作一律在磁盘/系统层回检。
4. **删除类操作不做** —— 不可逆且失败模式隐蔽，风险与收益不成比例。
5. **结论标注来源** —— 外派结果并入交付时应明确标注来源通道。

## 版本敏感性

`agy` 迭代较快，**默认值与 flag 行为会随版本变化**，网传资料常已过时。

遇到任何与本项目描述冲突的情况，**以 `agy --version` + `agy --help` 实列为准**，并欢迎提 PR 更新本项目。

> 本项目记录基于 `agy` **1.2.9**。已确证的一处行为变更：headless 默认超时在 ≤1.2.5 为 5 分钟，**1.2.6 起改为不限时长**。

## 贡献

欢迎补充新的实测数据、失败模式、平台差异 —— 完整规范见 **[CONTRIBUTING.md](CONTRIBUTING.md)**。

简要要求：

- 在 [`EVIDENCE.md`](EVIDENCE.md) 中记录**可复现的实验条件**（版本号、命令、观测结果），而不仅是结论；
- 区分**实测**与**推测**；
- 先核对 `agy --version` —— 行为随版本变化。

> Issue 与 PR 可用中文或英文提交，均欢迎。

## 许可

[MIT](LICENSE)
