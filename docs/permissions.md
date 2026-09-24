# 权限模型与本地文件操作

> 本文覆盖：默认能力边界、最小授权写法、shell 命令授权、删除红线、权限审计口径，以及本地文件读写的实测结论。

---

## 一、默认能力边界

`agy` 在 headless 模式下**不会弹出授权提示**。任何未预先授权的能力，都会被**自动拒绝**。

| 能力 | 默认状态 | 说明 |
|---|---|---|
| 联网搜索 | ✅ 可用 | 无需配置 |
| 加载 Agent Skills | ✅ 可用 | 加载与读取不需授权（但技能内的命令步骤需授权） |
| 长文本输出 | ✅ 可用 | 单次数万字符 |
| 读取工作目录内文件 | ⚠️ 需授权 | `--add-dir` 或 `read_file` 规则 |
| 创建 / 修改文件 | ⚠️ 需授权 | 授权后确实能写 |
| 删除文件 | 🚫 不做 | 见第四节红线 |
| 读取工作目录外文件 | ❌ 拒绝 | 需 `read_file` 规则 |
| 抓取网页正文 | ❌ 拒绝 | 需 `read_url` 规则 —— **能搜索、默认抓不了正文** |
| 执行 shell 命令 | ❌ 拒绝 | 需 `command` 规则 |

**关键认知**：`agy` 的「当前工作目录」**不是调用方 shell 的 cwd**，而是它自己的受信工作区根。因此**相对路径不可靠，必须给绝对路径**。

---

## 二、按目录最小授权

### 2.1 配置位置

```
~/.gemini/config/config.json
  └─ userSettings.globalPermissionGrants.allow   ← 规则数组
```

> ⚠️ 该文件与 Antigravity IDE **共享**。改动会同时影响 IDE 的行为，**改前务必备份**。

### 2.2 规则写法

| 权限类型 | 规则写法 | 粒度 |
|---|---|---|
| `read_file` | `read_file(/path/to/data/)` | **目录级**（末尾斜杠） |
| `read_file` | `read_file(/path/to/file.md)` | 文件级 |
| `write_file` | `write_file(/path/to/out/)` | 目录级 |
| `read_url` | `read_url(https://example.com/page)` | 精确 URL |
| `command` | `command(git)` / `command(regex:<模式>)` | 见第三节 |

**三条要点**：

1. **通配符无效** —— `read_file(/dir/*)`、`read_file(/dir/**)` 都会被拒。**目录级一律用末尾斜杠**。
2. **不要用 `--dangerously-skip-permissions`** —— 它是全权限放开，不限目录，等于放弃最小授权原则。
3. **被拒时照抄报错格式** —— 报错会直接给出权限类型与建议写法：
   ```
   Add an allow-rule under permissions.allow in settings.json (e.g. write_file(<target>))
   ```

### 2.3 追加规则的脚本

```bash
# 1) 备份
cp ~/.gemini/config/config.json ~/.gemini/config/config.json.bak-$(date +%Y%m%d)

# 2) 用 Python 追加（保证 JSON 合法）
python -c "
import json, pathlib
p = pathlib.Path.home() / '.gemini/config/config.json'
c = json.loads(p.read_text(encoding='utf-8'))
a = c['userSettings']['globalPermissionGrants']['allow']
for r in ['read_file(/path/to/data/)', 'write_file(/path/to/out/)']:
    if r not in a:
        a.append(r)
p.write_text(json.dumps(c, ensure_ascii=False, indent=2), encoding='utf-8')
print(a)"
```

### 2.4 推荐授权形态

只授**一个输入目录** + **一个专用输出目录**：

```
read_file(/path/to/data/)
write_file(/path/to/data/_transfer/)
```

这样即便子代理判断失误，其影响面也被限制在这两个目录内。

---

## 三、两条授权路径

实测两条路径**均有效**，可任选：

| 路径 | 键位 | 性质 |
|---|---|---|
| `~/.gemini/config/config.json` | `userSettings.globalPermissionGrants.allow` | 与 IDE 共享的 schema，对 CLI 同样生效 |
| `~/.gemini/antigravity-cli/settings.json` | `permissions.allow` | CLI 专属 schema —— 被拒时的报错指向它 |

### 最简临时授权：`--add-dir`

**无需改任何配置文件**：

```bash
agy -p "<任务>" --add-dir /path/to/workdir --output-format json
```

实测：清空所有 allow 规则后，仅加 `--add-dir <目录>`，即在该目录内成功创建文件。

**临时任务优先用它**，避免改动与 IDE 共享的配置。

---

## 四、shell 命令授权与删除红线

### 4.1 两种授权形式（实测均有效）

| 形式 | 写法 | 说明 |
|---|---|---|
| 精确串 | `command(git)` | 命令串需完全匹配（或按前缀） |
| 正则 | `command(regex:<模式>)` | 按命令串正则匹配；**写具体、避免 `.*` 泛匹配** |

### 4.2 作用域按模式强制

一个命令模式 **≠** 开放整个 shell。只授权命令 A 时，它执行**未授权**的命令 B 会被拒绝。

### 4.3 🚫 删除红线

**不做、不授权、不派发任何删除类操作。**

包括但不限于：`rm` / `rmdir` / `del` / `Remove-Item` / `shutil.rmtree` / `Move-Item`（覆盖语义）等。

