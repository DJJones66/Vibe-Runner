#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Optional


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def load_prd(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_prd(path: str, data: Dict[str, Any]) -> None:
    data["updated_at"] = now_iso()
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def find_task(data: Dict[str, Any], task_id: str) -> Optional[Dict[str, Any]]:
    for task in data.get("tasks", []):
        if task.get("id") == task_id:
            return task
    return None


def task_sort_key(task: Dict[str, Any]):
    return (int(task.get("priority", 9999)), str(task.get("id", "")))


def next_task(data: Dict[str, Any], task_id: Optional[str] = None) -> Optional[Dict[str, Any]]:
    allowed = {"pending", "retry"}
    by_id = {t.get("id"): t for t in data.get("tasks", [])}

    def deps_satisfied(task: Dict[str, Any]) -> bool:
        deps = task.get("depends_on", []) or []
        for dep_id in deps:
            dep = by_id.get(dep_id)
            if dep is None:
                return False
            if dep.get("status") != "done":
                return False
        return True

    if task_id:
        task = find_task(data, task_id)
        if not task:
            return None
        if task.get("status", "pending") not in allowed:
            return None
        if not deps_satisfied(task):
            return None
        return task

    candidates = [
        t
        for t in data.get("tasks", [])
        if t.get("status", "pending") in allowed and deps_satisfied(t)
    ]
    if not candidates:
        return None

    candidates.sort(key=task_sort_key)
    return candidates[0]


def cmd_next(args: argparse.Namespace) -> int:
    data = load_prd(args.prd)
    task = next_task(data, args.task)
    if task is None:
        return 0
    print(json.dumps(task, indent=2))
    return 0


def cmd_mark(args: argparse.Namespace) -> int:
    data = load_prd(args.prd)
    task = find_task(data, args.task_id)
    if task is None:
        print(f"task not found: {args.task_id}", file=sys.stderr)
        return 2

    task["status"] = args.status
    history = task.setdefault("history", [])
    history.append(
        {
            "time": now_iso(),
            "status": args.status,
            "note": args.note,
        }
    )

    save_prd(args.prd, data)
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    data = load_prd(args.prd)
    counts: Dict[str, int] = {}
    for task in data.get("tasks", []):
        status = task.get("status", "pending")
        counts[status] = counts.get(status, 0) + 1

    total = len(data.get("tasks", []))
    print(f"Project: {data.get('project', 'unknown')}")
    print(f"Total tasks: {total}")
    for key in sorted(counts.keys()):
        print(f"- {key}: {counts[key]}")
    return 0


def milestone_sort_key(name: str):
    if name.startswith("M") and name[1:].isdigit():
        return (0, int(name[1:]), name)
    return (1, 9999, name)


def cmd_milestones(args: argparse.Namespace) -> int:
    data = load_prd(args.prd)
    tasks = data.get("tasks", [])
    grouped: Dict[str, Dict[str, int]] = {}

    for task in tasks:
        milestone = task.get("milestone", "UNASSIGNED")
        status = task.get("status", "pending")
        if milestone not in grouped:
            grouped[milestone] = {
                "total": 0,
                "done": 0,
                "pending": 0,
                "failed": 0,
                "retry": 0,
                "other": 0,
            }

        grouped[milestone]["total"] += 1
        if status in grouped[milestone]:
            grouped[milestone][status] += 1
        else:
            grouped[milestone]["other"] += 1

    print(f"Project: {data.get('project', 'unknown')}")
    print("Milestones:")
    for milestone in sorted(grouped.keys(), key=milestone_sort_key):
        row = grouped[milestone]
        total = row["total"]
        done = row["done"]
        pending = row["pending"]
        failed = row["failed"]
        retry = row["retry"]
        other = row["other"]
        progress = 0.0 if total == 0 else (done / total) * 100
        print(
            f"- {milestone}: total={total} done={done} pending={pending} "
            f"retry={retry} failed={failed} other={other} progress={progress:.1f}%"
        )

    return 0


def cmd_field(args: argparse.Namespace) -> int:
    data = load_prd(args.prd)
    task = find_task(data, args.task_id)
    if task is None:
        print(f"task not found: {args.task_id}", file=sys.stderr)
        return 2

    value = task.get(args.field)
    if args.json:
        print(json.dumps(value))
    else:
        if value is None:
            print("")
        elif isinstance(value, (dict, list)):
            print(json.dumps(value))
        else:
            print(str(value))
    return 0


def render_prompt(codex_instructions: str, task: Dict[str, Any]) -> str:
    acceptance_lines = "\n".join(f"- {x}" for x in task.get("acceptance", []))
    return f"""{codex_instructions}\n\n---\n\nTask ID: {task.get('id')}\nTitle: {task.get('title')}\nPriority: {task.get('priority')}\n\nImplementation Request:\n{task.get('prompt', '').strip()}\n\nAcceptance Criteria:\n{acceptance_lines}\n\nExecution requirements:\n- Make real code changes in this repository.\n- Keep changes scoped to this task.\n- Run relevant checks before finishing.\n- In your final response, use the exact sections requested in CODEX.md.\n"""


def cmd_render_prompt(args: argparse.Namespace) -> int:
    data = load_prd(args.prd)
    task = find_task(data, args.task_id)
    if task is None:
        print(f"task not found: {args.task_id}", file=sys.stderr)
        return 2

    with open(args.codex_md, "r", encoding="utf-8") as f:
        codex_md = f.read().strip()

    content = render_prompt(codex_md, task)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(content)
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    data = load_prd(args.prd)
    task = find_task(data, args.task_id)
    if task is None:
        print(f"task not found: {args.task_id}", file=sys.stderr)
        return 2

    commands: List[str] = task.get("validation", []) or []
    if not commands:
        print("No validation commands defined.")
        return 0

    repo_root = os.path.abspath(args.repo_root)

    for idx, command in enumerate(commands, start=1):
        print(f"[validate {idx}/{len(commands)}] {command}")
        result = subprocess.run(command, shell=True, cwd=repo_root)
        if result.returncode != 0:
            print(
                f"Validation failed at step {idx}: {command}",
                file=sys.stderr,
            )
            return result.returncode

    print("Validation passed.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Vibe loop task controller")
    sub = parser.add_subparsers(dest="command", required=True)

    p_next = sub.add_parser("next")
    p_next.add_argument("prd")
    p_next.add_argument("--task", default=None)
    p_next.set_defaults(func=cmd_next)

    p_mark = sub.add_parser("mark")
    p_mark.add_argument("prd")
    p_mark.add_argument("task_id")
    p_mark.add_argument("status")
    p_mark.add_argument("note")
    p_mark.set_defaults(func=cmd_mark)

    p_summary = sub.add_parser("summary")
    p_summary.add_argument("prd")
    p_summary.set_defaults(func=cmd_summary)

    p_milestones = sub.add_parser("milestones")
    p_milestones.add_argument("prd")
    p_milestones.set_defaults(func=cmd_milestones)

    p_field = sub.add_parser("field")
    p_field.add_argument("prd")
    p_field.add_argument("task_id")
    p_field.add_argument("field")
    p_field.add_argument("--json", action="store_true")
    p_field.set_defaults(func=cmd_field)

    p_prompt = sub.add_parser("render-prompt")
    p_prompt.add_argument("prd")
    p_prompt.add_argument("task_id")
    p_prompt.add_argument("codex_md")
    p_prompt.add_argument("out")
    p_prompt.set_defaults(func=cmd_render_prompt)

    p_validate = sub.add_parser("validate")
    p_validate.add_argument("prd")
    p_validate.add_argument("task_id")
    p_validate.add_argument("repo_root")
    p_validate.set_defaults(func=cmd_validate)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
