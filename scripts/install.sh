#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON_PATH="$ROOT/daemon/interceptor-daemon"
TEMPLATE_PATH="$ROOT/daemon/com.interceptor.host.json"
GENERATED_DIR="$ROOT/daemon/.generated"
GENERATED_MANIFEST="$GENERATED_DIR/com.interceptor.host.json"
EXTENSION_DIR="$ROOT/extension/dist"
INSTALL_BRIDGE_SCRIPT="$ROOT/scripts/install-bridge.sh"

# ── Parse flags ────────────────────────────────────────────────────────────────
SKIP_EXTENSION=0
BROWSER=""
PROFILE=""
LIST_PROFILES=0
MODE=""           # "" | "browser-only" | "full"
DRY_RUN="${INSTALL_DRY_RUN:-0}"
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --skip-extension) SKIP_EXTENSION=1 ;;
    --brave)  BROWSER="brave" ;;
    --chrome) BROWSER="chrome" ;;
    --profile)
      i=$((i + 1))
      PROFILE="${!i}"
      ;;
    --profile=*) PROFILE="${arg#--profile=}" ;;
    --profiles) LIST_PROFILES=1 ;;
    --browser-only)
      if [[ "$MODE" == "full" ]]; then
        echo "ERROR: --browser-only and --full are mutually exclusive." >&2
        exit 1
      fi
      MODE="browser-only" ;;
    --full)
      if [[ "$MODE" == "browser-only" ]]; then
        echo "ERROR: --browser-only and --full are mutually exclusive." >&2
        exit 1
      fi
      MODE="full" ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown flag: $arg" >&2
       echo ""
       echo "Usage: bash scripts/install.sh [MODE] [BROWSER] [OPTIONS]"
       echo ""
       echo "Modes (mutually exclusive; if omitted, you'll be prompted):"
       echo "  --browser-only    Install CLI + daemon + extension only. No macOS bridge."
       echo "                    Smallest footprint, no TCC prompts."
       echo "  --full            Browser-only AND macOS bridge (LaunchAgent + AX +"
       echo "                    ScreenCaptureKit + Apple Events). macOS only."
       echo ""
       echo "Browser:"
       echo "  --brave           Target Brave Browser"
       echo "  --chrome          Target Google Chrome"
       echo "  --profile <name>  Profile directory name (e.g. \"Default\", \"Profile 2\")"
       echo "  --profiles        List available profiles and exit"
       echo ""
       echo "Options:"
       echo "  --skip-extension  Only install native messaging (skip extension load)"
       echo "  --dry-run         Print steps without executing them"
       exit 1 ;;
  esac
  i=$((i + 1))
done

