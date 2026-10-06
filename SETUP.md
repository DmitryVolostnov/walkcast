# WalkCast setup — instructions for Claude

You are setting up WalkCast for the user on their Mac. Work through the steps in order. Keep the user informed in their language, ask only what is listed here, and never ask them to paste secrets into the chat.

`REPO` below is the folder this file is in (usually `~/WalkCast`).

## 1. Check the basics
- macOS with `python3` (3.9+). If `ffmpeg` is missing, offer `brew install ffmpeg` and run it after they agree.
- Claude Code session logs exist in `~/.claude/projects` — that is what the podcast is about. If the folder is empty, tell the user the first episodes will lean on general topics until they have some sessions.

## 2. Ask about the listener
Ask in one message:
1. Name (how the host should address them).
2. Language of the podcast (default: Russian).
3. A language they are learning, for phrases sprinkled through each episode (default: English; "none" to skip).
4. Two or three sentences about themselves: work, family, interests. Optional, but it makes topics much better.

Copy `REPO/pipeline/config.example.json` to `REPO/pipeline/config.json` and fill in `listener` and the first source's `person`. Leave the second source disabled.

Create `REPO/pipeline/state/history.md` with a heading `# Что уже было в выпусках` and `REPO/pipeline/state/notes.md` with a heading `# Пожелания к выпускам` (translate the headings into the podcast language).

## 3. OpenAI key for the voice
The voice is OpenAI `gpt-4o-mini-tts`, about $0.5 per 35-minute episode. Ask the user to copy their API key from platform.openai.com → API keys and then run:

```bash
mkdir -p ~/.config/walkcast && pbpaste > ~/.config/walkcast/openai_key
```

Verify without printing the key: `curl -s -o /dev/null -w "%{http_code}" https://api.openai.com/v1/models -H "Authorization: Bearer $(tr -d '[:space:]' < ~/.config/walkcast/openai_key)"` must return `200`. If the key starts with `sk-ant-`, it's an Anthropic key — ask for the OpenAI one.

## 4. iCloud Drive access
Episodes go to `~/Library/Mobile Documents/com~apple~CloudDocs/WalkCast`. Try `mkdir -p` on it. If you get "Operation not permitted", ask the user to enable **System Settings → Privacy & Security → Full Disk Access → Claude** and restart the Claude app, then retry.

## 5. Voice check
Write a short test script `REPO/pipeline/episodes/0000-test.md` (a `# Title`, one `## Section`, two short paragraphs in the podcast language, addressing the listener by name) and run `python3 tts.py episodes/0000-test.md` from `REPO/pipeline`. It should land in iCloud Drive/WalkCast. Tell the user they can change the voice in `config.json` (`nova` is the default female voice; `ash`, `onyx`, `cedar` are male) — the host persona in PROMPT.md is female, so if they choose a male voice, edit that line too. Delete the test files afterwards (locally and in iCloud).

## 6. Daily schedule
Create a daily task at 19:00 local time whose prompt is the content of `REPO/pipeline/TASK.md` with `PIPELINE_DIR` replaced by the absolute path of `REPO/pipeline`.
- In the Claude desktop app, use the scheduled tasks tool (`create_scheduled_task`, cron `0 19 * * *`). Then ask the user to press **Run now** once in Scheduled, so the tools get approved and the first episode appears in ~10 minutes.
- Without the desktop app, create a launchd agent that runs `claude -p "<task prompt>" --permission-mode acceptEdits --allowedTools "Bash Read Write Edit WebSearch WebFetch"` from `REPO/pipeline` at 19:00, and run it once now.

Remind the user: the task runs only while the Mac is on (and, for the desktop app, while Claude is open); missed runs happen on next launch.

## 7. Listening on the phone
Offer both, recommend the first if they have Xcode:
- **iOS app** (`REPO/app`): in `app/project.yml` change `bundleIdPrefix`, `PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` to the user's own (find the team ID with `security find-identity -v -p codesigning` or ask), run `xcodegen` if installed, open `app/WalkCast.xcodeproj`, build to their iPhone. On first launch pick iCloud Drive → WalkCast. New episodes, chapters, background music and "what's tomorrow" picks work automatically.
- **Web player, no Xcode**: on the iPhone open https://dmitryvolostnov.github.io/walkcast/player/ in Safari → Share → Add to Home Screen. Each evening tap ＋ and pick the new `.mp3` and `.json` from iCloud Drive → WalkCast. Tomorrow's picks are saved as `tomorrow.json` via Share → Save to Files → WalkCast.

## 8. Wrap up
Summarise in a few lines: when the first episode arrives, where to tweak things (`pipeline/state/notes.md` for wishes, `pipeline/topics.md` for the topic pool, `pipeline/config.json` for voice and sources), and that the shared/family mode is a disabled source in `config.json`.
