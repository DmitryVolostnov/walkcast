#!/usr/bin/env python3
"""Озвучивает сценарий эпизода через OpenAI TTS и кладёт mp3 в iCloud Drive.

  python3 tts.py episodes/2026-10-06.md          # озвучить и доставить
  python3 tts.py episodes/2026-10-06.md --dry    # только посчитать чанки и стоимость
  python3 tts.py episodes/2026-10-06.md --limit 2  # озвучить первые 2 чанка (проба голоса)

Сценарий: markdown, первая строка «# Название», темы — «## Заголовок».
Заголовки не зачитываются, они идут в метаданные (список тем в плеере).
"""
import json, os, re, sys, shutil, subprocess, tempfile, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CFG = json.loads((ROOT / "config.json").read_text())
T = CFG["tts"]
T["voice"] = os.environ.get("WALKCAST_VOICE", T["voice"])
BIN = lambda n: shutil.which(n) or os.path.expanduser(f"~/.local/bin/{n}")


def api_key():
    k = os.environ.get("OPENAI_API_KEY")
    if not k:
        f = Path(os.path.expanduser(CFG["key_file"]))
        k = f.read_text().strip() if f.exists() else None
    if not k:
        sys.exit(f"Нет ключа OpenAI: положи его в {CFG['key_file']} или в OPENAI_API_KEY")
    return k


def parse(md):
    """→ (название, [(заголовок темы, [абзацы])])"""
    title, sections = None, []
    for line in md.splitlines():
        if line.startswith("# ") and title is None:
            title = line[2:].strip()
        elif line.startswith("## "):
            sections.append((line[3:].strip(), []))
        else:
            if not sections:
                sections.append(("Вступление", []))
            sections[-1][1].append(re.sub(r"[*_`>#]+", "", line).strip())
    out = []
    for name, lines in sections:
        paras = [p.strip() for p in re.split(r"\n\s*\n", "\n".join(lines)) if p.strip()]
        if paras:
            out.append((name, paras))
    return title or "Прогулка", out


def duration(path):
    info = subprocess.run([BIN("ffmpeg"), "-i", str(path)], capture_output=True, text=True).stderr
    d = re.search(r"Duration: (\d+):(\d+):([\d.]+)", info)
    return int(d[1]) * 3600 + int(d[2]) * 60 + float(d[3]) if d else 0


def chunk(paras, limit):
    out, cur = [], ""
    for p in paras:
        pieces = [p] if len(p) <= limit else re.split(r"(?<=[.!?…])\s+", p)
        for s in pieces:
            if cur and len(cur) + len(s) + 2 > limit:
                out.append(cur)
                cur = ""
            cur = f"{cur}\n\n{s}" if cur else s
    if cur:
        out.append(cur)
    return out


def speak(i, text, key, tmp):
    body = {"model": T["model"], "voice": T["voice"], "input": text,
            "instructions": T["instructions"], "speed": T.get("speed", 1.0), "response_format": "mp3"}
    for attempt in range(5):
        try:
            req = urllib.request.Request("https://api.openai.com/v1/audio/speech",
                                         data=json.dumps(body).encode(),
                                         headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=300) as r:
                path = Path(tmp) / f"{i:04d}.mp3"
                path.write_bytes(r.read())
                print(f"  чанк {i + 1} готов", flush=True)
                return path
        except Exception as e:
            print(f"  чанк {i + 1}: {e}, повтор…", flush=True)
            time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"чанк {i + 1} не озвучился")


def main():
    src = Path(sys.argv[1]).resolve()
    dry = "--dry" in sys.argv
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    title, sections = parse(src.read_text())
    # (индекс темы, текст); между темами — заставка
    jobs = [(si, c) for si, (_, paras) in enumerate(sections) for c in chunk(paras, T["chunk_chars"])][:limit]
    chars = sum(len(c) for _, c in jobs)
    # ~14 символов/сек русской речи; gpt-4o-mini-tts ≈ $0.015 за минуту
    minutes = chars / 14 / 60
    print(f"«{title}»: {len(sections)} тем, {len(jobs)} чанков, {chars} символов, ≈{minutes:.0f} мин, ≈${minutes * 0.015:.2f}")
    if dry:
        return
    key = api_key()
    stinger = ROOT / "assets" / "stinger.mp3"
    with tempfile.TemporaryDirectory() as tmp:
        with ThreadPoolExecutor(T.get("parallel", 4)) as ex:
            files = list(ex.map(lambda a: speak(a[0], a[1][1], key, tmp), enumerate(jobs)))
        playlist, chapters, t, prev = [], [], 0.0, None
        for (si, _), f in zip(jobs, files):
            if si != prev:
                if prev is not None and stinger.exists():
                    playlist.append(stinger)
                    t += duration(stinger)
                chapters.append({"title": sections[si][0], "start": round(t, 1)})
                prev = si
            playlist.append(f)
            t += duration(f)
        lst = Path(tmp) / "list.txt"
        lst.write_text("".join(f"file '{f}'\n" for f in playlist))
        out = src.with_suffix(".mp3")
        subprocess.run([BIN("ffmpeg"), "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(lst),
                        "-c:a", "libmp3lame", "-b:a", "96k", "-ac", "1",
                        "-metadata", f"title={title}", "-metadata", "artist=WalkCast", str(out)], check=True)
    dur = duration(out)
    nxt = src.with_suffix(".next.json")
    meta = {"date": src.stem, "title": title, "topics": [c["title"] for c in chapters], "chapters": chapters,
            "duration": round(dur), "next": json.loads(nxt.read_text()) if nxt.exists() else []}
    src.with_suffix(".json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    print(f"Готово: {out} ({dur / 60:.1f} мин)")

    dest = Path(os.path.expanduser(CFG["icloud_dir"]))
    try:
        dest.mkdir(parents=True, exist_ok=True)
        for f in (out, src.with_suffix(".json"), src):
            shutil.copy2(f, dest / f.name)
        print(f"Доставлено в iCloud Drive: {dest}")
        pick = dest / "tomorrow.json"
        if pick.exists() and limit is None:  # выбор слушателя использован этим выпуском
            (ROOT / "state" / "picks").mkdir(parents=True, exist_ok=True)
            shutil.move(pick, ROOT / "state" / "picks" / f"{src.stem}.json")
    except PermissionError:
        sys.exit("Нет доступа к iCloud Drive: выдай Claude «Полный доступ к диску» в Системных настройках → Конфиденциальность")


if __name__ == "__main__":
    main()
