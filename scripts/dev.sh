#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/.deriveddata"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Octodot.app"
APP_BINARY="$APP_PATH/Contents/MacOS/Octodot"
APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
POLL_SECONDS="${POLL_SECONDS:-1}"
FIRST_RUN_MODE=0

print_usage() {
  cat <<'EOF'
Usage:
  scripts/dev.sh              Build once, launch Octodot, then relaunch it after later builds.
  scripts/dev.sh --build      Build and relaunch once.
  scripts/dev.sh --watch      Watch the built app and relaunch when a new build lands.
  scripts/dev.sh --first-run  Launch Octodot in clean first-run mode for QA.

Notes:
  - The app is built into .deriveddata so the bundle path stays stable.
  - Debug builds cache the token locally to avoid repeated keychain prompts.
  - First-run mode skips saved auth and preferences without touching real local data.
EOF
}

timestamp_for() {
  local path="$1"
  if [[ -e "$path" ]]; then
    /usr/bin/stat -f '%m' "$path"
  else
    echo 0
  fi
}

wait_for_app_exit() {
  local attempts=0
  while /usr/bin/pgrep -x Octodot >/dev/null 2>&1; do
    (( attempts += 1 ))
    if (( attempts > 40 )); then
      /usr/bin/pkill -x Octodot >/dev/null 2>&1 || true
      break
    fi
    /bin/sleep 0.25
  done
}

wait_for_build_settle() {
  local stable_count=0
  local previous_binary=0
  local previous_bundle=0
  local previous_plist=0

  while (( stable_count < 3 )); do
    local current_binary current_bundle current_plist
    current_binary="$(timestamp_for "$APP_BINARY")"
    current_bundle="$(timestamp_for "$APP_PATH")"
    current_plist="$(timestamp_for "$APP_INFO_PLIST")"

    if [[ "$current_binary" != "0" && "$current_binary" == "$previous_binary" && "$current_bundle" == "$previous_bundle" && "$current_plist" == "$previous_plist" ]]; then
      (( stable_count += 1 ))
    else
      stable_count=0
    fi

    previous_binary="$current_binary"
    previous_bundle="$current_bundle"
    previous_plist="$current_plist"
    /bin/sleep 0.5
  done
}

quit_app() {
  /usr/bin/osascript -e 'tell application id "com.octodot.app" to quit' >/dev/null 2>&1 || true
  wait_for_app_exit
}

launch_app() {
  local attempts=0
  local open_args=()
  if (( FIRST_RUN_MODE )); then
    open_args=(--args --first-run)
  fi
  while true; do
    if /usr/bin/open "$APP_PATH" "${open_args[@]}"; then
      return 0
    fi

    (( attempts += 1 ))
    if (( attempts >= 8 )); then
      return 1
    fi

    echo "Launch failed, retrying..."
    /bin/sleep 1
  done
}

restart_app() {
  [[ -d "$APP_PATH" ]] || return 1
  wait_for_build_settle
  quit_app
  launch_app
}

build_app() {
  (
    cd "$ROOT_DIR"
    xcodebuild \
      -project Octodot.xcodeproj \
      -scheme Octodot \
      -configuration Debug \
      -derivedDataPath "$DERIVED_DATA_PATH" \
      build
  )
}

build_and_restart() {
  build_app
  restart_app
}

watch_build_output() {
  local last_seen
  last_seen="$(timestamp_for "$APP_BINARY")"

  while true; do
    /bin/sleep "$POLL_SECONDS"
    local current
    current="$(timestamp_for "$APP_BINARY")"

    if [[ "$current" != "$last_seen" && "$current" != "0" ]]; then
      echo "Detected a new build. Relaunching Octodot..."
      if restart_app; then
        last_seen="$current"
      else
        echo "Relaunch failed; watcher will keep waiting for the next build."
      fi
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --first-run)
      FIRST_RUN_MODE=1
      shift
      ;;
    *)
      break
      ;;
  esac
done

case "${1:-}" in
  -h|--help)
    print_usage
    ;;
  --build)
    build_and_restart
    ;;
  --watch)
    watch_build_output
    ;;
  "")
    build_and_restart
    echo "Watching $APP_BINARY for new builds. Press Ctrl-C to stop."
    watch_build_output
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
