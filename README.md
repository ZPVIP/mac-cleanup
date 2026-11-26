# mac-cleanup

A macOS cleanup and disk-usage audit script for developer machines. It clears rebuildable caches through each tool's own cleanup command and reports where the rest of your disk space went, without ever deleting Docker data, snapshots, browser profiles, AI models, or app data on its own.

## Usage

```bash
git clone <this repo> && cd mac-cleanup
cp config.example.json config.json   # then edit config.json
bash mac-cleanup.sh
```

The script takes no arguments. It shows a menu:

- **Dry run** (default): shows what would be cleaned and how big each item is. Deletes nothing.
- **Clean**: asks for confirmation, runs the automatic cleanup, then the disk audit.
- **Scan only**: disk audit only, no cleanup commands.

When stdin is not a terminal (for example when piped or run from cron), it runs a dry run.

Requires `jq`, which ships with macOS 15 and later (`brew install jq` on older versions).

## What Clean mode does

Each step only runs if the tool is installed:

- `brew cleanup --scrub --prune=all`
- `cargo clean` for each project in `rust_projects` (skipped when the project uses a shared or external target directory)
- `go clean -cache`
- `npm cache clean --force`, `yarn cache clean` (Yarn 1 only), `pnpm store prune`
- `uv cache prune`, `pip cache purge`
- `mise prune --tools` and `mise cache prune`

Caches are re-downloaded or rebuilt when needed, so the next build may be slower.

- **mise:** `mise prune --tools` removes any installed Node/Python/etc. version that no config file tracked by mise references. A version you installed by hand for later use can disappear. Pin versions you want to keep in a tracked mise config, or run a Dry run first.
- **Homebrew:** `brew cleanup` never upgrades anything. If it says `most recent version ... not installed`, check `brew outdated` and upgrade specific formulae yourself with `brew upgrade <formula>`.

## Configuration

`config.json` sits next to the script and is ignored by git. If it is missing, the script falls back to `config.example.json`.

```json
{
  "rust_projects": ["~/projects/my-rust-app"],
  "docker_builders": ["my-buildx-builder"],
  "report_dirs": [
    {
      "name": "Ollama models",
      "path": "~/.ollama/models",
      "enabled": true,
      "scan_large_files": true,
      "note": "List models with 'ollama list' and remove with 'ollama rm <model>'."
    }
  ]
}
```

- `rust_projects`: Rust project folders to `cargo clean` in Clean mode.
- `docker_builders`: Docker buildx builders whose cache size is shown in the audit. They are never pruned.
- `report_dirs`: folders whose size is shown in the "known locations" report. Set `enabled` to `false` to hide an entry, `scan_large_files` to `true` to list files of 500 MiB or more inside it, and `note` for advice printed under the entry. Entries under 100 MiB, or folders that don't exist, are left out of the report.

Paths may start with `~` or `$HOME`.

## Manual review guide

The script never runs anything in this section. These are things worth checking by hand when the audit shows they take a lot of space.

### General

- **App update caches:** `~/Library/Caches/*.ShipIt` and `*-updater` folders (VS Code, GitHub Desktop, other Electron apps) hold downloaded update packages. Quit the app and its updater before deleting them. Never delete the app's live profile in Application Support.
- **Large Application Support profiles** (JetBrains, VS Code, Cursor, Chrome, Brave, ...) contain settings, extensions, and sometimes unsynced data. Clean them from inside the app, not by deleting folders.
- **Xcode:** DerivedData is pure build output and safe to delete while Xcode is closed. Remove unused simulator runtimes from Xcode > Settings > Components instead of deleting mounted volumes by hand.
- **Rebuildable but expensive caches** (Electron, Playwright browsers, Corepack, node-gyp, `~/.cargo/registry`, `~/.cargo/git`, `~/.rustup`) force large re-downloads when removed. Never delete `~/.cargo/bin` or toolchains you use.
- **Swap:** a reboot releases swap space. Never delete swap files by hand. Logs are usually small; do not wipe all of `~/Library/Logs`.

### Docker

Docker keeps database data (PostgreSQL, MySQL, Redis, ...) in volumes. `docker system prune --volumes` first removes stopped containers and then the volumes they leave unused, so a database whose stack happens to be stopped can lose all its data. That is why the script only reports Docker usage. Work through the commands below from safest to riskiest.

| Command | What it does |
| --- | --- |
| `docker context show` | Read-only. Prints which Docker engine the CLI talks to (Docker Desktop, OrbStack, Colima, a remote host). Check this first so you clean the engine you think you are cleaning. |
| `docker system df -v` | Read-only. Breaks disk usage down into images, containers, volumes, and build cache, and shows how much of each is "reclaimable" (not used by any container). |
| `docker builder prune` | Deletes unused build cache of the default builder. Images, containers, and volumes are not touched; the next `docker build` is just slower. |
| `docker image prune` | Deletes dangling images: untagged layers left behind when an image is rebuilt under the same tag. Containers are not affected. Adding `-a` also removes every image no container uses; those get pulled or rebuilt next time. |
| `docker buildx ls` | Read-only. Lists buildx builders. Tools such as Kamal create their own builder containers, and each keeps a separate build cache that `docker builder prune` does not clear. |
| `docker buildx --builder <name> du` | Read-only. Shows how much build cache that builder holds. |
| `docker buildx --builder <name> prune --max-used-space 10gb` | Trims that builder's cache, oldest entries first, until it uses at most 10 GB. Only build cache is deleted. |
| `docker run --privileged --pid=host docker/desktop-reclaim-space` | Docker Desktop only. Deleting images does not shrink the `Docker.raw` disk file right away; this one-off container tells the Linux VM to hand freed blocks back to macOS. It pulls a small image and runs with full privileges inside the Docker VM. |
| `du -h ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | Read-only. `Docker.raw` is a sparse file: `ls` shows its maximum size, `du` shows the space it really uses. Compare `du` before and after cleaning. |

Never do these without a backup: delete `Docker.raw` (wipes every image, container, and volume), run `docker volume prune`, or run `docker system prune --volumes`.

### Time Machine and APFS snapshots (last resort)

Time Machine keeps hourly local snapshots on the internal disk. Space from files you delete stays used until the snapshots that still reference those files expire (usually within 24 hours) or are thinned.

| Command | What it does |
| --- | --- |
| `tmutil listlocalsnapshots /` | Read-only. Lists local Time Machine snapshots on the startup disk. |
| `diskutil apfs listSnapshots /System/Volumes/Data` | Read-only. Lists every APFS snapshot on the data volume, including ones created by macOS updates. |
| `sudo tmutil thinlocalsnapshots / 100000000000 4` | Deletes local Time Machine snapshots until about 100 GB (the number is in bytes) can be reclaimed, at urgency level 4 (scale 1-4). You lose the ability to restore from those local snapshots; backups on an external Time Machine disk are not affected. |
| `df -h /System/Volumes/Data` | Read-only. Shows free space on the data volume so you can see the effect. |

Do not remove `com.apple.os.update-*` snapshots by hand; macOS manages them.

## License

MIT
