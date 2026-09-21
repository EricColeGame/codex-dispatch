#!/usr/bin/env python3
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

from codex_run import build_headless_cmd

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "data"
SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string", "enum": ["completed", "blocked", "failed"]},
        "summary": {"type": "string"},
    },
    "required": ["status", "summary"],
    "additionalProperties": False,
}


def now():
    return datetime.now(timezone.utc).isoformat()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


@contextmanager
def result_lock(directory):
    with (directory / "result.lock").open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def finalize(directory, task_id, status, output, exit_code, error_class=None):
    with result_lock(directory):
        meta = read_json(directory / "task-meta.json")
        if meta.get("task_id") != task_id or meta.get("status") != "running":
            return False
        result = {**meta, "status": status, "output": output, "exit_code": exit_code,
                  "error_class": error_class, "timestamp": now(), "completed_at": now()}
        write_json(RESULTS / "tasks" / (task_id + ".json"), result)
        write_json(directory / "task-meta.json", result)
        return True


def outcome(exit_code, completed, failed, final_message, validation):
    if exit_code != 0 or failed:
        return "failed", "Codex 执行失败，请检查该任务的 events.jsonl 和 stderr.log", "model_transient"
    if not completed:
        return "failed", "Codex 未产生 turn.completed 事件", "worker_exited"
    try:
        try:
            report = json.loads(final_message)
        except ValueError:
            reports = re.findall(r"(?ms)^```json\s*\n(.*?)^```\s*$", final_message)
            if len(reports) != 1:
                raise ValueError("Missing unambiguous final report")
            report = json.loads(reports[0])
        status, summary = report["status"], report["summary"]
        if status not in {"completed", "blocked", "failed"} or not isinstance(summary, str) or not summary.strip():
            raise ValueError("Invalid final report")
    except (ValueError, KeyError, TypeError):
        if validation:
            return "awaiting_validation", "Codex 已完成执行，交由业务验收判断结果", None
        return "failed", "Codex 最终结果缺失或不符合完成协议", "worker_exited"
    if status != "completed":
        return "failed", summary, "task_blocked" if status == "blocked" else "task_failed"
    return ("awaiting_validation" if validation else "done"), summary, None


