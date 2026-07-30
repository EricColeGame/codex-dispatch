#!/bin/bash
# dispatch-codex.sh — 派发任务到 Codex CLI，自动回调通知
#
# Usage:
#   dispatch-codex.sh [OPTIONS] -p "your prompt here"
#
# Options:
#   -p, --prompt TEXT        任务 prompt（必需）
#   -n, --name NAME          任务名称（用于追踪）
#   -g, --group, --target ID 飞书通知目标，并自动注入任务 Prompt 和环境变量
#   --cdp PORT               浏览器 CDP 端口，并自动注入任务 Prompt 和环境变量
#   -s, --session KEY        回调 session key
#   -w, --workdir DIR        工作目录
#   --sandbox MODE           沙箱模式（read-only/workspace-write/danger-full-access）
#   --yolo                   --dangerously-bypass-approvals-and-sandbox
#   --skip-git-repo-check    允许在非 git 仓库中运行
#   --resume SESSION_ID      续跑指定 session
#   --model MODEL            模型覆盖；不传则使用 Codex 自身默认配置
#   --tmux                   使用 tmux 交互模式
#   --no-tmux                使用 headless 模式（默认）
#   --tmux-session NAME      tmux 会话名（默认: codex-agent）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/data"
PROMPTS_DIR="${RESULT_DIR}/prompts"

SESSION_DIR=""
META_FILE=""

TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
RUNNER="$SCRIPT_DIR/codex_run.py"
NOTIFY_SCRIPT="${SCRIPT_DIR}/hooks/notify-agi.sh"

# Defaults
PROMPT=""
PROMPT_FILE=""
EFFECTIVE_PROMPT=""
TASK_NAME=""
TASK_ID=""
FEISHU_TARGET="${FEISHU_TARGET:-}"
CDP_PORT="${CDP_PORT:-}"
CALLBACK_SESSION=""
WORKDIR="/root"
SANDBOX=""
YOLO="1"
SKIP_GIT_REPO_CHECK=""
RESUME_SESSION_ID=""
MODEL=""
ENABLE_TMUX="1"
TMUX_SESSION_NAME=""
DISPATCH_CONFIG="${DISPATCH_CONFIG:-}"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt) PROMPT="$2"; shift 2;;
        -n|--name) TASK_NAME="$2"; shift 2;;
        -g|--group|--target) FEISHU_TARGET="$2"; shift 2;;
        --cdp) CDP_PORT="$2"; shift 2;;
        -s|--session) CALLBACK_SESSION="$2"; shift 2;;
        -w|--workdir) WORKDIR="$2"; shift 2;;
        --sandbox) SANDBOX="$2"; shift 2;;
        --yolo) YOLO="1"; shift;;
        --skip-git-repo-check) SKIP_GIT_REPO_CHECK="1"; shift;;
        --resume) RESUME_SESSION_ID="$2"; shift 2;;
        --model) MODEL="$2"; shift 2;;
        --tmux) ENABLE_TMUX="1"; shift;;
        --no-tmux) ENABLE_TMUX=""; shift;;
        --tmux-session) TMUX_SESSION_NAME="$2"; shift 2;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo "Error: --prompt is required" >&2
    exit 1
fi

# Locate the config before resolving runtime defaults. An explicit --cdp or
# CDP_PORT always wins; otherwise use the configured default browser.
if [ -z "$DISPATCH_CONFIG" ]; then
    for candidate in "$SCRIPT_DIR/dispatch-config.json" "$SCRIPT_DIR/../dispatch-config.json" "/root/.openclaw/skills/coding-agent/scripts/dispatch-config.json"; do
        if [ -f "$candidate" ]; then DISPATCH_CONFIG="$candidate"; break; fi
    done
fi
if [ -z "$CDP_PORT" ] && [ -n "$DISPATCH_CONFIG" ] && [ -f "$DISPATCH_CONFIG" ]; then
    CDP_PORT="$(jq -r '.default_cdp // empty' "$DISPATCH_CONFIG")"
fi

