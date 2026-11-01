#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc "$PROJECT_ROOT/NotchBeat/Core/IslandLogic.swift" "$PROJECT_ROOT/Tests/CoreChecks.swift" -o "$CHECK_DIR/checks"
"$CHECK_DIR/checks"
xcrun swiftc "$PROJECT_ROOT/NotchBeat/Core/IslandLogic.swift" "$PROJECT_ROOT/NotchBeat/Preferences.swift" "$PROJECT_ROOT/Tests/PreferencesChecks.swift" -o "$CHECK_DIR/preferences"
"$CHECK_DIR/preferences"