**为什么设为红线（实测依据）**：

1. **删除走 shell，而 `command(regex:…)` 只匹配命令串、完全没有路径感知。**
   实测中，一条未锚定的模式 `command(regex:.*Remove-Item.*)` **成功删掉了授权目录之外的文件**。
   ⇒ **正则是减速带，不是安全边界。**
2. **存在「已真删但回复为空」的假失败。** 调用方会误判"没执行"，而文件已经没了，且无法恢复。
3. **删除不可逆**，风险与收益严重不成比例。

**确实需要删除时**：由**调用方在本地执行**，或改用**作用域受限、可追溯的专用工具**。

### 4.4 原生文件工具没有删除能力

实测确认，`agy` 原生文件工具只有三个：

- `view_file` —— 读取
- `write_to_file` —— 新建 + 全量覆写
- `replace_file_content` —— 局部编辑

**不存在 `delete` / `delete_file`**。删除只能通过 shell 绕过 —— 而这条路径已被红线封禁。

---

## 五、本地文件操作实测结论

| 操作 | 能否 | 工具 | 前置条件 |
|---|---|---|---|
| 读取 | ✅ | `view_file` | 目录在 `--add-dir` 或 allow 规则内 |
| 创建 | ✅ | `write_to_file` | 同上 |
| 修改（全量覆写） | ✅ | `write_to_file` | 同上 |
| 修改（局部编辑） | ✅ | `replace_file_content` | 同上 |
| 删除 | 🚫 | — | 红线 |

### 三个必须注意的坑

**① 权限动作名 ≠ 工具名**

工具叫 `write_to_file`，但**规则里必须写 `write_file`**：

```
write_file(/path/to/dir/)     ✅ 前斜杠 + 末尾斜杠
write_to_file(/path/to/dir/)  ❌ 不生效
```

**② 必须给绝对路径**

相对路径会被前置校验直接拒绝：

```
invalid_args: … must be an absolute path
```

且它的「当前目录」= 受信工作区根，**不是调用方 shell 的 cwd**。
⇒ **派单时务必在 prompt 里写死绝对路径**，否则它会写到工作区根或自己的 `scratch/` 下。

**③ `agy` 会改写 `settings.json`**

实测一次运行后该文件会被规范化重写（键序改变）。⚠️ **空数组 `"allow": []` 会被整体丢弃**（`permissions` 键消失），导致后续规则**静默失效**。

⇒ **不要在 `settings.json` 里留空 allow；手改后务必复核文件内容。**

### 失败探测很贵

被拒的轮次**同样计费**。实测单次范围 **3.0 万 ～ 18.2 万 token**（其中 `write_file` 被拒那次 18.2 万）。

⇒ **派真任务前先做一次最低成本的桩验证**：用一句极短的自包含指令（如"列出文件 X"或"创建空文件 X"）确认权限已生效，再投入重任务。

### 事后必做磁盘回检

它会**声称**"已成功创建"，也可能把写入**静默重定向到自己的 `scratch/`**。

**判成功一律以 `ls` / `cat` 目标绝对路径为准**，不采信其自述。

> ⚠️ **反面：空回复 ≠ 失败。**
> 实测某步骤**成功执行**，但紧随其后的自检命令不在 allow 内 → 被拒 → 整个回合返回空 `response`。
> 调用方据空回复会误判"什么都没发生"，而文件已经写好了。
> ⇒ **任何有副作用的操作，成败一律在系统层核验**（`ls` / `test -f` / `git status`）。**空回复既不等于失败，也不等于成功。**

---

## 六、权限审计口径

**权限面 ≠ 工具名白名单。** 审计应按「**可达数据域 + 可达执行能力**」核算：

```
可达面 = 显式 allow 的等价能力
       ∪  每个已授权 MCP 的数据根（乘以其读写删等动作面）
       ∪  unsandboxed 条目
       ∪  受信工作区 / 工程资源目录
```

**两个容易忽略的扩张点**：

1. **授权一个 MCP ≈ 间接放开该 MCP 的数据根**
   例：授权 `mcp(.../read_note)`，而该 server 以某目录为数据根 ⇒ **`read_file` 被拒 ≠ 该目录内容不可达**。

2. 🔴 **`mcp(.../execute_command)` 等价于放开任意命令执行**
   它绕过了直接 `command` 的拒绝，**风险高于文件读写授权**。
   实测取证：此类 server 常实现为 `subprocess.run(cmd, shell=True)` + 无命令白名单。
   ⇒ **须定期复核是否仍为必需。**

---

## 七、派发前应询问用户的三种情形

命中任一 → **先说明具体风险 → 询问用户是否外派 → 按答复执行**；
三者皆不命中 → **直接派发，无需询问**。

| # | 情形 |
|---|---|
| ① | 内容含**非公开信息**（他人数据、凭据密钥、内部资料、未公开数据） |
| ② | 需**读取本地文件或写入产物**（涉及放开权限） |
| ③ | 预估**收益不抵成本**（每轮 ≈28.7k 固定开销、任务过小） |

> 另有两类属**效果问题**而非规则限制：依赖调用方会话隐式共识（摘要必丢关键约束）；任务极简而上下文极大。这两种情况派了也没用。
