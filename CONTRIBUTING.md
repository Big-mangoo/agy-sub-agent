# Contributing

Thanks for your interest. Contributions are very welcome — especially **measured evidence**.

---

## What we need most

This project's value is its accuracy. The most useful contribution is **new reproducible evidence**.

| Priority | Contribution |
|---|---|
| ★★★ | **New measured data** — failure rates, version behavior changes, platform differences |
| ★★★ | **Corrections** — if any claim here conflicts with your measurement, say so, with evidence |
| ★★ | New failure modes with reproduction steps |
| ★★ | **Translations** — the detailed docs are currently Chinese-only |
| ★ | New examples for specific use cases |

---

## Before you contribute

### 1. Check your `agy` version

`agy` changes quickly, and many claims in this project are version-dependent.

```bash
agy --version
agy --help
```

If your version differs from the one recorded in [`EVIDENCE.md`](EVIDENCE.md), note that in your contribution.

> **Anything here can be wrong.** The authority is always your local `agy --help`, not this repository.

### 2. Distinguish measured from inferred

This project is explicit about the difference:

- **Measured** — you ran it and observed the result
- **Inferred** — you reasoned about it

Label clearly. Speculation is welcome *as speculation* — never presented as a finding.

---

## What makes good evidence

Include all four:

1. **Exact version** — the output of `agy --version`
2. **Exact command** — every flag, nothing omitted
3. **Raw observation** — the actual output, not a summary of your conclusion
4. **Sample size** — how many times did you run it?

### Good

```
agy --version  →  1.2.9

Command:
  agy -p "<task>" --model gemini-3.8-flash-high --output-format json

Ran 14 times, strictly serially. 3 of 14 runs returned:
  400 INVALID_ARGUMENT
  tools[…].properties[period].enum[0]: cannot be empty
  retryable: false

The remaining 11 runs succeeded.
```

### Not useful

```
There seems to be an intermittent error sometimes.
```

---

## Where things go

| Contribution | Location |
|---|---|
| New measured data | [`EVIDENCE.md`](EVIDENCE.md) — add a new `Ex` section |
| Correction to an existing claim | The relevant file; add to `EVIDENCE.md` if you have new data |
| New example | `examples/` |
| Documentation fix | The file itself |

---

## Quality checks before opening a PR

```bash
# Shell scripts must be syntactically valid
for f in examples/*.sh; do bash -n "$f" || echo "FAIL: $f"; done

# Python must compile
python -m py_compile examples/call_agy.py
```

Also please confirm:

- [ ] Files use **LF** line endings (enforced by `.gitattributes`)
- [ ] All internal links resolve
- [ ] **No personal paths, emails, tokens, or credentials**
- [ ] No client- or vendor-specific coupling (see *Scope* below)

---

## Privacy and safety

**Never include:**

- Real filesystem paths from your machine
- API keys, tokens, or credentials
- Other people's data
- Any non-public information

This repository is public. Assume everything you write will be permanently visible.

---

## Scope

This project is deliberately **client-agnostic**. It is designed to work with anything that can run a shell command.

Contributions that couple the core to a specific IDE, framework, or orchestration system will be declined. However, a **new, separate file** demonstrating integration with a particular tool is very welcome — keep the core generic.

---

## Language

- [`README.md`](README.md) is English; [`README.zh-CN.md`](README.zh-CN.md) is Chinese.
- The detailed docs under [`docs/`](docs/) are currently Chinese.
- **Issues and PRs are welcome in Chinese or English** — both are perfectly fine.

Translations of the detailed docs are one of the highest-value contributions available right now.

---

## Code of conduct

Be precise, be kind, and be willing to be wrong.

Technical disagreement backed by evidence is not a problem here — it is the entire point of the project. If your measurement contradicts something written here, that is a **valuable** contribution, not a confrontation.

---

## Reporting problems

Open an issue including:

1. What you expected to happen
2. What actually happened
3. Evidence in the format described above

**For security issues**, please report privately (via GitHub's security advisory feature) rather than in a public issue.
