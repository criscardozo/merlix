#!/usr/bin/env bash
# Downloads the Zig toolchain Ghostty needs into .build/tools, verified against a
# pinned SHA-256. Nothing is installed globally. Prints the path to the zig binary.
set -euo pipefail

ZIG_VERSION="0.16.0"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tools="${root}/.build/tools"
dest="${tools}/zig-${ZIG_VERSION}"

case "$(uname -m)" in
  arm64)
    arch="aarch64"
    sha256="b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
    ;;
  x86_64)
    arch="x86_64"
    sha256="0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7"
    ;;
  *)
    echo "error: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

if [ -x "${dest}/zig" ]; then
  echo "${dest}/zig"
  exit 0
fi

name="zig-${arch}-macos-${ZIG_VERSION}"
tarball="${tools}/${name}.tar.xz"
mkdir -p "${tools}"

echo "Downloading Zig ${ZIG_VERSION} (${arch})..." >&2
curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/${name}.tar.xz" -o "${tarball}"

actual="$(shasum -a 256 "${tarball}" | awk '{print $1}')"
if [ "${actual}" != "${sha256}" ]; then
  rm -f "${tarball}"
  echo "error: Zig tarball checksum mismatch (got ${actual})" >&2
  exit 1
fi

tar -xf "${tarball}" -C "${tools}"
rm -f "${tarball}"
mv "${tools}/${name}" "${dest}"
echo "${dest}/zig"
