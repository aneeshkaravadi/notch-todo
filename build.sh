#!/bin/zsh
# Builds NotchTodo.app. `./build.sh install` also copies it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/NotchTodo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
clang -O2 -fobjc-arc -Wall -mmacosx-version-min=14.0 \
  -framework Cocoa -framework QuartzCore -framework ServiceManagement \
  NotchTodo.m -o "$APP/Contents/MacOS/NotchTodo"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x NotchTodo || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/NotchTodo.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/NotchTodo.app
  echo "Installed and launched ~/Applications/NotchTodo.app"
fi
