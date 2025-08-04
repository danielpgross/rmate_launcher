# RMate Server

A server implementation of the RMate protocol that allows editing remote files using a local editor of the user's choice.

## Features

- ✅ **Remote file editing** via RMate protocol
- ✅ **Multiple concurrent files** supported
- ✅ **Real-time file watching** with OS-level notifications
- ✅ **Cross-platform** (Linux, macOS)
- ✅ **Statically linked binaries** for easy deployment
- ✅ **Any editor** that can be launched from command line

## Installation

### From GitHub Releases

Download the appropriate binary for your platform from the [releases page](../../releases):

- **Linux x86_64**: `rmate_server-linux-x86_64.tar.gz`
- **Linux ARM64**: `rmate_server-linux-aarch64.tar.gz`
- **macOS Intel**: `rmate_server-macos-x86_64.tar.gz`
- **macOS Apple Silicon**: `rmate_server-macos-aarch64.tar.gz`

```bash
# Download and extract (example for Linux x86_64)
curl -L -o rmate_server.tar.gz https://github.com/yourusername/rmate-server/releases/latest/download/rmate_server-linux-x86_64.tar.gz
tar -xzf rmate_server.tar.gz
chmod +x rmate_server-linux-x86_64
mv rmate_server-linux-x86_64 /usr/local/bin/rmate_server
```

### From Source

```bash
git clone https://github.com/yourusername/rmate-server.git
cd rmate-server
zig build -Doptimize=ReleaseSmall
```

### Running as a Service

For production use, you may want to run rmate-server as a system service that starts automatically.

#### macOS (launchd)

1. Copy the example plist file and customize it:
```bash
cp macos-launchd.plist.example ~/Library/LaunchAgents/com.user.rmate-server.plist
```

2. Edit the plist file to customize:
   - Path to your rmate_server binary
   - Your preferred editor in `RMATE_EDITOR`
   - Port and IP settings if different from defaults
   - Log file paths

3. Load and start the service:
```bash
launchctl load ~/Library/LaunchAgents/com.user.rmate-server.plist
launchctl start com.user.rmate-server
```

4. To stop or unload:
```bash
launchctl stop com.user.rmate-server
launchctl unload ~/Library/LaunchAgents/com.user.rmate-server.plist
```

#### Linux (systemd)

1. Copy and customize the service file:
```bash
sudo cp linux-systemd.service.example /etc/systemd/system/rmate-server.service
```

2. Edit the service file to customize:
   - Path to your rmate_server binary
   - Your preferred editor in `RMATE_EDITOR`
   - Port and IP settings if different from defaults

3. Enable and start the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable rmate-server
sudo systemctl start rmate-server
```

4. Check service status:
```bash
sudo systemctl status rmate-server
sudo journalctl -u rmate-server -f  # View logs
```

## Usage

```
rmate_server [OPTIONS]
```

### Options

- `--help, -h` - Show help message and exit

### Required Environment Variables

#### `RMATE_EDITOR`
Editor command to use. The command will receive the temp file path as an argument.

```bash
# Examples:
export RMATE_EDITOR="code --wait"    # VS Code
export RMATE_EDITOR="vim"            # Vim
export RMATE_EDITOR="nano"           # Nano
export RMATE_EDITOR="subl --wait"    # Sublime Text
```

### Optional Environment Variables

#### `RMATE_PORT`
Port to listen on (default: 52698)

```bash
export RMATE_PORT=52699
```

#### `RMATE_IP`
IP address to bind to (default: 127.0.0.1)

```bash
export RMATE_IP=0.0.0.0  # Listen on all interfaces
```

## How It Works

1. User opens remote file in SSH session using an RMate client
2. Client connects through SSH tunnel to RMate server running on local machine
3. RMate server saves file content to temporary file on disk
4. RMate server begins watching for changes to tempfile using OS-level file watching
5. RMate server spawns local editor process to edit the newly-created temporary file
6. On changes to the temp file, RMate server sends 'save' command to client
7. On close of the local editor process, RMate server sends 'close' command to client

The server supports multiple files opened concurrently.

## Example Setup

### 1. Start the server locally

```bash
RMATE_EDITOR="code --wait" rmate_server
```

### 2. Set up SSH tunnel

```bash
ssh -R 52698:localhost:52698 user@remote-server
```

### 3. Edit remote files

On the remote server, use any RMate client:

```bash
# Using rmate client
rmate /path/to/remote/file.txt

# The file will open in your local VS Code!
```

## Building from Source

### Prerequisites

- [Zig](https://ziglang.org/) 0.14.1 or later

### Build Commands

```bash
# Development build
zig build

# Optimized build
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test

# Cross-compile for Linux
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall
```

## Development

### Running locally

```bash
export RMATE_EDITOR="code --wait"
zig build run
```

### Testing

```bash
zig build test
```

## For Maintainers

- **Release Instructions**: See [RELEASE.md](./RELEASE.md) for detailed release process

## License

[Add your license here]

## Contributing

[Add contributing guidelines here]