#!/bin/bash
# Ночной запуск WalkCast без участия человека: Claude Code в headless-режиме,
# инструменты разрешены заранее (никаких вопросов «можно записать файл?»),
# в конце — проверка, что mp3 действительно лежит в iCloud, иначе уведомление.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
DATE=$(date +%F)
ICLOUD="$(python3 -c "import json,os;print(os.path.expanduser(json.load(open('$DIR/config.json'))['icloud_dir']))")"
LOG="$DIR/state/logs/$DATE.log"
mkdir -p "$DIR/state/logs"
cd "$DIR"

notify() { osascript -e "display notification \"$1\" with title \"WalkCast\" sound name \"Basso\"" 2>/dev/null; }
delivered() { [ -s "$ICLOUD/$DATE.mp3" ] && [ -s "$ICLOUD/$DATE.json" ]; }

if delivered; then echo "$(date) уже есть $DATE.mp3" >> "$LOG"; exit 0; fi

PROMPT="$(sed "s|PIPELINE_DIR|$DIR|g" TASK.md)"
for attempt in 1 2; do
  echo "=== $(date) попытка $attempt" >> "$LOG"
  perl -e 'alarm shift; exec @ARGV' 3600 claude -p "$PROMPT" \
    --permission-mode acceptEdits \
    --allowedTools "Bash Read Write Edit Glob Grep WebSearch WebFetch" \
    >> "$LOG" 2>&1
  echo "=== $(date) claude завершился с кодом $?" >> "$LOG"
  delivered && break
  # сценарий мог быть написан, а упала только озвучка — доозвучиваем без Claude
  if [ -s "episodes/$DATE.md" ]; then
    python3 tts.py "episodes/$DATE.md" >> "$LOG" 2>&1
    delivered && break
  fi
done

if delivered; then
  echo "$(date) OK: $ICLOUD/$DATE.mp3" >> "$LOG"
else
  echo "$(date) FAIL: выпуска нет" >> "$LOG"
  notify "Выпуск за $DATE не собрался. Лог: pipeline/state/logs/$DATE.log"
  exit 1
fi