# ── List profiles ──────────────────────────────────────────────────────────────
if [[ "$LIST_PROFILES" == "1" ]]; then
  if [[ -z "$BROWSER" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      if [[ -d "/Applications/Brave Browser.app" ]]; then BROWSER="brave"
      elif [[ -d "/Applications/Google Chrome.app" ]]; then BROWSER="chrome"
      fi
    else
      if command -v brave-browser >/dev/null 2>&1 || command -v brave >/dev/null 2>&1; then BROWSER="brave"
      elif command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then BROWSER="chrome"
      fi
    fi
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    case "$BROWSER" in
      brave)  PROFILE_ROOT="$HOME/Library/Application Support/BraveSoftware/Brave-Browser" ;;
      chrome) PROFILE_ROOT="$HOME/Library/Application Support/Google/Chrome" ;;
      *) echo "No supported browser found."; exit 1 ;;
    esac
  else
    case "$BROWSER" in
      brave)  PROFILE_ROOT="$HOME/.config/BraveSoftware/Brave-Browser" ;;
      chrome) PROFILE_ROOT="$HOME/.config/google-chrome" ;;
      *) echo "No supported browser found."; exit 1 ;;
    esac
  fi

  echo "Available profiles:"
  echo ""
  printf "  %-20s %s\n" "DIRECTORY" "DISPLAY NAME"
  printf "  %-20s %s\n" "---------" "------------"
  for dir in "$PROFILE_ROOT"/*/; do
    name=$(basename "$dir")
    if [[ -f "$dir/Preferences" ]]; then
      if command -v plutil >/dev/null 2>&1; then
        display=$(plutil -extract profile.name raw -o - "$dir/Preferences" 2>/dev/null || echo "(unknown)")
      else
        display=$(python3 -c "import json,sys; d=json.load(open('$dir/Preferences')); print(d.get('profile',{}).get('name','(unknown)'))" 2>/dev/null || echo "(unknown)")
      fi
      printf "  %-20s %s\n" "$name" "$display"
    fi
  done
  echo ""
  echo "Usage: bash scripts/install.sh --brave --profile \"Profile 2\""
  exit 0
fi

# ── Mode resolution ────────────────────────────────────────────────────────────
# If neither --browser-only nor --full was passed, prompt interactively.
# Default: macOS → "full", anything else → "browser-only" (full mode is mac-only).
if [[ -z "$MODE" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    DEFAULT_MODE="full"
  else
    DEFAULT_MODE="browser-only"
  fi

  # In dry-run / non-interactive contexts, fall back to the platform default
  # rather than blocking on stdin.
  if [[ "$DRY_RUN" == "1" || ! -t 0 ]]; then
    MODE="$DEFAULT_MODE"
    echo "==> Mode not specified; defaulting to '$MODE' (non-interactive)."
  else
    echo "Choose install mode:"
    echo "  browser-only  CLI + daemon + extension. No macOS bridge."
    echo "                No TCC prompts (Screen Recording, Accessibility, etc.)."
    echo "  full          Browser-only PLUS the macOS Swift bridge."
    echo "                Adds 'interceptor macos *' commands; macOS will prompt"
    echo "                for Screen Recording / Accessibility / Apple Events on"
    echo "                first use."
    echo ""
    read -r -p "Mode [browser-only/full] (default: $DEFAULT_MODE): " ANSWER
    ANSWER="${ANSWER:-$DEFAULT_MODE}"
    case "$ANSWER" in
      browser-only|full) MODE="$ANSWER" ;;
      *)
        echo "Unrecognized mode '$ANSWER'. Use --browser-only or --full." >&2
        exit 1 ;;
    esac
  fi
fi

if [[ "$MODE" == "full" && "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: --full mode is macOS only (the Swift bridge is mac-only)." >&2
  echo "       Use --browser-only on this platform." >&2
  exit 1
fi

echo "==> Mode: $MODE"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> DRY RUN — no files will be created or modified."
fi

# ── Browser resolution ────────────────────────────────────────────────────────
# If neither --chrome nor --brave was passed, prompt or fall back to a
# deterministic default in non-interactive contexts. Valid resolved values:
#   "chrome" | "brave" | "both"
if [[ -z "$BROWSER" ]]; then
  CHROME_INSTALLED=0
  BRAVE_INSTALLED=0
  [[ -d "/Applications/Google Chrome.app" ]] && CHROME_INSTALLED=1
  [[ -d "/Applications/Brave Browser.app" ]] && BRAVE_INSTALLED=1

  if (( CHROME_INSTALLED + BRAVE_INSTALLED == 0 )); then
    echo "ERROR: No supported browser found in /Applications/." >&2
    echo "       Install Google Chrome or Brave Browser, then re-run." >&2
    exit 1
  fi

  if (( CHROME_INSTALLED + BRAVE_INSTALLED == 1 )); then
    [[ "$CHROME_INSTALLED" == "1" ]] && BROWSER="chrome" || BROWSER="brave"
    echo "==> Browser: $BROWSER (only supported browser found)"
  elif [[ "$DRY_RUN" == "1" || ! -t 0 ]]; then
    BROWSER="chrome"
    echo "==> Browser not specified; defaulting to '$BROWSER' (non-interactive)."
  else
    echo ""
    echo "Choose target browser:"
    echo "  chrome   Google Chrome"
    echo "  brave    Brave Browser"
    echo "  both     Install for both"
    echo ""
    read -r -p "Browser [chrome/brave/both] (default: chrome): " ANSWER
    ANSWER="${ANSWER:-chrome}"
    case "$ANSWER" in
      chrome|brave|both) BROWSER="$ANSWER" ;;
      *)
        echo "Unrecognized browser '$ANSWER'. Use chrome, brave, or both." >&2
        exit 1 ;;
    esac
  fi
fi

echo "==> Browser: $BROWSER"

# Helper that runs a step or prints it under --dry-run.
run_step() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "    DRY: $*"
  else
    eval "$@"
  fi
}

# ── Step 1: Generate native messaging manifest ────────────────────────────────
echo "==> [browser] Generating native messaging manifest..."
if [[ "$DRY_RUN" == "1" ]]; then
  echo "    DRY: mkdir -p $GENERATED_DIR"
  echo "    DRY: sed __DAEMON_PATH__ -> $DAEMON_PATH > $GENERATED_MANIFEST"
else
  mkdir -p "$GENERATED_DIR"
  ESCAPED_DAEMON_PATH="$(printf '%s' "$DAEMON_PATH" | sed 's/[&|\\]/\\&/g')"
  sed "s|__DAEMON_PATH__|$ESCAPED_DAEMON_PATH|g" "$TEMPLATE_PATH" > "$GENERATED_MANIFEST"
fi

# ── Step 2: Install native messaging symlinks for chosen browser(s) ───────────
echo "==> [browser] Installing native messaging symlink(s)..."
NM_DIRS=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  case "$BROWSER" in
    chrome) NM_DIRS+=("$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts") ;;
    brave)  NM_DIRS+=("$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts") ;;
    both)
      NM_DIRS+=("$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts")
      NM_DIRS+=("$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts")
      ;;
  esac
else
  case "$BROWSER" in
    chrome) NM_DIRS+=("$HOME/.config/google-chrome/NativeMessagingHosts") ;;
    brave)  NM_DIRS+=("$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts") ;;
    both)
      NM_DIRS+=("$HOME/.config/google-chrome/NativeMessagingHosts")
      NM_DIRS+=("$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts")
      ;;
  esac
fi

for dir in "${NM_DIRS[@]}"; do
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "    DRY: mkdir -p $dir"
    echo "    DRY: ln -sfn $GENERATED_MANIFEST $dir/com.interceptor.host.json"
  else
    mkdir -p "$dir"
    ln -sfn "$GENERATED_MANIFEST" "$dir/com.interceptor.host.json"
    case "$dir" in
      *Google/Chrome*) echo "    Chrome: $dir/com.interceptor.host.json" ;;
      *Brave-Browser*) echo "    Brave:  $dir/com.interceptor.host.json" ;;
    esac
  fi
done

# ── Step 3: Load extension into browser via --load-extension ──────────────────
# Takes one arg: "chrome" | "brave". Reads $SKIP_EXTENSION, $PROFILE, $DRY_RUN,
# $EXTENSION_DIR from the surrounding scope.
load_extension() {
  local target="$1"

  if [[ "$SKIP_EXTENSION" == "1" ]]; then
    echo ""
    echo "==> [browser] Skipping extension loading (--skip-extension)"
    return 0
  fi

  if [[ ! -d "$EXTENSION_DIR" && "$DRY_RUN" != "1" ]]; then
    echo ""
    echo "==> Extension not built yet. Run: bash scripts/build.sh"
    echo "    Then re-run this script."
    exit 1
  fi

  local BROWSER_APP BROWSER_BIN BROWSER_NAME
  if [[ "$(uname -s)" == "Darwin" ]]; then
    case "$target" in
      brave)
        BROWSER_APP="/Applications/Brave Browser.app"
        BROWSER_BIN="$BROWSER_APP/Contents/MacOS/Brave Browser"
        BROWSER_NAME="Brave"
        ;;
      chrome)
        BROWSER_APP="/Applications/Google Chrome.app"
        BROWSER_BIN="$BROWSER_APP/Contents/MacOS/Google Chrome"
        BROWSER_NAME="Chrome"
        ;;
      *)
        echo "ERROR: load_extension called with unknown browser '$target'." >&2
        return 1 ;;
    esac
  else
    case "$target" in
      brave)
        BROWSER_BIN="$(command -v brave-browser 2>/dev/null || command -v brave 2>/dev/null || echo "")"
        BROWSER_NAME="Brave"
        ;;
      chrome)
        BROWSER_BIN="$(command -v google-chrome 2>/dev/null || command -v google-chrome-stable 2>/dev/null || echo "")"
        BROWSER_NAME="Chrome"
        ;;
      *)
        echo "ERROR: load_extension called with unknown browser '$target'." >&2
        return 1 ;;
    esac
    BROWSER_APP="$BROWSER_BIN"
    if [[ -z "$BROWSER_BIN" ]]; then
      echo "ERROR: $BROWSER_NAME binary not found on PATH." >&2
      echo "       Install $BROWSER_NAME or load the extension manually from $EXTENSION_DIR" >&2
      return 1
    fi
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "==> [browser] DRY: would launch $BROWSER_NAME --load-extension=$EXTENSION_DIR"
    return 0
  fi

  # Check if browser is already running
  local BROWSER_RUNNING=0
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if pgrep -f "$BROWSER_BIN" >/dev/null 2>&1; then BROWSER_RUNNING=1; fi
  else
    if pgrep -f "$(basename "$BROWSER_BIN")" >/dev/null 2>&1; then BROWSER_RUNNING=1; fi
  fi

  if [[ "$BROWSER_RUNNING" == "1" ]]; then
    echo ""
    echo "==> $BROWSER_NAME is already running."
    echo "    To load the extension without browser intervention, $BROWSER_NAME must be restarted."
    echo ""
    echo "    Option 1 — Quit $BROWSER_NAME, then re-run this script."
    echo ""
    echo "    Option 2 — Load manually:"
    echo "      1. Open chrome://extensions"
    echo "      2. Enable Developer Mode"
    echo "      3. Load unpacked → $EXTENSION_DIR"
    echo ""
    echo "    Option 3 — Force restart (will restore tabs on relaunch):"
    read -p "      Quit $BROWSER_NAME and relaunch with extension? [y/N] " CONFIRM
    if [[ "${CONFIRM:-n}" == "y" || "${CONFIRM:-n}" == "Y" ]]; then
      echo "    Quitting $BROWSER_NAME..."
      if [[ "$(uname -s)" == "Darwin" ]]; then
        osascript -e "tell application \"$BROWSER_NAME Browser\" to quit" 2>/dev/null || \
        osascript -e "tell application \"$BROWSER_NAME\" to quit" 2>/dev/null || true
      else
        pkill -f "$(basename "$BROWSER_BIN")" 2>/dev/null || true
      fi
      sleep 2
      for j in {1..10}; do
        if ! pgrep -f "$BROWSER_BIN" >/dev/null 2>&1; then break; fi
        sleep 1
      done
    else
      echo "    Skipping extension loading."
      return 0
    fi
  fi

  if [[ "$target" == "chrome" ]]; then
    echo ""
    echo "==> Google Chrome ignores --load-extension in branded desktop builds."
    echo "    Use one of these paths instead:"
    echo "      1. Developer flow: open chrome://extensions, enable Developer Mode,"
    echo "         then Load unpacked -> $EXTENSION_DIR"
    echo ""
    echo "    Native messaging metadata has already been installed."
    return 0
  fi

  echo ""
  echo "==> [browser] Launching $BROWSER_NAME with --load-extension..."
  echo "    Extension: $EXTENSION_DIR"

  # Build launch args
  local LAUNCH_ARGS=(--load-extension="$EXTENSION_DIR")
  if [[ -n "$PROFILE" ]]; then
    LAUNCH_ARGS+=(--profile-directory="$PROFILE")
    echo "    Profile:   $PROFILE"
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    open -a "$BROWSER_APP" --args "${LAUNCH_ARGS[@]}"
  else
    nohup "$BROWSER_BIN" "${LAUNCH_ARGS[@]}" >/dev/null 2>&1 &
    disown
  fi

  echo ""
  echo "==> Extension loaded into $BROWSER_NAME."
  echo "    Extension ID: hkjbaciefhhgekldhncknbjkofbpenng"
  if [[ -n "$PROFILE" ]]; then
    echo "    Profile: $PROFILE"
  fi
}

case "$BROWSER" in
  chrome|brave) load_extension "$BROWSER" ;;
  both)
    load_extension chrome
    load_extension brave
    ;;
esac

# ── Step 4 (full mode only): Install Swift bridge ──────────────────────────────
# browser-only MUST NOT touch the LaunchAgent or .app bundle.
if [[ "$MODE" == "browser-only" ]]; then
  echo ""
  echo "==> Done. Installed in browser-only mode."
  echo "    No macOS bridge installed; no LaunchAgent written."
  echo "    Test:    interceptor status   (expect 'mode: browser-only')"
  echo ""
  echo "    To upgrade later:    interceptor upgrade --full"
  exit 0
fi

# MODE == "full" past this point.
echo ""
echo "==> [bridge] Chaining into install-bridge.sh..."
if [[ "$DRY_RUN" == "1" ]]; then
  echo "    DRY: bash $INSTALL_BRIDGE_SCRIPT"
  echo "    DRY: would write ~/Library/LaunchAgents/com.interceptor.bridge.plist"
  echo "    DRY: would lsregister ~/.local/share/interceptor/interceptor-bridge.app"
  echo "    DRY: would launchctl bootstrap gui/$(id -u 2>/dev/null || echo "<uid>")"
  echo ""
  echo "==> DRY-RUN complete (full mode)."
  exit 0
fi

if [[ ! -x "$INSTALL_BRIDGE_SCRIPT" && ! -f "$INSTALL_BRIDGE_SCRIPT" ]]; then
  echo "ERROR: $INSTALL_BRIDGE_SCRIPT not found." >&2
  echo "       Build the bridge first: bash scripts/build-bridge.sh" >&2
  exit 1
fi

bash "$INSTALL_BRIDGE_SCRIPT"

echo ""
echo "==> Done. Installed in full computer-use mode."
echo "    Test:    interceptor status   (expect 'mode: full')"
echo "    First 'interceptor macos screenshot' will prompt for Screen Recording."
echo "    First 'interceptor macos act' will prompt for Accessibility."
echo "    First 'interceptor macos intent dispatch' will prompt for Apple Events."
