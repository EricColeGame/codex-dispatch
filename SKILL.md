---
name: codex-dispatch
description: Use this skill when the user wants to delegate a coding, refactor, debugging, documentation, or multi-step development task to OpenAI Codex through the Codex dispatch program. This skill does not execute the task itself; it prepares parameters and calls dispatch-codex.sh so Codex runs independently in tmux with task metadata and completion hook handling.
read_when:
  - 需要把任务委派给 Codex
  - 需要 Codex 在 tmux 会话里独立执行
  - 需要 Claw Remote 面板可观察 Codex 执行现场
  - 需要通过 dispatch-codex.sh 派发开发任务
metadata: {"clawdbot":{"emoji":"X","requires":{"bins":["tmux","jq","python3","codex"]}}}
allowed-tools: Bash(codex-dispatch:*)
---

# Codex Dispatch Skill

本 skill 是给后续 agent 用的调用规范。OpenClaw agent 只负责任务发放，真正执行由 Codex 在 tmux 会话中完成。

## 固定流程（必须）

1. 先回复用户：`收到，已将任务委派给 Codex 执行。`
2. 确定参数：`USER_TASK`、`TMUX_SESSION`；需要覆盖默认浏览器时再提供 `CDP_PORT`。任务名默认继承 `TMUX_SESSION`，工作目录默认 `/root`。
3. 调用 `dispatch-codex.sh`，不要直接运行 `codex` 或 `codex exec`。
4. dispatch 会写任务状态、启动 tmux、发送启动通知；hook 会在任务完成后写结果和发送完成通知。
5. dispatch 命令返回后立即回复用户 tmux 观察命令，不要 attach，不要轮询等待任务完成。

## 参数规则

必填参数：

- `USER_TASK`：用户要 Codex 完成的完整任务描述。

推荐自动生成：

- `TMUX_SESSION`：tmux 会话名；建议使用短横线命名，例如 `codex-fix-login-bug`。不传 `-n` 时，dispatch 会自动把它作为任务名。

可选参数：

- `FEISHU_TARGET`：显式覆盖通知目标；不传时按 `CDP_PORT` 映射，无法映射则使用配置中的 `default_target`。
- `WORKDIR`：仅任务不能在默认 `/root` 下执行时覆盖。
- `CDP_PORT`：可选的浏览器端口覆盖值。不传时使用 `dispatch-config.json` 中的 `default_cdp`；通过 `--cdp` 传入后，dispatch 会覆盖默认值，并自动注入 Prompt、环境变量和任务元数据。
- `MODEL`：只在用户明确要求临时换模型时传 `--model`。
- `SANDBOX`：Codex sandbox 模式；不传则使用 Codex 自身配置。
- `RESUME_SESSION_ID`：需要续跑指定 Codex 会话时传 `--resume`。
- `SKIP_GIT_REPO_CHECK`：非 git 目录运行时设为 `1`，脚本会追加 `--skip-git-repo-check`。

## 执行命令

后续 agent 按下面模板构造命令。默认安装路径是 `/home/ubuntu/.openclaw/skills/codex-dispatch`。

```bash
#!/bin/bash
set -euo pipefail

CODEX_DISPATCH_ROOT="${CODEX_DISPATCH_ROOT:-/home/ubuntu/.openclaw/skills/codex-dispatch}"

USER_TASK="${USER_TASK:?需要提供任务描述}"
TMUX_SESSION="${TMUX_SESSION:?需要提供 tmux 会话名}"

FEISHU_TARGET="${FEISHU_TARGET:-}"
CDP_PORT="${CDP_PORT:-}"
MODEL="${MODEL:-}"
SANDBOX="${SANDBOX:-}"
RESUME_SESSION_ID="${RESUME_SESSION_ID:-}"
SKIP_GIT_REPO_CHECK="${SKIP_GIT_REPO_CHECK:-}"

PROMPT="$(cat <<EOF
${USER_TASK}

执行要求：
1. 在 dispatch 默认工作目录 /root 内完成任务。
2. 修改前先阅读相关文件，保持改动范围最小。
3. 如需验证，运行与本次改动直接相关的命令。
4. 完成后输出：改了什么、验证结果、遗留风险。
5. 如果失败，说明失败原因、已完成部分、下一步建议。
EOF
)"

CMD=(
  env -u CLAUDECODE
  "${CODEX_DISPATCH_ROOT}/dispatch-codex.sh"
  -p "$PROMPT"
  --tmux-session "$TMUX_SESSION"
)

if [ -n "$FEISHU_TARGET" ]; then
  CMD+=(--target "$FEISHU_TARGET")
fi

if [ -n "$CDP_PORT" ]; then
  CMD+=(--cdp "$CDP_PORT")
fi

if [ -n "$MODEL" ]; then
  CMD+=(--model "$MODEL")
fi

if [ -n "$SANDBOX" ]; then
  CMD+=(--sandbox "$SANDBOX")
fi

if [ -n "$RESUME_SESSION_ID" ]; then
  CMD+=(--resume "$RESUME_SESSION_ID")
fi

if [ -n "$SKIP_GIT_REPO_CHECK" ]; then
  CMD+=(--skip-git-repo-check)
fi

"${CMD[@]}"
```

## Codex 执行指令（传给 `-p` 的 prompt）

传给 `-p` 的 prompt 必须包含：

```text
任务目标：
<用户原始任务>

工作目录：
<WORKDIR>

执行要求：
1. 先阅读相关文件，确认项目结构和现有约定。
2. 只修改完成任务必须修改的文件。
3. 不要生成无关测试、报告或总结文档，除非用户明确要求。
4. 如需验证，只运行与本次改动直接相关的命令。
5. 完成后汇总：改动文件、改动内容、验证命令和结果、风险或未完成项。
```

## 返回给用户

dispatch 成功启动后，立即告诉用户：

```text
任务已进入 Codex tmux 会话：
tmux -S /home/ubuntu/clawdbot-tmux-sockets/codex-code.sock attach -t <TMUX_SESSION>

按 Ctrl+B 然后按 D 可以退出观察，不会终止任务。
```

## 关键文件路径

- Codex dispatch：`/home/ubuntu/.openclaw/skills/codex-dispatch/dispatch-codex.sh`
- Codex runner：`/home/ubuntu/.openclaw/skills/codex-dispatch/codex_run.py`
- Codex hook：`/home/ubuntu/.openclaw/skills/codex-dispatch/hooks/notify-agi.sh`
- tmux socket：`/home/ubuntu/clawdbot-tmux-sockets/codex-code.sock`
- Codex 任务状态：`/home/ubuntu/.openclaw/skills/codex-dispatch/data/`