def run_task(directory):
    meta = read_json(directory / "task-meta.json")
    task_id = meta["task_id"]
    schema_path = directory / "result-schema.json"
    write_json(schema_path, SCHEMA)
    final_path = directory / "last-message.json"
    args = argparse.Namespace(
        codex_bin=meta["codex_bin"], model=meta["model"], resume=None,
        prompt="-", json_output=True, output_file=str(final_path), cwd=meta["workdir"],
        sandbox=meta.get("sandbox"), skip_git_repo_check=True,
        yolo=not bool(meta.get("sandbox")),
        extra=["-c", "notify=[]", "--output-schema", str(schema_path)],
    )
    command = build_headless_cmd(args)
    environment = {**os.environ, "CODEX_MANAGED_TASK": "1", "CODING_AGENT_TASK_ID": task_id,
                   "CODING_AGENT_SESSION_DIR": str(directory)}
    progress = {"task_id": task_id, "runner_pid": os.getpid(), "last_activity": 0,
                "started": False, "thread_id": None}
    write_json(directory / "progress.json", progress)
    completed = False
    failed = False
    process = None

    def interrupted(signum, frame):
        if process is not None and process.poll() is None:
            process.terminate()
        raise RuntimeError(f"Codex worker interrupted: signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        with (directory / "events.jsonl").open("a", buffering=1) as events, \
                (directory / "stderr.log").open("a", buffering=1) as errors:
            process = subprocess.Popen(command, cwd=meta["workdir"], env=environment,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, bufsize=1)
            process.stdin.write(meta["prompt"])
            process.stdin.close()
            for line in process.stdout:
                events.write(line)
                print(line, end="", flush=True)
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                event_type = event.get("type", "")
                if event_type == "thread.started":
                    progress["thread_id"] = event.get("thread_id")
                if event_type in {"turn.started", "item.started", "item.updated", "item.completed", "turn.completed", "turn.failed"}:
                    progress.update(last_activity=int(time.time()), started=True)
                    write_json(directory / "progress.json", progress)
                if event_type == "turn.completed":
                    completed = True
                if event_type == "turn.failed":
                    failed = True
            exit_code = process.wait()
        final_message = final_path.read_text() if final_path.exists() else ""
        status, output, error = outcome(exit_code, completed, failed, final_message,
                                        meta["business_validation_required"])
        finalize(directory, task_id, status, output, exit_code, error)
        return 0 if status in {"done", "awaiting_validation"} else 1
    except Exception as error:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        finalize(directory, task_id, "failed", str(error), 1, "worker_exited")
        return 1


def progress_for(directory, task_id):
    try:
        meta = read_json(directory / "task-meta.json")
        progress = read_json(directory / "progress.json")
        if meta["task_id"] != task_id or progress["task_id"] != task_id:
            raise ValueError("Task identity mismatch")
        pid = str(int(progress["runner_pid"]))
        environment = Path("/proc", pid, "environ").read_bytes().split(b"\0")
        if ("CODING_AGENT_TASK_ID=" + task_id).encode() not in environment:
            raise ValueError("Runner identity mismatch")
        return {"owned": True, "last_activity": progress["last_activity"]}
    except (OSError, ValueError, KeyError, TypeError):
        return {"owned": False, "last_activity": 0}


def launch(args):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", args.tmux_session):
        raise ValueError("Invalid tmux session name")
    if not Path(args.workdir).is_dir():
        raise ValueError("Working directory does not exist")
    codex_bin = shutil.which("codex")
    if not codex_bin:
        raise ValueError("codex is not in PATH")
    socket_dir = Path(os.environ.get("CLAWDBOT_TMUX_SOCKET_DIR", "/home/ubuntu/clawdbot-tmux-sockets"))
    socket_dir.mkdir(parents=True, exist_ok=True)
    socket = str(socket_dir / "codex-code.sock")
    tmux = ["tmux", "-S", socket]
    if subprocess.run(tmux + ["has-session", "-t", args.tmux_session], capture_output=True).returncode == 0:
        raise ValueError("Refusing to replace an existing tmux session")
    directory = RESULTS / "sessions" / args.tmux_session
    directory.mkdir(parents=True, exist_ok=True)
    name = re.sub(r"[^A-Za-z0-9_.-]", "-", args.name or args.tmux_session)
    task_id = f"{name}_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{os.getpid()}"
    prompt = args.prompt + f"\n\n工作目录: {args.workdir}\nCDP_PORT={args.cdp or ''}\n"
    prompt += "最终仅输出符合 schema 的 JSON 对象（status 和 summary），不要 Markdown 或额外文本；遇到未解决的阻断必须使用 blocked 或 failed，不得报告 completed。"
    meta = {"task_id": task_id, "task_name": name, "agent": "codex", "status": "running",
            "started_at": now(), "prompt": prompt, "workdir": args.workdir,
            "tmux_session": args.tmux_session, "tmux_socket": socket, "run_mode": "managed",
            "model": args.model or "", "sandbox": args.sandbox, "codex_bin": codex_bin,
            "feishu_target": args.target or "", "cdp_port": args.cdp or "",
            "business_validation_required": os.environ.get("BATCH_VALIDATION_REQUIRED") == "true"}
    with result_lock(directory):
        meta_path = directory / "task-meta.json"
        if meta_path.exists() and read_json(meta_path).get("status") in {"running", "awaiting_validation"}:
            raise ValueError("Session has an unresolved task; use a unique session name")
        write_json(meta_path, meta)
        write_json(RESULTS / "tasks" / (task_id + ".json"), meta)
    print(f"Task metadata written: {meta_path}", flush=True)
    print(f"Task ID: {task_id}", flush=True)
    command = tmux + ["new-session", "-d", "-s", args.tmux_session, "-c", args.workdir]
    environment = {key: value for key, value in os.environ.items()
                   if key.startswith(("LLM_", "WEBSITE_", "OPENAI_", "CODEX_")) or key == "PATH"}
    environment.update(CODING_AGENT_TASK_ID=task_id, CODING_AGENT_SESSION_DIR=str(directory),
                       CODEX_MANAGED_TASK="1", CDP_PORT=args.cdp or "", FEISHU_TARGET=args.target or "")
    for key, value in environment.items():
        command.extend(["-e", f"{key}={value}"])
    command.append("exec " + shlex.join([sys.executable, str(Path(__file__).resolve()),
                                        "run", "--session-dir", str(directory)]))
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
        subprocess.run(tmux + ["set-option", "-t", args.tmux_session, "remain-on-exit", "on"],
                       check=True, capture_output=True)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            result = read_json(RESULTS / "tasks" / (task_id + ".json"))
            if result["status"] in {"done", "awaiting_validation"}:
                print("Codex completed during startup verification", flush=True)
                return 0
            if result["status"] == "failed":
                print("Codex startup failed; inspect per-task result", flush=True)
                return 1
            progress_path = directory / "progress.json"
            if progress_path.exists() and read_json(progress_path).get("started"):
                print("Codex accepted the task and emitted execution events", flush=True)
                return 0
            time.sleep(2)
        finalize(directory, task_id, "failed", "Codex did not emit execution events within 120 seconds", 1, "worker_exited")
        subprocess.run(tmux + ["kill-session", "-t", args.tmux_session], capture_output=True)
        return 1
    except Exception as error:
        finalize(directory, task_id, "failed", str(error), 1, "worker_exited")
        return 1


def notify(directory):
    meta = read_json(directory / "task-meta.json")
    with result_lock(directory):
        path = RESULTS / "tasks" / (meta["task_id"] + ".json")
        result = read_json(path)
        if result.get("status") not in {"done", "failed"} or not result.get("feishu_target") or result.get("notified_at"):
            return 0
        binary = shutil.which("openclaw")
        if not binary:
            return 1
        message = f"Codex 流水线任务: {result['task_name']}\n状态: {result['status']}\n{result.get('output', '')[:1000]}"
        sent = subprocess.run([binary, "message", "send", "--channel", "feishu", "--target",
                               result["feishu_target"], "--message", message],
                              capture_output=True, timeout=30)
        if sent.returncode == 0:
            result["notified_at"] = now()
            write_json(path, result)
        return sent.returncode


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    launcher = commands.add_parser("launch")
    launcher.add_argument("-p", "--prompt", required=True)
    launcher.add_argument("-n", "--name", default="")
    launcher.add_argument("-w", "--workdir", required=True)
    launcher.add_argument("--tmux-session", required=True)
    launcher.add_argument("--target", default="")
    launcher.add_argument("--cdp", default="")
    launcher.add_argument("--model", default="")
    launcher.add_argument("--sandbox")
    launcher.add_argument("--skip-git-repo-check", action="store_true")
    for name in ("run", "progress", "notify"):
        command = commands.add_parser(name)
        command.add_argument("--session-dir", required=True, type=Path)
        if name == "progress":
            command.add_argument("--task-id", required=True)
    args = parser.parse_args()
    if args.command == "launch":
        return launch(args)
    if args.command == "run":
        return run_task(args.session_dir)
    if args.command == "progress":
        print(json.dumps(progress_for(args.session_dir, args.task_id)))
        return 0
    return notify(args.session_dir)


if __name__ == "__main__":
    raise SystemExit(main())
