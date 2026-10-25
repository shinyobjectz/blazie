# 🔥 Blazie

A terminal on the iPad into your Mac, from anywhere. Blazie opens straight into a login shell on the Mac. It
has tabs for more shells, for localhost dev servers, and for live Mac app windows. Claude Code on the Mac can
open those tabs for you.

- **blazied** (`blazied`): the Mac daemon. It serves shells over WebSocket (each one in a hidden tmux
  session, so it survives restarts, sleep and network changes), pushes tabs to the app, and proxies
  `mac-PORT.<domain>` to `localhost:PORT`.
- **Cloudflare Tunnel** carries `mac.<domain>` and `*.<domain>` to blazied. Nothing listens on the LAN.
- **BlazieStream** (`mac/`): streams one Mac app window as H.264 from a virtual Retina display the size of the
  iPad tab, and replays taps, scrolls and keys on it.
- **Blazie for iPad** (`ios/`): SwiftUI and SwiftTerm, with terminal, web and Mac-app tabs.
- **blazie CLI and MCP server** (`blazie`): `blazie tab 5173`, `blazie mac-app Figma`, and the same as MCP tools
  for Claude.

Build: `mac/build.sh` (the streamer and its LaunchAgent), then `ios/build.sh` (the app; iPad on USB).
Secrets stay out of the repo: the shell token and the tunnel token live in `~/.blazie/`.
