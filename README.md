# RMate Launcher

Seamlessly edit files over SSH with a local editor of your choice, using the rmate protocol.

## Overview

- ✅ **Remote file editing** via RMate protocol with any local editor
- ✅ **Multiple concurrent files** with real-time OS-level file watching
- ✅ **Cross-platform** (Linux, macOS) with statically linked binaries
- ✅ **Editor agnostic** - VS Code, Sublime Text, Zed, etc.
- ✅ **Always available** - Runs as standalone service, independent of editor

### How it works

1. RMate client on remote server connects via SSH tunnel to local RMate server
2. Server saves file content to temp file and watches for changes with OS-level notifications
3. Server spawns local editor to edit temp file
4. Changes trigger `save` commands; editor close triggers `close` command

### Why the rmate protocol?

Originally developed for [TextMate](https://github.com/textmate/rmate), this is a proven protocol for editing remote files through SSH tunnels. It's widely supported with clients in [Ruby](https://github.com/textmate/rmate) (original), [Bash](https://github.com/aurora/rmate), [Python](https://github.com/sclukey/rmate-python), [Perl](https://github.com/davidolrik/rmate-perl), [Nim](https://github.com/aurora/rmate-nim), [C](https://github.com/hanklords/rmate.c), [Node.js](https://github.com/jrnewell/jmate), and [Go](https://github.com/mattn/gomate). Use any existing client with RMate Server - no changes required.

### Why not use existing editor extensions?

Editor-specific extensions ([RemoteSubl](https://github.com/randy3k/RemoteSubl), [Remote VSCode](https://github.com/rafaelmaiolla/remote-vscode)) require the editor to be running, have inconsistent behavior, and lock you into one editor. RMate Server provides consistent functionality across all editors and future-proof remote editing.

## Usage

```bash
# 1. Start server locally (skip this step if already running as a service)
RMATE_EDITOR="code --wait" rmate_server &

# 2. SSH with tunnel
ssh -R 52698:~/.rmate-server/rmate.sock user@remote-server

# 3. Edit remote files (opens in your local editor!)
rmate /path/to/remote/file.txt
```

### Automatic SSH Config

Add to `~/.ssh/config` for automatic forwarding:
```ssh-config
Host myserver.example.com          # For specific hosts
    RemoteForward 52698 ~/.rmate-server/rmate.sock

Host *                            # For all hosts (optional)
    RemoteForward 52698 ~/.rmate-server/rmate.sock
```

## Installation

### From GitHub Releases

Download binaries from the [releases page](../../releases):
- **Linux**: `rmate_server-linux-x86_64.tar.gz` / `rmate_server-linux-aarch64.tar.gz`
- **macOS**: `rmate_server-macos-x86_64.tar.gz` / `rmate_server-macos-aarch64.tar.gz`

```bash
# Download and install (example for Linux x86_64)
curl -L -o rmate_server.tar.gz https://github.com/yourusername/rmate-server/releases/latest/download/rmate_server-linux-x86_64.tar.gz
tar -xzf rmate_server.tar.gz && chmod +x rmate_server-linux-x86_64
mv rmate_server-linux-x86_64 /usr/local/bin/rmate_server
```

### From Source

Requires [Zig](https://ziglang.org/) 0.14.1+:
```bash
git clone https://github.com/yourusername/rmate-server.git && cd rmate-server
zig build -Doptimize=ReleaseSmall  # or just 'zig build' for development
```

## Running as a service

For daily use, run it as a system service. Templates are provided to set up the service on macOS and Linux:

#### macOS (launchd)

```bash
mkdir -p ~/.rmate-server
cp macos-launchd.plist.example ~/Library/LaunchAgents/com.user.rmate-server.plist
# Edit plist: paths, RMATE_EDITOR, RMATE_SOCKET, sandbox settings
launchctl load ~/Library/LaunchAgents/com.user.rmate-server.plist
launchctl start com.user.rmate-server
```

#### Linux (systemd)

```bash
mkdir -p ~/.rmate-server ~/.config/systemd/user
cp linux-systemd.service.example ~/.config/systemd/user/rmate-server.service
# Edit service: paths, RMATE_EDITOR, RMATE_SOCKET
systemctl --user daemon-reload && systemctl --user enable --now rmate-server
sudo loginctl enable-linger $USER  # Start on boot (optional)
```

## Configuration

All configuration is defined in environment variables.

### Required

`RMATE_EDITOR` - Editor command to run. Path to the temp file will be passed as the first argument.
```bash
export RMATE_EDITOR="code --wait"    # VS Code
export RMATE_EDITOR="vim"            # Vim  
export RMATE_EDITOR="subl --wait"    # Sublime Text
```

### Optional Configuration

- `RMATE_SOCKET` - Unix socket path (default: `~/.rmate-server/rmate.sock`)
- `RMATE_PORT` / `RMATE_IP` - Legacy TCP options (default: `52698/127.0.0.1`, less secure)

### Advanced: Dynamic editor selection

Since `RMATE_EDITOR` can be any command, you can use a bash script to launch different editors based on file patterns:

```bash
#!/bin/bash
# ~/.rmate-server/editor-selector.sh
case "$(basename "$1")" in
    *.md|*.txt|README*) zed --wait "$1" ;;           # Docs in Zed
    *.js|*.ts|*.json|*.html) code --wait "$1" ;;     # Web dev in VS Code  
    *) subl --wait "$1" ;;                           # Everything else in Sublime
esac
```
```bash
chmod +x ~/.rmate-server/editor-selector.sh
export RMATE_EDITOR="$HOME/.rmate-server/editor-selector.sh"
```

## Development

### Prerequisites

[Zig](https://ziglang.org/) 0.14.1+

### Build & Run

```bash
zig build                                                    # Development build
zig build -Doptimize=ReleaseSmall                           # Optimized build  
zig build test                                               # Run tests
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall # Cross-compile

# Run locally
export RMATE_EDITOR="code --wait" && zig build run
```

## License

MIT