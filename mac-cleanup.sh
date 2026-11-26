#!/bin/bash
# mac-cleanup.sh
# macOS development cleanup and disk-growth audit.
#
# Run it with no arguments and pick a mode from the menu:
#   1) Dry run   - show what would be cleaned, delete nothing
#   2) Clean     - run the automatic cleanup, then the disk audit
#   3) Scan only - disk audit only, no cleanup commands at all
#
# Automatic cleanup only touches rebuildable or re-downloadable artifacts, always through each tool's own cleanup command: Homebrew old versions and download cache, `cargo clean` for the Rust projects listed in config.json, Go build cache, npm / Yarn 1 / pnpm / pip / uv caches, unreferenced mise tool versions and stale mise metadata. Cleaning caches may slow the next build or require network access.
#
# Never deleted automatically: Docker containers/images/volumes, APFS/Time Machine snapshots, browser profiles, AI models, app databases, Xcode simulator runtimes, or any Application Support directory.
#
# Configuration: config.json next to this script (see config.example.json and README.md). Requires jq (bundled with macOS 15+, or `brew install jq`).

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: bash mac-cleanup.sh

Takes no arguments. Pick Dry run, Clean, or Scan only from the menu.
Settings (Rust projects, Docker builders, extra folders to report) live in
config.json next to the script; copy config.example.json to get started.
USAGE
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "This script takes no arguments; run it and choose a mode from the menu." >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is intended for macOS (Darwin)." >&2
  exit 1
fi

has() { command -v "$1" >/dev/null 2>&1; }
exists_path() { [[ -e "$1" || -L "$1" ]]; }

if ! has jq; then
  echo "jq is required to read config.json. It ships with macOS 15+; otherwise run: brew install jq" >&2
  exit 1
fi

size_kb() {
  local p="$1" n
  if ! exists_path "$p"; then printf '0\n'; return; fi
  n="$(du -sk "$p" 2>/dev/null | awk 'NR==1 {print $1}')"
  printf '%s\n' "${n:-0}"
}

size_many_kb() {
  local p total=0 k
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    k="$(size_kb "$p")"
    total=$((total + k))
  done
  printf '%s\n' "$total"
}

human_kb() {
  awk -v k="${1:-0}" 'BEGIN {
    if (k >= 1048576) printf "%.2f GiB", k / 1048576;
    else if (k >= 1024) printf "%.1f MiB", k / 1024;
    else printf "%d KiB", k;
  }'
}

say() { printf '%s\n' "$*"; }
section() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$1"; }
# Echoes a command like a shell prompt before its output is printed.
show_cmd() { printf '\033[1m$ %s\033[0m\n' "$*"; }

# Word-wraps stdin to the terminal width, keeping each line's leading indent. Lines starting with "* " get a hanging indent.
wrap_text() {
  local width
  width="$(tput cols 2>/dev/null || echo 80)"
  [[ "$width" =~ ^[0-9]+$ ]] || width=80
  (( width > 110 )) && width=110
  (( width < 40 )) && width=40
  awk -v w="$width" '{
    match($0, /^ */); ind = substr($0, 1, RLENGTH); text = substr($0, RLENGTH + 1)
    if (text == "") { print ""; next }
    cont = ind; if (text ~ /^\* /) cont = ind "  "
    n = split(text, words, / +/); line = ind; empty = 1
    for (i = 1; i <= n; i++) {
      if (!empty && length(line) + 1 + length(words[i]) > w) { print line; line = cont words[i] }
      else if (empty) { line = line words[i]; empty = 0 }
      else line = line " " words[i]
    }
    print line
  }'
}

expand_path() {
  local p="$1"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
    "\$HOME") p="$HOME" ;;
    "\$HOME/"*) p="$HOME/${p#\$HOME/}" ;;
  esac
  printf '%s\n' "${p%/}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CONFIG_FILE=""
CONFIG_NOTICE=""
if [[ -f "$SCRIPT_DIR/config.json" ]]; then
  CONFIG_FILE="$SCRIPT_DIR/config.json"
elif [[ -f "$SCRIPT_DIR/config.example.json" ]]; then
  CONFIG_FILE="$SCRIPT_DIR/config.example.json"
  CONFIG_NOTICE="config.json not found, using config.example.json. Copy it to config.json and edit it to add your Rust projects and choose which folders to report."
else
  CONFIG_NOTICE="No config.json found: Rust project cleanup and the known-locations report are skipped."
fi

