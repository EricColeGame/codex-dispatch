# Codex Dispatch

`codex-dispatch/` 是独立的 Codex 任务派发目录。它负责把任务送进 Codex tmux 会话，让学生可以在 tmux 或 Claw Remote 面板里同步观察执行现场。

## 目录结构

```text
codex-dispatch/
  SKILL.md                    # Codex dispatch skill：告诉后续 agent 怎么调用派发程序
  dispatch-config.json        # 默认消息群与 CDP → 飞书群映射
  dispatch-codex.sh            # 单任务派发入口
  batch-dispatch-codex.sh      # 批量串行派发入口
  codex_run.py                 # Codex 运行器
  hooks/notify-agi.sh          # Codex 完成通知 hook
```

## 学生需要准备什么

必需：

- `tmux`
- `jq`
- `python3`
- `codex` CLI，并且学生自己已经登录 / 配置好 Codex。

安装系统依赖：

```bash
apt-get update
apt-get install -y tmux jq python3 git
```

确认 Codex 可用：

```bash
command -v codex
codex --version
codex
```

配置 Codex hook：

Codex tmux 任务能启动和观察，不依赖 hook；但要让任务完成后自动写入 `data/tasks/<TASK_ID>.json`、更新 `data/latest.json`、发送飞书完成通知，就需要提前在 Codex 配置文件里配置 notify hook。

Codex 配置文件是：

```text
~/.codex/config.toml
```

如果文件不存在，先创建：

```bash
mkdir -p ~/.codex
touch ~/.codex/config.toml
```

然后把下面这一行合并进 `~/.codex/config.toml`：

```toml
notify = ["/root/.openclaw/skills/codex-dispatch/hooks/notify-agi.sh"]
```

注意：

- 不要覆盖学生原来 `~/.codex/config.toml` 里的模型、账号、sandbox 等配置，只增加或合并 `notify`。
- 如果学生把项目安装到别的位置，要把上面路径改成自己机器上的真实 `hooks/notify-agi.sh` 路径。
- 如果配置文件里已经有 `notify = [...]`，就把 `/root/.openclaw/skills/codex-dispatch/hooks/notify-agi.sh` 加进原数组，不要重复写两个 `notify` 字段。

例如已经有其他 notify 命令时，可以整理成：

```toml
notify = [
  "/root/.openclaw/skills/codex-dispatch/hooks/notify-agi.sh"
]
```

验证：

```bash
test -x /root/.openclaw/skills/codex-dispatch/hooks/notify-agi.sh
grep -n 'notify' ~/.codex/config.toml
```

课堂建议把这一步放在启动 dispatch 前完成。`codex_run.py` 也会尝试检查 notify 配置，但手动配置更适合教学演示：学生能明确知道“Codex 完成时为什么会回写任务状态和发完成通知”。

默认不需要 `.env`。不传 `--model` 时，脚本直接使用学生自己 `~/.codex/config.toml` / Codex 登录态里的默认模型配置；只有显式传 `--model` 时，才临时覆盖本次任务模型。

## 安装位置

推荐固定放到 OpenClaw skills 目录下：

```text
/root/.openclaw/skills/codex-dispatch
```

确认脚本可执行：

```bash
cd /root/.openclaw/skills/codex-dispatch
chmod +x *.sh *.py hooks/*.sh
```

## 安装后先配置消息群

首次派发任务前，必须打开当前项目目录里的配置文件：

```text
/root/.openclaw/skills/codex-dispatch/dispatch-config.json
```

默认内容使用课堂占位值，不能直接照搬。把其中的飞书 `chat_id` 全部替换成学生自己的真实群 ID：

```json
{
  "default_cdp": "9222",
  "default_target": "oc_xxxx_notification",
  "cdp_targets": {
    "9222": "oc_xxxx_notification",
    "9223": "oc_xxxx_demand",
    "9224": "oc_xxxx_code_1",
    "9225": "oc_xxxx_code_2",
    "9226": "oc_xxxx_code_3"
  }
}
```

- `default_cdp`：默认浏览器端口；未传 `--cdp` 时使用该端口，显式传入时覆盖默认值；
- `default_target`：默认工位的消息通知群；与 `default_cdp` 组成默认浏览器和通知组合；
- `cdp_targets`：CDP 端口与飞书群的对应关系；只传 `--cdp 9226` 时，dispatch 自动使用 `9226` 对应的群；
- `--target`：可选的临时覆盖；只有某次任务要改发其他群时才需要传。

`cdp_targets[default_cdp]` 必须与 `default_target` 相同；本例即 `9222 → oc_xxxx_notification`。

检查 JSON 格式：

```bash
cd /root/.openclaw/skills/codex-dispatch
jq empty dispatch-config.json
jq '.default_cdp, .default_target, .cdp_targets' dispatch-config.json
```

