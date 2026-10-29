#!/usr/bin/env bash
set -euo pipefail

# Shared by the release workflow and Windows PR smoke. Racket's distribute
# layout is OS-specific; Windows normally places the executable at the output
# root, while Unix/macOS produce bin/. Distribute into stage/bin on Windows
# (not a post-distribution mv), so Racket's patched library lookup stays valid.
if [ "${RUNNER_OS:-}" = "Windows" ]; then
  exe="build/flashpilot.exe"
  destination="stage/bin"
else
  exe="build/flashpilot"
  destination="stage"
fi

mkdir -p build
raco exe -o "$exe" app/cli.rkt
chmod u+w "$exe"
raco distribute "$destination" "$exe"

# Keep sample firmware and plans separate from the runtime layout.
cp -R examples stage/examples

if [ "${RUNNER_OS:-}" = "Windows" ]; then
  test -f stage/bin/flashpilot.exe
  test ! -e stage/flashpilot.exe
else
  test -f stage/bin/flashpilot
fi