if [[ -n "$CONFIG_FILE" ]] && ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "Invalid JSON in $CONFIG_FILE:" >&2
  jq empty "$CONFIG_FILE" 2>&1 | sed 's/^/  /' >&2
  exit 1
fi

# Field separator for multi-column config rows. A non-whitespace IFS keeps empty fields.
FS=$'\x1f'

# Prints one line per string in the top-level array named $1.
config_strings() {
  [[ -n "$CONFIG_FILE" ]] || return 0
  jq -r --arg k "$1" '(.[$k] // []) | .[]? | strings' "$CONFIG_FILE"
}

# Prints enabled report_dirs entries as: name FS path FS note FS scan_large_files
config_report_dirs() {
  [[ -n "$CONFIG_FILE" ]] || return 0
  jq -r '(.report_dirs // []) | .[]? | objects | select(.enabled != false and (.path | type) == "string")
    | [(.name // .path), .path, (.note // ""), ((.scan_large_files // false) | tostring)]
    | map(tostring | gsub("[\n\t\u001f]"; " ")) | join("\u001f")' "$CONFIG_FILE"
}

RUST_PROJECTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && RUST_PROJECTS+=("$(expand_path "$line")")
done < <(config_strings rust_projects)

DOCKER_BUILDERS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && DOCKER_BUILDERS+=("$line")
done < <(config_strings docker_builders)

REPORT_NAMES=()
REPORT_PATHS=()
REPORT_NOTES=()
LARGE_FILE_DIRS=()
while IFS="$FS" read -r r_name r_path r_note r_scan; do
  [[ -n "$r_path" ]] || continue
  r_path="$(expand_path "$r_path")"
  REPORT_NAMES+=("$r_name")
  REPORT_PATHS+=("$r_path")
  REPORT_NOTES+=("$r_note")
  [[ "$r_scan" == "true" ]] && LARGE_FILE_DIRS+=("$r_path")
done < <(config_report_dirs)

# ---------------------------------------------------------------------------
# Mode selection menu
# ---------------------------------------------------------------------------

confirm_clean() {
  local answer
  say ""
  say "Clean mode will run each installed tool's own cleanup command:"
  say "  brew cleanup --scrub --prune=all, cargo clean (${#RUST_PROJECTS[@]} project(s) from config),"
  say "  go clean -cache, npm/yarn/pnpm/pip/uv cache cleanup, mise prune --tools, mise cache prune."
  say "Nothing in Docker, Time Machine, browsers, or Application Support is touched."
  read -r -p "Proceed with cleanup? [y/N] " answer || return 1
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" ]]
}

choose_mode() {
  if [[ ! -t 0 ]]; then
    say "No interactive terminal detected: running a dry run (nothing will be deleted)."
    MODE="dry-run"
    return
  fi
  local choice
  while true; do
    cat <<'MENU'

What would you like to do?
  1) Dry run    Show what would be cleaned and how big it is. Deletes nothing.
  2) Clean      Run the automatic cleanup, then the disk audit.
  3) Scan only  Disk usage audit only. No cleanup commands are run.
  q) Quit
MENU
    read -r -p "Choose [1/2/3/q] (Enter = 1): " choice || exit 1
    case "$choice" in
      ""|1) MODE="dry-run"; return ;;
      2) if confirm_clean; then MODE="clean"; return; fi
         say "Cleanup cancelled." ;;
      3) MODE="scan-only"; return ;;
      q|Q) exit 0 ;;
      *) say "Please enter 1, 2, 3, or q." ;;
    esac
  done
}

[[ -n "$CONFIG_NOTICE" ]] && say "Note: $CONFIG_NOTICE" | wrap_text
choose_mode

# ---------------------------------------------------------------------------
# Cleanup helpers
# ---------------------------------------------------------------------------

TOTAL_SAVED_KB=0
SUCCEEDED=0
FAILED=0
SKIPPED=0

