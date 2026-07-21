#!/usr/bin/env bash
#
# deploy-phone.sh — Install a standalone RELEASE build of Hooplab onto your
# iPhone over the cable. Once installed you can UNPLUG and use the app anywhere,
# no laptop and no VSCode required.
#
# Free Apple account note: the build is signed with a 7-day certificate, so the
# app stops launching ~1 week after each install. Just plug in and re-run this
# script to get another 7 days. (A paid Apple Developer account + TestFlight
# removes the cable and the 7-day limit — ask Claude to set that up.)
#
# Usage:  ./deploy-phone.sh
#
set -euo pipefail
cd "$(dirname "$0")"

echo "🔍 Looking for a connected iPhone…"

DEVICE_ID="$(flutter devices --machine 2>/dev/null | python3 -c '
import sys, json
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
phones = [d for d in devices
          if str(d.get("targetPlatform", "")).startswith("ios")
          and d.get("emulator") is False]
print(phones[0]["id"] if phones else "")
')"

if [ -z "$DEVICE_ID" ]; then
  echo ""
  echo "❌ No iPhone detected."
  echo "   • Plug your iPhone into this Mac with a cable."
  echo "   • Unlock the phone and tap 'Trust This Computer' if asked."
  echo "   • Then run ./deploy-phone.sh again."
  exit 1
fi

echo "📱 Found iPhone: $DEVICE_ID"
echo "🔨 Building the release app and installing it (a few minutes the first time)…"
echo ""

flutter install --release -d "$DEVICE_ID"

echo ""
echo "✅ Done! Hooplab is now installed as a standalone app."
echo "   You can unplug the phone and use it anywhere for ~7 days."
echo "   When it stops opening, plug in and run ./deploy-phone.sh again."
