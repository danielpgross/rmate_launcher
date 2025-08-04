# Release Instructions

This document is for maintainers creating releases of rmate-server.

## Creating a Release

### 1. Update version in `build.zig`

Remove `.pre = "dev"` for releases:

```zig
// Before release
const version = std.SemanticVersion{ .major = 0, .minor = 7, .patch = 0, .pre = "dev" };

// For v1.0.0 release
const version = std.SemanticVersion{ .major = 1, .minor = 0, .patch = 0 };
```

### 2. Commit and push the version update

```bash
git add build.zig
git commit -m "Release v1.0.0"
git push origin main
```

### 3. Create and push git tag

```bash
git tag v1.0.0
git push origin v1.0.0
```

### 4. Create GitHub release

- Go to GitHub → Releases → "Create a new release"
- Choose your tag (v1.0.0)
- Add release notes
- Click "Publish release"

### 5. GitHub Actions automatically handles the rest

The release workflow will:
- Build binaries for all platforms (Linux x86_64/ARM64, macOS x86_64/ARM64)
- Create optimized, statically-linked binaries using `ReleaseSmall`
- Generate SHA256 checksums for security verification
- Upload all artifacts to the GitHub release

### 6. Bump to next dev version

After the release, update `build.zig` for the next development cycle:

```zig
const version = std.SemanticVersion{ .major = 1, .minor = 1, .patch = 0, .pre = "dev" };
```

```bash
git add build.zig
git commit -m "Bump to v1.1.0-dev"
git push origin main
```

## Binary Details

The release workflow produces:

### Artifacts Created
- `rmate_server-linux-x86_64.tar.gz` + `.sha256`
- `rmate_server-linux-aarch64.tar.gz` + `.sha256`  
- `rmate_server-macos-x86_64.tar.gz` + `.sha256`
- `rmate_server-macos-aarch64.tar.gz` + `.sha256`

### Binary Characteristics
- **Statically linked** - No runtime dependencies required
- **Stripped** - Small file sizes (~60KB for Linux, ~120KB for macOS)
- **Cross-platform** - Works across different Linux distributions and macOS versions
- **Optimized** - Built with `ReleaseSmall` for minimal size

## Version Consistency

Ensure the version in `build.zig` matches your git tag:
- Git tag: `v1.0.0`
- build.zig: `1.0.0` (no `.pre = "dev"`) ✅

The application displays this version in:
- Startup log: `"RMate server 1.0.0 listening on..."`
- Client greeting: `"RMate Server 1.0.0"`
- Help output: `rmate_server --help` shows `"RMate Server 1.0.0"`

## Testing Before Release

Test cross-compilation locally (optional):

```bash
# Test all targets build successfully
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall  
zig build -Dtarget=x86_64-macos-none -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos-none -Doptimize=ReleaseSmall

# Test that tests pass
zig build test
```

## Troubleshooting

### Release workflow fails
- Check that the tag was pushed: `git ls-remote --tags origin`
- Verify GitHub Actions has necessary permissions (should be automatic)
- Check the Actions tab for detailed error logs

### Version mismatch
- Ensure `build.zig` version matches git tag
- Re-run the release after fixing version consistency

### Missing artifacts
- The workflow takes 2-3 minutes to complete
- Refresh the release page if artifacts don't appear immediately
- Check Actions tab if the workflow is still running