# Calls a program's own cleanup command and measures the paths it owns before and after.
# Syntax: step 'Display name' path1 [path2 ...] -- command arg1 arg2 ...
step() {
  local name="$1" before after freed status=0
  shift
  local paths=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    paths+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  local cmd=("$@")
  before="$(size_many_kb ${paths[@]+"${paths[@]}"})"
  printf '\n%-27s Before: %-12s\n' "$name" "$(human_kb "$before")"
  show_cmd "$(printf '%q ' "${cmd[@]}")"
  if [[ "$MODE" == "dry-run" ]]; then
    say "  (dry run: not executed)"
    return
  fi

  # Always execute from HOME to avoid picking up per-project Yarn / npm configuration.
  local out
  out="$(mktemp "${TMPDIR:-/tmp}/mac-cleanup.XXXXXXXX")" || return
  (cd "$HOME" && "${cmd[@]}") >"$out" 2>&1 || status=$?
  if [[ "$status" -ne 0 ]]; then
    printf '  FAILED (exit %s). Last output:\n' "$status"
    tail -n 6 "$out" | sed 's/^/    /'
    FAILED=$((FAILED + 1))
  else
    # Show warnings even on a 0 status; avoid verbose package manager logs.
    if grep -Eiq '(warning|error|skipping)' "$out"; then
      grep -Ei '(warning|error|skipping)' "$out" | tail -n 3 | sed 's/^/    /'
    fi
    SUCCEEDED=$((SUCCEEDED + 1))
  fi
  rm -f "$out"
  after="$(size_many_kb ${paths[@]+"${paths[@]}"})"
  freed=$((before - after))
  if [[ "$freed" -gt 0 ]]; then
    TOTAL_SAVED_KB=$((TOTAL_SAVED_KB + freed))
    printf '  After: %-12s Freed: %s\n' "$(human_kb "$after")" "$(human_kb "$freed")"
  elif [[ "$freed" -lt 0 ]]; then
    printf '  After: %-12s (grew by %s)\n' "$(human_kb "$after")" "$(human_kb "$((-freed))")"
  else
    printf '  After: %-12s Freed: 0 KiB\n' "$(human_kb "$after")"
  fi
}

