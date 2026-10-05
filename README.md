# Jarvis

A Siri-style voice assistant for macOS, with Claude as the brain. Lives in the menu bar.

## Use it
- **⌥Space**: talk. Press again to stop listening early, or to interrupt while Jarvis is talking.
- **⌥⇧Space**: type instead.
- **"Hey Jarvis…"**: hands-free wake word (turn it on in the menu). Uses Apple's on-device SpeechAnalyzer, so it works with Siri and Dictation turned off and audio never leaves the Mac.
- If Jarvis ends with a question, the mic reopens on its own so you can answer.
- From Shortcuts, Raycast, a Stream Deck, etc.: open `jarvis://listen`, `jarvis://type`, or `jarvis://ask?q=what%27s%20my%20battery`.

## What it can do
Claude gets tools that act on the Mac: AppleScript (apps, music, volume, Calendar, Reminders, Notes, Mail, Messages,
dark mode, UI scripting), the shell (files, system info), opening apps/URLs/files, screenshots ("what's on my screen?"),
the clipboard, timers, web search, and a long-term memory file (menu: Open Memory File).

Jarvis asks you to confirm before it sends messages, deletes things, or does anything else that's hard to undo, and by default shell commands
show a Run/Cancel dialog (menu: Ask Before Shell Commands).

## Build
```
./build.sh
```
This builds `build/Jarvis.app`, signs it, installs it to `~/Applications`, and launches it. On first launch it asks for an Anthropic
API key (stored in the Keychain) and for Microphone + Speech Recognition access. The first time Jarvis controls a given app, macOS asks you to
approve it. Screenshots need Screen Recording permission.

## Tips
- A Premium or Enhanced voice sounds much better. Use Voice › Download Better Voices…, then choose the voice under Voice.
- Model: Opus 5.5 by default. Sonnet 5.5 and Haiku 4.5 are faster, and you can switch in the menu.
- To make ⌥Space your Siri replacement, turn off Siri in System Settings › Apple Intelligence & Siri.