必须看到自己的真实群 ID，不能仍然是 `oc_xxxx_*`。配置完成后，dispatch 的选择顺序是：

```text
显式 --target
→ 否则按 --cdp 查询 cdp_targets
→ 否则使用 default_target
```

## 最小启动

下面不传 `--target`，用于验证刚才配置的 `default_target` 是否生效。

```bash
cd /root/.openclaw/skills/codex-dispatch

env -u CLAUDECODE ./dispatch-codex.sh \
  --tmux-session demo-codex-readme \
  --workdir /root/Documents/dispatch-demo/codex \
  -p "在当前目录创建 README.md，内容写一行 hello from codex dispatch。完成后汇总结果。"
```

查看 tmux 现场：

```bash
tmux -S /root/clawdbot-tmux-sockets/codex-code.sock \
  attach -t demo-codex-readme
```

退出观察但不终止任务：

```text
Ctrl+b，然后按 d
```

指定模型示例：

```bash
env -u CLAUDECODE ./dispatch-codex.sh \
  --tmux-session demo-codex-model \
  --workdir /root/Documents/dispatch-demo/codex \
  --model "<模型名>" \
  --cdp 9226 \
  -p "在当前目录创建 README.md，内容写一行 hello from codex model override。完成后汇总结果。"
```

## `dispatch-codex.sh`

Codex 单任务派发入口。课堂里最优先讲这个文件。

必填参数：

- `-p, --prompt TEXT`：必填。要交给 Codex 执行的任务提示词。

可选参数：

- `-n, --name NAME`：任务名，用于生成 `TASK_ID` 和查看日志；不传时默认使用 `--tmux-session` 的值。
- `-g, --group, --target ID`：可选。显式覆盖通知目标；不传时按 CDP 映射，无法映射则使用 `dispatch-config.json` 的默认消息通知群。
- `--cdp PORT`：可选。浏览器 CDP 端口；不传时读取 `default_cdp`，显式传入时覆盖默认值，并自动写入 Prompt、环境变量和任务元数据。
- `-s, --session KEY`：回调 session key。
- `-w, --workdir DIR` / `--workdir DIR`：可选覆盖 Codex 的工作目录；默认 `/root`，普通任务无需传。
- `--sandbox MODE`：沙箱模式，例如 `read-only`、`workspace-write`、`danger-full-access`；不传则使用 Codex 自身配置。
- `--yolo`：使用 `--dangerously-bypass-approvals-and-sandbox`；当前脚本默认开启，适合课堂可信工作目录。
- `--skip-git-repo-check`：允许在非 git 仓库中运行。
- `--resume SESSION_ID`：续跑指定 Codex session / thread。
- `--model MODEL`：临时覆盖 Codex 模型；不传就用学生自己的默认模型配置。
- `--tmux`：使用 tmux 交互模式；当前默认就是 tmux。
- `--no-tmux`：禁用 tmux，改用 headless 模式。
- `--tmux-session NAME`：指定 tmux 会话名；默认 `codex-agent`。

它负责：

- 解析任务、工作目录、模型、sandbox、tmux 会话等参数；
- 生成 `TASK_ID`；
- 写入 `data/` 下的任务状态文件；
- 把长 prompt 写入 `data/prompts/<TASK_ID>.md`，再让 Codex 读取该文件；
- 设置 hook 需要的 `CODING_AGENT_*` 环境变量；
- 调用 `codex_run.py` 把 Codex 启动进 tmux；
- headless 模式下直接调用 `hooks/notify-agi.sh` 写结果；
- tmux 模式下依赖 Codex notify hook 完成结果回写。

## `codex_run.py`

Codex 运行器。它不是课堂主入口，主要被 `dispatch-codex.sh` 调用。

必填参数：

- 无。独立运行时也可以不传参数；dispatch 流程会自动传入必要参数。

可选参数：

- `-p, --prompt TEXT`：要发送给 Codex 的 prompt。
- `--mode auto|headless|tmux`：运行模式；dispatch 默认传 `tmux`。
- `--cwd DIR`：Codex 工作目录。
- `--sandbox MODE`：透传 Codex sandbox 模式。
- `--yolo`：透传 Codex bypass approvals / sandbox 参数。
- `--skip-git-repo-check`：允许非 git 仓库运行。
- `--resume SESSION_ID`：恢复指定 Codex session / thread。
- `--model MODEL`：模型覆盖；不传就使用 Codex 自身默认配置。
- `--codex-bin PATH`：Codex CLI 路径；默认读取 `CODEX_BIN`，再查找 `codex`。
- `--tmux-session NAME`：tmux 会话名；默认 `codex-agent`。
- `--tmux-socket-dir DIR`：tmux socket 目录；默认 `/root/clawdbot-tmux-sockets`。
- `--tmux-socket-name NAME`：tmux socket 文件名；默认 `codex-code.sock`。
- `--interactive-wait-s SECONDS`：interactive 启动后等待 N 秒再打印 tmux 快照。
- `--output-file FILE`：headless 模式下最后消息输出文件。
- `-- EXTRA_ARGS`：透传给 Codex CLI 的额外参数。