safe_cmd_path() {
  # Tools may print error messages such as "undefined" or URLs instead of a path. Only accept absolute local paths, never root.
  local candidate="$1"
  [[ "$candidate" = /* && "$candidate" != "/" && "$candidate" != "/System" ]] || return 1
  printf '%s\n' "$candidate"
}

volume_free_kb() {
  df -Pk /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4+0}'
}

report_dir() {
  local name="$1" path="$2" kb="$3" note="${4:-}"
  printf '  %-34s %10s  %s\n' "$name" "$(human_kb "$kb")" "$path"
  [[ -n "$note" ]] && printf '      %s\n' "$note" | wrap_text
}

report_top() {
  local title="$1" dir="$2" limit="$3"
  section "$title"
  if [[ ! -d "$dir" ]]; then say "  Not found: $dir"; return; fi
  # Size only first-level entries.
  find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
    | while IFS= read -r -d '' path; do
        printf '%s\t%s\n' "$(size_kb "$path")" "$path"
      done \
    | sort -nr \
    | head -n "$limit" \
    | while IFS="$(printf '\t')" read -r k path; do
        printf '  %10s  %s\n' "$(human_kb "$k")" "$path"
      done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

say ""
say "mac-cleanup | mode=$MODE | $(date '+%Y-%m-%d %H:%M:%S')"
say "Config: ${CONFIG_FILE:-none}"
START_FREE="$(volume_free_kb)"
say "Data volume free before: $(human_kb "$START_FREE")"

if [[ "$MODE" != "scan-only" ]]; then
  section "AUTOMATIC CLEANUP"

  if has brew; then
    brew_cellar="$(brew --cellar 2>/dev/null || true)"
    brew_cache="$(brew --cache 2>/dev/null || true)"
    if safe_cmd_path "$brew_cellar" >/dev/null && safe_cmd_path "$brew_cache" >/dev/null; then
      if [[ "$MODE" == "dry-run" ]]; then
        say "Homebrew preview:"
        show_cmd "brew cleanup --dry-run --scrub --prune=all | tail -n 20"
        brew cleanup --dry-run --scrub --prune=all 2>&1 | tail -n 20
      else
        step "Homebrew cleanup" "$brew_cellar" "$brew_cache" -- brew cleanup --scrub --prune=all
      fi
    else say "  Homebrew paths unavailable: skipping"; SKIPPED=$((SKIPPED+1)); fi
  else say "  Homebrew not installed: skipping"; SKIPPED=$((SKIPPED+1)); fi

  section "RUST PROJECT TARGET DIRECTORIES"
  if [[ ${#RUST_PROJECTS[@]} -eq 0 ]]; then
    say "  No rust_projects in config: skipping"
  fi
  for project in ${RUST_PROJECTS[@]+"${RUST_PROJECTS[@]}"}; do
    if [[ ! -f "$project/Cargo.toml" ]]; then
      say "  SKIP: $project (no Cargo.toml)"; SKIPPED=$((SKIPPED+1)); continue
    fi
    if ! has cargo; then
      say "  SKIP: cargo command missing"; SKIPPED=$((SKIPPED+1)); continue
    fi
    # Cargo workspaces and CARGO_TARGET_DIR can point outside the listed project. Never clean a shared build directory.
    target="$project/target"
    discovered="$(cd "$project" && cargo metadata --no-deps --format-version 1 2>/dev/null | jq -r '.target_directory // empty' 2>/dev/null)" || discovered=""
    [[ -n "$discovered" ]] && target="$discovered"
    case "$target" in
      "$project/target"|"$project/target/"*) ;;
      *) say "  SKIP shared/external Cargo target: $target (project $project)"; SKIPPED=$((SKIPPED+1)); continue ;;
    esac
    step "cargo clean: $(basename "$project")" "$target" -- cargo clean --manifest-path "$project/Cargo.toml"
  done

  if has go; then
    go_cache="$(go env GOCACHE 2>/dev/null || true)"
    if safe_cmd_path "$go_cache" >/dev/null; then
      step "Go build cache" "$go_cache" -- go clean -cache
    fi
  fi

  if has npm; then
    npm_cache="$(npm config get cache 2>/dev/null || true)"
    if safe_cmd_path "$npm_cache" >/dev/null; then
      step "npm cache" "$npm_cache" -- npm cache clean --force
    fi
  fi

  if has yarn; then
    yarn_ver="$(cd "$HOME" && yarn --version 2>/dev/null || true)"
    if [[ "$yarn_ver" == 1.* ]]; then
      yarn_cache="$(cd "$HOME" && yarn cache dir 2>/dev/null || true)"
      if safe_cmd_path "$yarn_cache" >/dev/null; then
        step "Yarn Classic cache" "$yarn_cache" -- yarn cache clean
      fi
    else
      say "  SKIP Yarn $yarn_ver: Yarn 2+ may use project-local/zero-install caches. Review manually."
      SKIPPED=$((SKIPPED+1))
    fi
  fi

  if has pnpm; then
    pnpm_store="$(cd "$HOME" && pnpm store path 2>/dev/null || true)"
    if safe_cmd_path "$pnpm_store" >/dev/null; then
      step "pnpm unused store" "$pnpm_store" -- pnpm store prune
    fi
  fi

  if has mise; then
    mise_installs="${MISE_DATA_DIR:-$HOME/.local/share/mise}/installs"
    mise_cache="$(mise cache path 2>/dev/null || true)"
    safe_cmd_path "$mise_cache" >/dev/null || mise_cache="$HOME/.cache/mise"
    if [[ "$MODE" == "dry-run" ]]; then
      say ""
      say "mise tool version preview:"
      show_cmd "mise prune --tools --dry-run | tail -n 20"
      mise prune --tools --dry-run 2>&1 | tail -n 20
      say ""
      say "mise cache preview:"
      show_cmd "mise cache prune --dry-run | tail -n 10"
      mise cache prune --dry-run 2>&1 | tail -n 10
    else
      step "mise unused tool versions" "$mise_installs" -- mise prune --tools
      step "mise stale metadata cache" "$mise_cache" -- mise cache prune
    fi
  fi

  if has uv; then
    uv_cache="$(uv cache dir 2>/dev/null || true)"
    if safe_cmd_path "$uv_cache" >/dev/null; then
      step "uv unused cache" "$uv_cache" -- uv cache prune
    fi
  fi

  if has python3 && python3 -m pip --version >/dev/null 2>&1; then
    pip_cache="$(python3 -m pip cache dir 2>/dev/null || true)"
    if safe_cmd_path "$pip_cache" >/dev/null; then
      step "pip download/wheel cache" "$pip_cache" -- python3 -m pip cache purge
    fi
  fi

  section "CLEANUP SUMMARY"
  if [[ "$MODE" == "dry-run" ]]; then
    say "DRY RUN ONLY. No changes made. Per-item pre-clean sizes are shown above."
  else
    say "Estimated deleted from measured cache/tool directories: $(human_kb "$TOTAL_SAVED_KB")"
    say "Steps succeeded: $SUCCEEDED | failed: $FAILED | skipped: $SKIPPED"
    say "Note: reclaimed host disk space can differ (hardlinks, APFS snapshots, caches rebuilt)."
  fi
fi

section "DATA VOLUME"
END_FREE="$(volume_free_kb)"
show_cmd "df -h /System/Volumes/Data"
df -h /System/Volumes/Data 2>/dev/null || true
if [[ "$MODE" == "clean" ]]; then
  DELTA=$((END_FREE - START_FREE))
  if (( DELTA >= 0 )); then
    say "Change in available space (df): +$(human_kb "$DELTA")"
  else
    say "Change in available space (df): -$(human_kb "$((-DELTA))")"
  fi
fi

report_top "LARGEST Application Support entries (READ-ONLY)" "$HOME/Library/Application Support" 25
report_top "LARGEST ~/Library/Caches entries (READ-ONLY)" "$HOME/Library/Caches" 25
report_top "LARGEST ~/Library/Logs entries (READ-ONLY)" "$HOME/Library/Logs" 10

section "KNOWN LARGE FILE/CACHE LOCATIONS (READ-ONLY)"
if [[ ${#REPORT_PATHS[@]} -eq 0 ]]; then
  say "  No enabled report_dirs in config."
fi
if has mise; then
  REPORT_NAMES+=("mise installed tools")
  REPORT_PATHS+=("${MISE_DATA_DIR:-$HOME/.local/share/mise}/installs")
  REPORT_NOTES+=("")
fi
go_mod_cache="$(has go && go env GOMODCACHE 2>/dev/null || true)"
if [[ -n "$go_mod_cache" ]]; then
  REPORT_NAMES+=("Go module downloads")
  REPORT_PATHS+=("$go_mod_cache")
  REPORT_NOTES+=("Downloaded Go modules. 'go clean -modcache' removes them; they are re-downloaded on the next build.")
fi
REPORT_MIN_KB=102400 # Locations smaller than 100 MiB are not worth listing.
i=0
shown=0
hidden=0
while [[ $i -lt ${#REPORT_PATHS[@]} ]]; do
  kb="$(size_kb "${REPORT_PATHS[$i]}")"
  if [[ "$kb" -lt "$REPORT_MIN_KB" ]]; then
    hidden=$((hidden + 1))
  else
    [[ $shown -gt 0 ]] && say ""
    report_dir "${REPORT_NAMES[$i]}" "${REPORT_PATHS[$i]}" "$kb" "${REPORT_NOTES[$i]}"
    shown=$((shown + 1))
  fi
  i=$((i + 1))
done
if [[ $hidden -gt 0 ]]; then
  [[ $shown -gt 0 ]] && say ""
  say "  ($hidden location(s) under $(human_kb "$REPORT_MIN_KB") or missing are not shown.)"
fi

section "LARGE FILES >= 500MiB IN MODEL FOLDERS (READ-ONLY)"
if [[ ${#LARGE_FILE_DIRS[@]} -eq 0 ]]; then
  say "  No report_dirs with scan_large_files enabled in config."
fi
for p in ${LARGE_FILE_DIRS[@]+"${LARGE_FILE_DIRS[@]}"}; do
  [[ -d "$p" ]] && find "$p" -type f -size +500M -print0 2>/dev/null
done | while IFS= read -r -d '' f; do
  printf '%s\t%s\n' "$(size_kb "$f")" "$f"
done | sort -nr | head -n 15 | while IFS="$(printf '\t')" read -r k f; do
  printf '  %10s  %s\n' "$(human_kb "$k")" "$f"
done

section "DOCKER AUDIT (READ-ONLY)"
if has docker; then
  show_cmd "docker context show"
  docker context show 2>/dev/null || true
  if docker info >/dev/null 2>&1; then
    say ""
    show_cmd "docker system df"
    docker system df 2>/dev/null || true
    say ""
    show_cmd "docker buildx ls"
    docker buildx ls 2>/dev/null || true
    for builder in ${DOCKER_BUILDERS[@]+"${DOCKER_BUILDERS[@]}"}; do
      say ""
      show_cmd "docker buildx --builder $builder du | tail -n 2"
      docker buildx --builder "$builder" du 2>/dev/null | tail -n 2 || true
    done
  else say "  Docker daemon unavailable, skipping live usage."; fi
else say "  Docker CLI not installed."; fi
docker_raw="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
if [[ -f "$docker_raw" ]]; then
  say ""
  show_cmd "du -h ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
  du -h "$docker_raw" 2>/dev/null || true
fi

section "DONE"
case "$MODE" in
  dry-run) say "Dry run finished. Nothing was deleted. Run again and choose Clean to apply." ;;
  scan-only) say "Scan finished. Nothing was deleted." ;;
  clean) say "Cleanup finished." ;;
esac
say "Before removing anything else by hand (Docker, Time Machine snapshots, app data), read the \"Manual review guide\" in README.md."