if [ -n "$CDP_PORT" ] && ! [[ "$CDP_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: --cdp must be a numeric port" >&2
    exit 1
fi

if [ -z "$FEISHU_TARGET" ]; then
    if [ -n "$DISPATCH_CONFIG" ] && [ -f "$DISPATCH_CONFIG" ] && [ -n "$CDP_PORT" ]; then
        FEISHU_TARGET="$(jq -r --arg cdp "$CDP_PORT" '.cdp_targets[$cdp] // empty' "$DISPATCH_CONFIG")"
    fi
    if [ -z "$FEISHU_TARGET" ] && [ -n "$DISPATCH_CONFIG" ] && [ -f "$DISPATCH_CONFIG" ]; then
        FEISHU_TARGET="$(jq -r '.default_target // empty' "$DISPATCH_CONFIG")"
    fi
fi
if [ -z "$FEISHU_TARGET" ]; then
    echo "Error: no Feishu target; configure dispatch-config.json or pass --target" >&2
    exit 1
fi

export FEISHU_TARGET CDP_PORT
RUNTIME_CONTEXT="【Dispatch 运行时参数（由派发器注入，请直接使用，不要向用户重复询问）】"
if [ -n "$CDP_PORT" ]; then
    RUNTIME_CONTEXT="${RUNTIME_CONTEXT}
- CDP_PORT=${CDP_PORT}：浏览器调试端口；所有 agent-browser 命令使用 --cdp ${CDP_PORT}。"
fi
if [ -n "$FEISHU_TARGET" ]; then
    RUNTIME_CONTEXT="${RUNTIME_CONTEXT}
- FEISHU_TARGET=${FEISHU_TARGET}：飞书汇报目标；任务结束通知发送到该目标。"
fi
PROMPT="${RUNTIME_CONTEXT}

${PROMPT}"

# ---- 0. Append tail prompt (same pattern as dispatch-claude-code.sh) ----
PROMPT="${PROMPT}

---
【必须执行】任务完成后，你必须：

1. 统计任务总用时和各阶段用时
2. 分析执行过程中的优化点（哪些步骤耗时长、哪些失败重试了、哪些流程可以改进）
3. 给出 prompt 提示词或执行脚本的具体修改建议（如有）
4. 将以上内容连同任务结果摘要（成功/失败状态、关键信息）一起发送到飞书群聊：

\`\`\`bash
openclaw message send --channel feishu --target \"${FEISHU_TARGET}\" --message \"<任务结果摘要 + 用时统计 + 优化建议>\" 2>/dev/null || true
\`\`\`

即使任务失败，也必须发送失败原因和已完成的阶段信息。这是强制要求，不可省略。

5. 出错脚本修复、验证与 git 提交：任务结束前，对执行过程中出错的脚本进行修复；修复后必须重新运行验证，确认输出符合预期才算完成，禁止只修改不验证。凡是修复了脚本，验证通过后必须进入 /root/.openclaw 仓库，检查 git status 和 git diff，只提交本次修复涉及的文件，创建 git commit，并 push 到远程仓库。禁止提交无关改动、密钥文件、临时文件或大产物；若提交或 push 失败，必须在飞书失败通知中说明原因。**重要：执行 git add/commit/push 时必须使用 flock 排队锁**，避免多 agent 并行操作同一仓库导致 index.lock 冲突：
   \`\`\`bash
   flock /root/.openclaw/.git/git-commit.lock bash -c 'cd /root/.openclaw && git add <文件> && git commit --no-verify -m \"消息\" && git push origin master'
   \`\`\`
   如果获取锁超时（默认等 120 秒），说明其他 agent 正在 commit，等待后重试即可。

6. 经验库读写：
   - 目录结构：/root/.openclaw/skills/skill-memory/ 按 skill 名分为子目录（如 game-refactor/、code-before/、drbacklink/、wiki-sites/ 等），子目录内是按日期命名的经验文件 <YYYY-MM-DD>.md，同一天的所有任务经验合并到同一个日期文件里。
   - 子目录推断：读取环境变量 \$CODING_AGENT_TMUX_SESSION，从中去掉末尾的动态参数部分（域名、站点名、序号等任务级变量），剩余的固定前缀即为子目录名（如 game-refactor-part4-homepage-1-superstarbaseballwiki → 子目录 game-refactor/；code-before-example.com → 子目录 code-before/；wiki 站点相关 → 子目录 wiki-sites/）。如不确定，先 ls /root/.openclaw/skills/skill-memory/ 查看所有子目录列表，选择最匹配的。
   - 文件名：当天日期，即 /root/.openclaw/skills/skill-memory/<子目录>/<YYYY-MM-DD>.md（用执行当天日期，不要用任务名做文件名）。
   - 执行前：读取该子目录下最近 3 天的日期文件（最近 3 个 <YYYY-MM-DD>.md），把里面的经验条目作为参考，主动规避已知问题。不要读取全部历史文件，只取最近 3 天即可。
   - 执行后：将本次遇到的问题和改进建议追加写入当天的日期文件。同一天多次任务都追加到同一个日期文件，用 ## <本次域名或任务简称> 二级标题区分不同任务段落。如该日期文件不存在则先创建，并在首行写入标题行 # <子目录名> 经验 - <YYYY-MM-DD>，空一行后再追加经验段落。追加格式：
     ## <本次域名或任务简称>
     ### 遇到的问题
     - <如实填写，无则写\"无明显问题\">
     ### 改进建议
     - <如实填写，无则写\"无\">
     （末尾空一行）"

# ---- 0. Resolve runtime mode ----
TMUX_SESSION="${TMUX_SESSION_NAME:-}"
if [ -z "$TASK_NAME" ]; then
    TASK_NAME="${TMUX_SESSION_NAME:-adhoc-$(date +%s)}"
fi
TASK_ID="${TASK_NAME}_$(date +%Y%m%d_%H%M%S)_$$"

RUN_MODE="headless"
TMUX_SOCKET=""
if [ -n "$ENABLE_TMUX" ]; then
    RUN_MODE="tmux"
    TMUX_SOCKET_DIR="${CLAWDBOT_TMUX_SOCKET_DIR:-/root/clawdbot-tmux-sockets}"
    mkdir -p "$TMUX_SOCKET_DIR"
    TMUX_SOCKET="$TMUX_SOCKET_DIR/codex-code.sock"
fi

# 根据 tmux 会话名确定状态目录
if [ -n "$TMUX_SESSION_NAME" ]; then
    SESSION_DIR="${RESULT_DIR}/sessions/${TMUX_SESSION_NAME}"
    META_FILE="${SESSION_DIR}/task-meta.json"
else
    SESSION_DIR="${RESULT_DIR}"
    META_FILE="${RESULT_DIR}/task-meta.json"
fi

# ---- 1. Prepare prompt file ----
mkdir -p "$RESULT_DIR" "$RESULT_DIR/tasks" "$PROMPTS_DIR" "$WORKDIR"

PROMPT_FILE="${PROMPTS_DIR}/${TASK_ID}.md"
printf '%s\n' "$PROMPT" > "$PROMPT_FILE"
PROMPT_BASENAME=$(basename "$PROMPT_FILE")
EFFECTIVE_PROMPT="Read the file at the absolute path below using your Read tool, then follow all instructions strictly.
Path: ${PROMPT_FILE}

If the Read tool fails, run this command to locate the file:
  find / -name '${PROMPT_BASENAME}' 2>/dev/null
Then read whatever path it returns."

# ---- 2. Write task metadata ----

if [ -n "$SESSION_DIR" ] && [ "$SESSION_DIR" != "$RESULT_DIR" ]; then
    mkdir -p "$SESSION_DIR"
fi

jq -n \
    --arg name "$TASK_NAME" \
    --arg task_id "$TASK_ID" \
    --arg target "$FEISHU_TARGET" \
    --arg cdp_port "$CDP_PORT" \
    --arg session "$CALLBACK_SESSION" \
    --arg prompt "$PROMPT" \
    --arg prompt_file "$PROMPT_FILE" \
    --arg effective_prompt "$EFFECTIVE_PROMPT" \
    --arg model "$MODEL" \
    --arg workdir "$WORKDIR" \
    --arg ts "$(date -Iseconds)" \
    --arg run_mode "$RUN_MODE" \
    --arg tmux_session "$TMUX_SESSION" \
    --arg tmux_socket "$TMUX_SOCKET" \
    '{task_name: $name, task_id: $task_id, feishu_target: $target, cdp_port: $cdp_port, callback_session: $session, prompt: $prompt, prompt_file: $prompt_file, effective_prompt: $effective_prompt, model: $model, workdir: $workdir, started_at: $ts, run_mode: $run_mode, tmux_session: $tmux_session, tmux_socket: $tmux_socket, status: "running"}' \
    > "$META_FILE"

if [ -n "$SESSION_DIR" ] && [ "$SESSION_DIR" != "$RESULT_DIR" ]; then
    echo "$TASK_ID" > "${SESSION_DIR}/current-task-id.txt"
fi

cp "$META_FILE" "${RESULT_DIR}/tasks/${TASK_ID}.json"

echo "Task metadata written: $META_FILE"
echo "   Task ID: $TASK_ID"
echo "   Task: $TASK_NAME"
echo "   Target: ${FEISHU_TARGET:-none}"
echo "   CDP: ${CDP_PORT:-none}"
echo "   Prompt file: $PROMPT_FILE"

# ---- 2.5 Send start notification ----
if [ -n "$FEISHU_TARGET" ]; then
    if [ -n "$ENABLE_TMUX" ]; then
        NOTIFY_MSG="🚀 Codex 任务启动: ${TASK_NAME}

Tmux 会话: $TMUX_SESSION

查看实时执行:
\`\`\`bash
tmux -S $TMUX_SOCKET attach -t $TMUX_SESSION
\`\`\`"
    else
        NOTIFY_MSG="🚀 Codex 任务启动: ${TASK_NAME}（headless 模式，无 tmux 会话）"
    fi
    timeout 30 /usr/bin/openclaw message send --channel feishu --target "$FEISHU_TARGET" \
        --message "$NOTIFY_MSG" 2>/dev/null || true
fi

# ---- 3. Clear previous output ----
> "$TASK_OUTPUT"

# ---- 4. Set environment ----
export CODING_AGENT_TASK_ID="$TASK_ID"
export CODING_AGENT_SESSION_DIR="$SESSION_DIR"
export CODING_AGENT_TMUX_SESSION="$TMUX_SESSION"
export CODING_AGENT_WORKDIR="$WORKDIR"
export CODING_AGENT_PROMPT_FILE="$PROMPT_FILE"

# ---- 5. Build runner command ----
LAST_MSG_FILE="${RESULT_DIR}/last-message-${TASK_ID}.txt"

CMD=(python3 "$RUNNER" -p "$EFFECTIVE_PROMPT" --cwd "$WORKDIR")

if [ -n "$MODEL" ]; then
    CMD+=(--model "$MODEL")
fi

if [ -n "$ENABLE_TMUX" ]; then
    CMD+=(--mode tmux --tmux-session "$TMUX_SESSION" --interactive-wait-s 0)
else
    CMD+=(--mode headless --output-file "$LAST_MSG_FILE")
fi

if [ -n "$SANDBOX" ]; then
    CMD+=(--sandbox "$SANDBOX")
fi

if [ -n "$SKIP_GIT_REPO_CHECK" ]; then
    CMD+=(--skip-git-repo-check)
fi

if [ -n "$YOLO" ]; then
    CMD+=(--yolo)
fi

if [ -n "$RESUME_SESSION_ID" ]; then
    CMD+=(--resume "$RESUME_SESSION_ID")
fi

# ---- 6. Run Codex ----
if [ -n "$ENABLE_TMUX" ]; then
    echo "Creating tmux session: $TMUX_SESSION"
    "${CMD[@]}" 2>&1 | tee "$TASK_OUTPUT"
    EXIT_CODE=${PIPESTATUS[0]}
    echo ""
    echo "Task sent to codex session: $TMUX_SESSION"
    echo "To watch: tmux -S $TMUX_SOCKET attach -t $TMUX_SESSION"
else
    echo "Launching Codex (headless)..."
    echo "   Command: ${CMD[*]}"
    echo ""

    "${CMD[@]}" 2>&1 | tee "$TASK_OUTPUT"
    EXIT_CODE=${PIPESTATUS[0]}

    echo ""
    echo "Codex exited with code: $EXIT_CODE"

    # Update meta with completion
    if [ -f "$META_FILE" ]; then
        jq --arg code "$EXIT_CODE" --arg ts "$(date -Iseconds)" \
            '. + {exit_code: ($code | tonumber), completed_at: $ts, status: "done"}' \
            "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    fi

    # Call notify-agi.sh directly in headless mode
    if [ -x "$NOTIFY_SCRIPT" ]; then
        echo "Calling notify-agi.sh..."
        CODING_AGENT_TASK_ID="$TASK_ID" \
        CODING_AGENT_SESSION_DIR="$SESSION_DIR" \
        CODEX_EXIT_CODE="$EXIT_CODE" \
        CODEX_LAST_MSG_FILE="$LAST_MSG_FILE" \
        CODEX_TASK_OUTPUT="$TASK_OUTPUT" \
            "$NOTIFY_SCRIPT"
    fi
fi

exit $EXIT_CODE
