#!/usr/bin/env python3
"""Собирает дайджест «о чём мы говорили» из всех источников в config.json.

Последние `fresh_hours` — подробно (реплики пользователя + куски ответов).
Предыдущие `context_days` — кратко (только реплики пользователя), как фон.
Результат: state/digest.md — его читает ежедневный прогон Claude.
"""
import json, os, re, sys, glob
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CFG = json.loads((ROOT / "config.json").read_text())
NOW = datetime.now(timezone.utc)
FRESH = NOW - timedelta(hours=CFG.get("fresh_hours", 24))
OLDEST = NOW - timedelta(days=CFG.get("context_days", 7))
SKIP_MARKER = "WALKCAST_DAILY_RUN"  # собственные прогоны WalkCast не анализируем
NOISE = re.compile(r"<(system-reminder|command-[a-z]+|local-command-[a-z]+|task-notification|bash-[a-z]+)>.*?</\1>|\[Image[^\]]*\]", re.S)


def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def text_of(content, include_tools=False):
    if isinstance(content, str):
        return content
    out = []
    for b in content or []:
        if b.get("type") == "text":
            out.append(b.get("text", ""))
    return "\n".join(out)


def clean(t, limit):
    t = NOISE.sub("", t).strip()
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t if len(t) <= limit else t[:limit] + " […]"


def claude_code_sessions(path):
    path = os.path.expanduser(path)
    for f in glob.glob(os.path.join(path, "*", "*.jsonl")):
        if datetime.fromtimestamp(os.path.getmtime(f), timezone.utc) < OLDEST:
            continue
        title, cwd, turns, skip = None, None, [], False
        for line in open(f, errors="ignore"):
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = d.get("type")
            if t == "custom-title":
                title = d.get("customTitle") or d.get("title") or title
            if t not in ("user", "assistant") or d.get("isSidechain"):
                continue
            when = ts(d.get("timestamp", ""))
            if not when or when < OLDEST:
                continue
            cwd = cwd or d.get("cwd")
            msg = d.get("message", {})
            content = msg.get("content")
            # tool_result-ы пользователя — не реплики человека
            if t == "user" and isinstance(content, list) and any(b.get("type") == "tool_result" for b in content):
                continue
            txt = text_of(content)
            if SKIP_MARKER in txt:
                skip = True
                break
            if txt.strip():
                turns.append((when, t, txt))
        if skip or not turns:
            continue
        yield {"title": title, "cwd": cwd, "turns": turns, "last": turns[-1][0]}


def text_folder(path):
    """Любые заметки .md/.txt (например, экспорт чьих-то логов)."""
    path = os.path.expanduser(path)
    for f in glob.glob(os.path.join(path, "**", "*.*"), recursive=True):
        if not f.endswith((".md", ".txt")):
            continue
        mt = datetime.fromtimestamp(os.path.getmtime(f), timezone.utc)
        if mt < OLDEST:
            continue
        yield {"title": Path(f).stem, "cwd": None, "turns": [(mt, "user", Path(f).read_text(errors="ignore"))], "last": mt}


READERS = {"claude-code": claude_code_sessions, "text-folder": text_folder}


def main():
    budget = CFG.get("digest_max_chars", 80000)
    parts = [f"# Дайджест на {datetime.now().strftime('%Y-%m-%d %H:%M')}\n"]
    pick = Path(os.path.expanduser(CFG["icloud_dir"])) / "tomorrow.json"
    if pick.exists():
        picks = json.loads(pick.read_text()).get("picks", [])
        if picks:
            parts.append("\n## Выбор слушателя на сегодня (обязательные темы)\n")
            parts += [f"- {p['title']}: {p.get('teaser', '')}" for p in picks]
    enabled = [s for s in CFG["sources"] if s.get("enabled", True)]
    for src in enabled:
        sessions = sorted(READERS[src["type"]](src["path"]), key=lambda s: s["last"], reverse=True)
        fresh = [s for s in sessions if s["last"] >= FRESH]
        per_session = max(3000, (budget // len(enabled) - 15000) // max(1, len(fresh)))
        older = [s for s in sessions if s["last"] < FRESH]
        parts.append(f"\n## Источник: {src['person']} ({src['type']})\n")
        parts.append(f"\n### Свежее (последние {CFG.get('fresh_hours', 24)} ч) — {len(fresh)} сессий\n")
        for s in fresh:
            where = Path(s["cwd"]).name if s["cwd"] else ""
            if "scratch-workspaces" in (s["cwd"] or ""):
                where = "без проекта"
            block = [f"\n#### {s['title'] or 'Без названия'} [{where}] {s['last'].astimezone().strftime('%d.%m %H:%M')}\n"]
            turns = s["turns"]
            for i, (when, role, txt) in enumerate(turns):
                if role == "user":
                    if clean(txt, 1200):
                        block.append(f"- **{src['person']}:** {clean(txt, 1200)}")
                # из ответов Claude берём только итоговый перед следующей репликой человека
                elif i + 1 == len(turns) or turns[i + 1][1] == "user":
                    block.append(f"  - Claude: {clean(txt, 600)}")
            block = "\n".join(block)
            parts.append(block if len(block) <= per_session else block[:per_session] + "\n  […сессия обрезана…]")
        parts.append(f"\n### Фон (до {CFG.get('context_days', 7)} дней назад) — {len(older)} сессий\n")
        for s in older:
            asks = [c for c in (clean(t, 250) for _, r, t in s["turns"] if r == "user") if c][:6]
            parts.append(f"- {s['last'].astimezone().strftime('%d.%m')} «{s['title'] or 'Без названия'}»: " + " | ".join(asks))
    out = "\n".join(parts)
    if len(out) > budget:
        out = out[:budget] + "\n\n[…дайджест обрезан по лимиту…]"
    (ROOT / "state").mkdir(exist_ok=True)
    (ROOT / "state" / "digest.md").write_text(out)
    print(f"digest.md: {len(out)} chars")


if __name__ == "__main__":
    main()
