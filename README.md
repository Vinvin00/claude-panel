# Claude Panel

A tiny panel for your Mac that keeps an eye on your Claude Code sessions while you do other things.

![Claude Panel in action](media/demo.gif)

It sits as a thin tab on the right edge of the screen with one little light per session. Green means Claude is working, orange means it needs you, grey means it's done. Hover the tab and the full panel slides out, where you can see what each session is up to and answer it right there.

## What it does

- Shows every running session, from the Claude desktop app and from the terminal
- Lets you approve or deny permission prompts without switching windows
- Lets you answer Claude's questions with one click, or type a reply
- Slides out a small card when a session finishes, with the first line of what Claude said
- Click a session to jump to it, right-click for more options
- Keeps a list of your Claude accounts (personal, work, whatever) so you can open any of them in one click, and add new ones with `+`
- Shows which model and effort each session is on, in small text under its name
- Shows how much of your 5-hour limit each account has used, as a little ring on its button, so you can pick the account with room left
- Shows how many replies and tokens you've used today
- Lives in the menu bar too (the ✨ icon), where all the settings are

## Install

You need a Mac, Claude Code, and Apple's command line tools (they bring Swift and Python). If you don't have the tools yet, run `xcode-select --install` first.

```bash
git clone https://github.com/Vinvin00/claude-panel.git
cd claude-panel
./install.sh
```

That builds the app into `~/Applications`, adds its hooks and a status line to `~/.claude/settings.json` (your old file is saved next to it as `settings.json.before-claude-panel`), and opens it. If you already have your own status line, it leaves yours alone. Look for the tab on the right edge of your screen.

New Claude sessions show up straight away. Sessions that were already open appear once they do something.

## Good to know

- When Claude asks you something and you're not in the Claude window, it waits up to 5 minutes for your answer in the panel. If you go back to Claude instead, it stops waiting so you can answer there.
- The usage rings come from Claude Code's status line, which only runs in the terminal. So an account's ring fills in once you've used Claude in a terminal on that account, and it hides itself when the number gets old. The desktop app keeps its own numbers to itself.
- Extra accounts each get their own Claude window. When you sign in to one, use "Continue with email" and type the code into that window. Google sign-in tends to open your main Claude window instead.
- I built this for myself on macOS 26, so that's the only place it's been tested. Older versions may not work.

## Remove it

```bash
./install.sh --remove
```

Then delete `~/Applications/Claude Panel.app`.

## License

MIT. Do what you like with it.