它负责：

- 找到 `codex` CLI；
- 检查并补充 Codex notify 配置；
- 构造 headless 或 tmux interactive 命令；
- 创建 / 复用 / 清理 tmux 会话；
- 把 Codex 启动在指定 tmux 会话里；
- 把任务环境变量写进 tmux server 和 shell；
- 把 prompt 粘贴进 Codex 输入框并回车；
- 输出 attach / capture-pane 命令，方便人工观察。

## `batch-dispatch-codex.sh`

Codex 批量串行派发脚本。它读取一个 `tasks.json`，按顺序把多个任务逐个派给 Codex。

必填参数：

- `--tasks FILE`：必填。批量任务 JSON 文件路径，文件里必须有 `tasks` 数组。

可选参数：

- `-g, --group, --target ID`：可选覆盖通知目标；不传时由每个 Part 的单任务 dispatch 根据配置自动选择。
- `--cdp PORT`：浏览器 CDP 端口，自动传给每个 Part。
- `-w, --workdir DIR` / `--workdir DIR`：所有子任务共用的工作目录；默认 `/root`，仅需改到其他目录时传。
- `--sandbox MODE`：传给每个 Codex 子任务的 sandbox 模式。
- `--skip-git-repo-check`：允许在非 git 仓库中运行。
- `--model MODEL`：传给每个 Codex 子任务的模型覆盖值。
- `--wait-timeout SECONDS`：单个 part 最长等待时间；默认 `3600` 秒。
- `--stop-on-error`：某个 part 失败时立即停止；默认继续后面的任务。
- `--tmux-session NAME`：基础 tmux 会话名前缀；每个 part 会变成 `${NAME}-p<序号>`。
- `-h, --help`：打印帮助。

`tasks.json` 格式：

```json
{
  "tasks": [
    {"name": "part-1", "prompt": "第一阶段任务"},
    {"name": "part-2", "prompt": "第二阶段任务"}
  ]
}
```

它负责：

- 读取 `--tasks tasks.json`；
- 校验任务列表格式；
- 给每个 part 派一个独立 tmux 会话：`${TMUX_SESSION}-p<序号>`；
- 调用 `dispatch-codex.sh` 派发当前 part；
- 从 dispatch 输出里提取 `TASK_ID`；
- 轮询 `data/tasks/<TASK_ID>.json` 等待任务完成；
- 把上一步结果摘要传给下一步，形成链式上下文；
- 最后输出成功、失败、超时和总耗时。

## `hooks/notify-agi.sh`

Codex 完成通知 hook。Codex tmux 模式下，任务完成后由 Codex notify 调用它。

可选输入：

- `$1`：Codex notify 传入的 JSON payload；交互式 tmux 模式主要从这里解析最后输出、thread id 和工作目录。
- `CODING_AGENT_SESSION_DIR`：dispatch 注入。当前任务所在 session 状态目录；默认回退到 `data/`。
- `CODEX_EXIT_CODE`：headless 模式注入。Codex 进程退出码；默认 `0`。
- `CODEX_LAST_MSG_FILE`：headless 模式注入。Codex 最后一条消息文件。
- `CODEX_JSONL_FILE`：Codex JSONL 输出文件，用于提取 thread id。
- `CODEX_TASK_OUTPUT`：headless 模式注入。完整任务输出文件；默认 `data/task-output.txt`。
- `FEISHU_TARGET`：可选覆盖通知目标；默认由 `dispatch-config.json` 根据 CDP 或默认消息通知群自动选择。

它负责：

- 读取 Codex notify payload 或 headless 环境变量；
- 提取最后输出、thread id、工作目录；
- 找到对应 `task-meta.json`；
- 写入 `data/tasks/<TASK_ID>.json`；
- 写入 `data/latest.json`；
- 更新 `task-meta.json` 的 `status` / `completed_at`；
- 做简单去重，避免重复通知；
- 有真实通知配置时发送飞书完成通知。

## Claw Remote 观察

Codex dispatch 固定使用：

```text
/root/clawdbot-tmux-sockets/codex-code.sock
```

只要 Claw Remote 后端读取同一个 socket，就能看到 Codex 任务现场。

```bash
tmux -S /root/clawdbot-tmux-sockets/codex-code.sock list-sessions
```

任务状态文件：

```text
/root/.openclaw/skills/codex-dispatch/data/
```
