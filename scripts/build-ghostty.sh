#!/usr/bin/env bash
# Builds GhosttyKit.xcframework plus Ghostty's runtime resources (themes, shell
# integration, terminfo) from the pinned ThirdParty/ghostty submodule into
# .build/ghostty. Skips the build when nothing it depends on has changed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ghostty="${root}/ThirdParty/ghostty"
out="${root}/.build/ghostty"
stamp="${out}/.commit"

if [ ! -f "${ghostty}/build.zig" ]; then
  git -C "${root}" submodule update --init ThirdParty/ghostty
fi

commit="$(git -C "${ghostty}" rev-parse HEAD)"
# A pull that moves the submodule does not check it out; say so rather than
# build the old one. (While bumping it, the checkout is ahead on purpose.)
recorded="$(git -C "${root}" ls-tree HEAD ThirdParty/ghostty | awk '{print $3}')"
if [ -n "${recorded}" ] && [ "${recorded}" != "${commit}" ]; then
  echo "warning: ThirdParty/ghostty is at ${commit:0:9}, the repo records ${recorded:0:9}." >&2
  echo "         Run: git submodule update ThirdParty/ghostty" >&2
fi

# Rebuild when the commit, the Zig version or this script changes.
zig_version="$(sed -n 's/^ZIG_VERSION="\(.*\)"$/\1/p' "${root}/scripts/bootstrap-zig.sh")"
key="${commit} zig-${zig_version} $(shasum -a 256 "${BASH_SOURCE[0]}" | cut -c1-12)"
if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${key}" ] &&
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
printf '%s\n' "${key}" > "${stamp}"
echo "GhosttyKit ready at ${out}"
