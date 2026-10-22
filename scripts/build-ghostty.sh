#!/usr/bin/env bash
# Builds GhosttyKit.xcframework plus Ghostty's runtime resources (themes, shell
# integration, terminfo) from the pinned ThirdParty/ghostty submodule into
# .build/ghostty. Skips the build when the submodule commit has not changed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty="${root}/ThirdParty/ghostty"
out="${root}/.build/ghostty"
stamp="${out}/.commit"

if [ ! -f "${ghostty}/build.zig" ]; then
  git -C "${root}" submodule update --init ThirdParty/ghostty
fi

commit="$(git -C "${ghostty}" rev-parse HEAD)"
if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${commit}" ] &&
  [ -d "${out}/GhosttyKit.xcframework" ] && [ -d "${out}/share/ghostty" ]; then
  echo "GhosttyKit is up to date (${commit:0:9})"
  exit 0
fi

zig="$("${root}/scripts/bootstrap-zig.sh")"

echo "Building GhosttyKit from ${commit:0:9}..."
cd "${ghostty}"
"${zig}" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Dsentry=false \
  --prefix "${out}" \
  --cache-dir "${root}/.build/zig-cache" \
  --global-cache-dir "${root}/.build/zig-global-cache"

rsync -a --delete "${ghostty}/macos/GhosttyKit.xcframework/" "${out}/GhosttyKit.xcframework/"
printf '%s\n' "${commit}" > "${stamp}"
echo "GhosttyKit ready at ${out}"
