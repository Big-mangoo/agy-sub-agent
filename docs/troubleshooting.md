# 排障手册

> 按症状查。所有条目均来自实测，非推测。

---

## 一、版本敏感性（先读这条）

`agy` 迭代较快，**默认值与 flag 行为会随版本变化**，网传资料常已过时。

> **遇到任何与本项目冲突的描述，第一动作是实查本机：**
> ```bash
> agy --version
> agy --help
> ```
> **以实列为准**，而非采信外部文档。

### 已确证的一处行为变更

| 版本 | headless 默认超时 |
|---|---|
| ≤ 1.2.5 | **5 分钟** |
| ≥ 1.2.6 | **不限时长**（`0 waits until the turn completes`） |

**这意味着**：网上大量资料写的"默认 5 分钟"**只对旧版本成立**。在本机新版本上照搬该结论会产生误判。

**通用教训**：外部反馈需要**先核验其所述版本是否等于你的版本**，再决定是否照办。否则可能把"已经更好的行为"降级为"更差的行为"。

---

## 二、症状速查表

| 症状 | 可能原因 | 处理 |
|---|---|---|
| `Eligibility check failed ... Bad Gateway` | 未配置代理环境变量 | 设置 `HTTPS_PROXY` / `HTTP_PROXY`（见 §三） |
| **无输出、命令挂起**（不是快速失败） | 未认证 | 首次需交互式运行 `agy` 完成登录；再查 `~/.gemini/antigravity-cli/log/cli-*.log` |
| 返回成功但 `total_tokens = 0` | 超时截断（误传了 `--print-timeout`） | **不要传该参数**；按三层判据判为失败并重试 |
| `response` 为空字符串 | 权限被拒（headless 无法弹窗） | 见 §四 |
| `response` 停在 `Waiting for ... to conclude.` | 中间态 | 用 `--conversation <id>` 续接，要求输出最终产出 |
| 400 `INVALID_ARGUMENT`（`enum[0]: cannot be empty`） | 全局 MCP 状态缓存写冲突 | 串行 + **自动重试 ≥3 次**（见 §五） |
| 400 `only allowed for OBJECT type` | `--json-schema` 根节点是 `array` | 包一层对象：`{"items": [...]}` |
| 报错 `conflicts with --effort=…` | 同时传了 `--model <带effort的slug>` 和 `--effort` | 二选一：只用 slug，或 `--model <family> --effort high` |
| `invalid_args: ... must be an absolute path` | 给了相对路径 | 用绝对路径（见 [`permissions.md`](permissions.md) §5） |
| 声称"已创建"但目标路径无文件 | 幻觉 / 写到了自己的 `scratch/` | **磁盘回检**，不采信自述 |
| 明明没执行，却报成功 | 见 [`verification.md`](verification.md) §3 | 三层判据 |

---

## 三、网络与代理

**`agy` 只读取环境变量代理，不读系统代理设置。**

```bash
export HTTPS_PROXY=http://127.0.0.1:7890
export HTTP_PROXY=http://127.0.0.1:7890
```

端口按你的实际代理调整。

### 网络层自检

```bash
curl -X POST https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
```

返回 **401 / 404 = 网络通**（仅缺认证头）。

---

## 四、权限被拒 → 整体空回复

**症状**：

- `status: "SUCCESS"`、`exit code: 0`、`total_tokens > 0`
- **`response` 为空字符串**
- `denied_actions` 非空
- stderr 出现 `no output produced — a tool required the ... permission ... auto-denied`
- **计费照扣**（实测一次 20 万 token）

**成因**：headless 模式无法弹出授权提示，任何未授权动作被自动拒绝，导致整个回合无产出。

**处理分两路**：

| 场景 | 处理 |
|---|---|
| 任务只需文本 | prompt 中显式声明：「你没有文件写入权限，不要尝试创建/写入/运行任何文件；完整内容以文本形式写入回复」→ 重派 |
| 任务确需写盘 | 精确授权 `write_file(<目录>/)`（**不要**用 `--dangerously-skip-permissions`） |

> ⚠️ **反面提醒**：空回复**也可能是假失败** —— 有副作用的步骤可能**已经执行**了。
> **一律在系统层回检**（`ls` / `test -f` / `git status`）。

---

## 五、偶发 400：必须重试

**症状**：

```
400 INVALID_ARGUMENT
tools[…].properties[period].enum[0]: cannot be empty
retryable: false
```

**成因**：全局 MCP 状态缓存写冲突 → 残缺的工具 schema。

**关键性质**：

| 认知 | 是否正确 |
|---|---|
| "只要串行就不会发生" | ❌ 严格串行下实测 14 次仍有 3 次命中（约 8%） |
| "`retryable: false` 所以不能重试" | ❌ 该字段只表示"同一请求原样重发无意义"，**新建进程重跑可自愈** |
| "隔离工作目录可规避" | ❌ 竞态在全局缓存层，与工作目录无关 |

**处理**：**串行执行 + 失败自动重试 ≥3 次**。

---

## 六、冷启动与慢启动

### 插件 MCP 就绪等待

headless 冷启动需要等待插件 MCP 就绪。**若某个 MCP 起不来，会拖几分钟。**

**建议**：宁可**本地安装固化**，不要在派发路径上使用 `npx` 型命令（常因网络问题卡死）。

### 未认证时挂起

未认证时 `agy -p` 会**挂起**，而不是快速失败。

**处理**：超时被杀且无输出时，检查最新的日志文件：

```
~/.gemini/antigravity-cli/log/cli-*.log
```

---

## 七、配置文件的坑

### `config.json` 与 IDE 共享

```
~/.gemini/config/config.json
```

改动会**同时影响 Antigravity IDE** 的行为。**改前务必备份。**

### `settings.json` 会被改写

`agy` 运行时会**规范化重写** `~/.gemini/antigravity-cli/settings.json`（键序变化）。

⚠️ **空数组 `"allow": []` 会被整体丢弃**（`permissions` 键消失），导致后续规则**静默失效**。

⇒ **不要留空 allow；手改后务必复核文件内容。**

---

## 八、成本异常

**被拒的轮次同样计费。** 实测单次范围 **3.0 万 ～ 18.2 万 token**。

**参考量级**：

| 场景 | 输入 token |
|---|---|
| 常规短任务 | ≈ 28.7k（系统提示 + 插件注入的固定开销） |
| 重任务单次 | 12 – 18 万 |
| subagent 多路任务 | 可达 70 万+ |

**建议**：

1. **派真任务前先做最低成本的桩验证** —— 一句极短指令确认权限/连通性已就绪。
2. **只派值得付这个底价的重任务** —— 任务过小时收益不抵成本。

---

## 九、故障排查顺序

```
1. 命令挂起 / 无输出？
   → 检查认证状态、查看 cli-*.log

2. 网络错误？
   → 检查 HTTPS_PROXY / HTTP_PROXY 环境变量

3. status=SUCCESS 但结果不对？
   → 按三层判据核验（verification.md）
   → 先看 total_tokens 是否为 0

4. response 为空？
   → 检查 denied_actions 与 stderr
   → 若为权限所致，按 §四 处理
   → 同时系统层回检，排除"假失败"

5. 结果看着对？
   → 仍要核验来源真实性（尤其检索类）
   → 有副作用的操作必须在系统层确认
```

---

## 十、反馈与贡献

若你遇到本手册未覆盖的问题，欢迎提交：

1. **可复现的实验条件**（`agy --version`、完整命令、观测结果）
2. **区分实测与推测** —— 猜测请明确标注为猜测

版本升级后，建议重跑一次 `agy --help` 并核对本项目描述是否仍然成立。
