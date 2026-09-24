# agy-sub-agent

> Delegate subtasks to the Antigravity CLI as an **independent sub-agent channel**.
> Client-, framework-, and orchestrator-agnostic — anything that can run a shell command can use it.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-compatible-blue.svg)](SKILL.md)

**English** · [简体中文](README.zh-CN.md)

---

## What is this

[Antigravity](https://antigravity.google/) is Google's AI coding assistant. It ships with an official CLI, `agy`, that supports **headless** (non-interactive) execution.

This project treats it as a **sub-agent channel**: you hand it self-contained, independently verifiable subtasks and get back structured JSON.

```
Your main program / main agent
        │
        │  delegate a subtask (self-contained prompt)
        ▼
   agy sub-agent process  ──→  runs independently (research / coding / analysis / review)
        │
        │  JSON result (usage, conversation_id, denied_actions)
        ▼
   caller verifies  ──→  merges into the deliverable
```

## Why use it

| Value | Notes |
|---|---|
| **Zero-cost compute** | Individual free tier, $0/month, no credit card required |
| **Keeps your context clean** | The subtask runs in a separate process; the caller only receives the result |
| **Cross-vendor independence** | A Gemini-family perspective — well suited to **second opinions** and cross-checks |
| **Parallel-friendly** | Runs alongside your other work; a single process can also fan out multiple subagents |

## Quick start

### 1. Install and authenticate

```bash
# Install the agy CLI per the official instructions,
# then run it once interactively to sign in.
agy
```

### 2. Delegate a task

```bash
agy -p "<self-contained task description>" \
  --model gemini-3.8-flash-high \
  --output-format json
```

### 3. Parse the result

```python
import json, subprocess

out = subprocess.run(
    ["agy", "-p", prompt, "--model", "gemini-3.8-flash-high", "--output-format", "json"],
    capture_output=True, text=True,
).stdout

d = json.loads(out)

# The only hard signal that the model actually ran
assert d["usage"]["total_tokens"] > 0, "did not actually execute"

# Prefer the pre-parsed structured field; fall back to the last line of `response`
result = d.get("structured_output") or json.loads(d["response"].strip().splitlines()[-1])
```

## The four hard requirements

> These are the single most important lessons in this project. Violating any one of them produces failures that are very hard to diagnose.

| # | Requirement | What happens if you break it |
|---|---|---|
| 1 | **Set proxy environment variables in restricted networks** | `agy` reads **environment-variable** proxies only, never system proxy settings → the request fails or simply hangs |
| 2 | **Do not pass `--print-timeout`** | The default means "no time limit". Setting a non-zero value truncates long tasks and produces a "successful status, incomplete result" false positive |
| 3 | **Retry failures automatically (serially, ≥3 times)** | Around 8% of calls fail intermittently → without retries you will misdiagnose the channel as broken |
| 4 | **Use in-process subagents for concurrency** | ≥3 concurrent external processes fail probabilistically through state races — and isolating the working directory does not help |

See [`docs/`](docs/) for details.

## Capability boundaries at a glance

| Capability | Default state |
|---|---|
| Web search | ✅ Reliable — the main reason to delegate |
| Loading Agent Skills | ✅ Works (loading and reading require no authorization) |
| Long-form output | ✅ Tens of thousands of characters per call |
| Reading / creating / modifying local files | ⚠️ **Requires authorization** (least-privilege, directory-scoped — see [`docs/permissions.md`](docs/permissions.md)) |
| Fetching full web pages | ❌ Requires `read_url` — **it can search but cannot fetch page bodies by default** |
| Running shell commands | ❌ Requires `command` authorization (**this project does not use it for deletions**) |

## Verifying results: a three-layer test

**Never trust `status` or the exit code alone** — both report `SUCCESS` / `0` even when execution failed.

| Layer | Question | Test |
|---|---|---|
| **① Invocation** | Did the model actually run? | `usage.total_tokens > 0` — the only hard signal |
| **② Delivery** | Was everything asked for actually delivered? | All requested sections/conclusions are present; watch for an "intermediate state" (stopping at `Waiting for…` with the final output missing) |
| **③ Content** | Is the content correct and complete? | Structurally complete + **sources verified** |

## ⚠️ The most important warning: verify every citation

Measured data (see [`EVIDENCE.md`](EVIDENCE.md)): in one literature-search task, **6 sampled sources yielded 3 fabrications** —

- **2 DOIs did not exist** in the DOI system, yet had flawless formatting with complete volume/issue/page data — **indistinguishable to the eye**;
- **1 DOI was real, but its content was rewritten wholesale** (dataset size, file format, and license all wrong).

**Conclusion:** this is not "the tool is bad" — it is that **its failure mode is exceptionally well hidden in retrieval tasks**. The channel is usable, but **never use it without verification**.

Any citation must follow these rules:

1. **Verify every single reference** (sampling is not acceptable for retrieval tasks) — check `https://doi.org/<doi>` and `https://arxiv.org/abs/<id>`;
2. **Copy the anti-fabrication clause verbatim into the prompt** (template in [`docs/verification.md`](docs/verification.md));
3. **For datasets, verify size / format / license** rather than trusting a paraphrase;
4. **If the fabrication rate is unacceptable, discard the whole channel and redo it** with another model.

## Integration (client-agnostic)

Pick whichever form matches your tooling:

| Form | File | Use it with |
|---|---|---|
| **Agent Skill** | [`SKILL.md`](SKILL.md) | AI coding tools that support the Agent Skills spec — drop it into your skills directory |
| **Agent instructions** | [`AGENTS.md`](AGENTS.md) | Tools that honor the `AGENTS.md` convention — read as project-level instructions |
| **Shell scripts** | [`examples/`](examples/) | Any software, CI system, or scheduler that can run a command |
| **Python wrapper** | [`examples/call_agy.py`](examples/call_agy.py) | Programmatic use, or integration into an existing pipeline |

> The design is decoupled from any specific client, orchestration framework, or expert system. All you need is the ability to run one command.

## Project structure

```
agy-sub-agent/
├── README.md                     # This file (English)
├── README.zh-CN.md               # 简体中文版
├── SKILL.md                      # Agent Skills specification format
├── AGENTS.md                     # AGENTS.md convention format
├── EVIDENCE.md                   # Measured evidence and data (traceable sources)
├── LICENSE
├── docs/
│   ├── permissions.md            # Permission model and local file operations
│   ├── verification.md           # Result verification and content checking
│   ├── concurrency.md            # Concurrency strategy
│   └── troubleshooting.md        # Troubleshooting handbook
└── examples/
    ├── 01-second-opinion.sh      # Second opinion (auditable independence)
    ├── 02-research-task.sh       # Retrieval task (anti-fabrication prompt)
    ├── 03-code-task.sh           # Coding task
    ├── 04-parallel-fanout.sh     # In-process parallel fan-out
    ├── 05-file-task.sh           # File writing (authorization + disk check)
    └── call_agy.py               # Python wrapper
```

## Design principles

1. **Packagable and verifiable in isolation** — only delegate subtasks that meet both criteria.
2. **Prompts must be self-contained** — the sub-agent cannot see the caller's conversation context.
3. **Never trust self-reports; only trust verification** — any operation with side effects must be checked at the filesystem/system level.
4. **No deletions** — irreversible, with a well-hidden failure mode; the risk/benefit ratio is unacceptable.
5. **Label the source** — when sub-agent output is merged into a deliverable, mark the originating channel.

## Version sensitivity

`agy` moves fast: **defaults and flag behavior change between versions**, and third-party write-ups are often outdated.

Whenever something conflicts with what this project says, **trust your local `agy --version` and `agy --help`** — and please open a PR to update this project.

> This project is based on `agy` **1.2.9**. One confirmed behavior change: the headless default timeout was 5 minutes through ≤1.2.5, and became **unlimited in 1.2.6**.

## Documentation language

Detailed docs under [`docs/`](docs/), plus [`SKILL.md`](SKILL.md), [`AGENTS.md`](AGENTS.md), and [`EVIDENCE.md`](EVIDENCE.md), are currently written in **Chinese** (they are more detailed than this README).

This README is intentionally self-contained — the four hard requirements, the three-layer test, and the citation warning are all here, so you can use the channel without reading Chinese. Translations are very welcome.

## Contributing

Contributions of new measured evidence, failure modes, and platform differences are welcome. Please:

- record **reproducible experimental conditions** in [`EVIDENCE.md`](EVIDENCE.md) (version, exact command, observed result) — not just conclusions;
- clearly distinguish **measured** from **inferred**.

## License

[MIT](LICENSE)
