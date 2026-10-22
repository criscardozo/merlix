#!/usr/bin/env bash
# Captures the Merlix window to a PNG (default: .build/screenshot.png).
# Window captures do not include what is behind the window, so translucency
# and vibrancy show as flat grey here; judge those by eye.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-${root}/.build/screenshot.png}"

id="$(swift - <<'EOF'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in windows where (w[kCGWindowOwnerName as String] as? String) == "Merlix"
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] as! Int)
    break
}
EOF
)"

if [ -z "${id}" ]; then
  echo "error: no Merlix window on screen" >&2
  exit 1
fi

mkdir -p "$(dirname "${out}")"
screencapture -x -o -l "${id}" "${out}"
echo "${out}"
