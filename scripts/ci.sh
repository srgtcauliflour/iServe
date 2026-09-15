#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
mkdir -p build
# Pick available devices instead of coupling CI to a specific simulator model/runtime.
xcrun simctl list devices available --json > build/simulators.json
python3 scripts/select_simulators.py build/simulators.json > build/destinations.txt
while IFS=' ' read -r family identifier; do
  xcodebuild test -project iServe.xcodeproj -scheme iServe \
    -destination "platform=iOS Simulator,id=$identifier" \
    -parallel-testing-enabled NO \
    -resultBundlePath "build/$family.xcresult" \
    CODE_SIGNING_ALLOWED=NO
done < build/destinations.txt
