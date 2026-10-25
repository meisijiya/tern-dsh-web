#!/usr/bin/env bash
# Runs the launch-path harness against main.luau with the official luau CLI.
#
# The CLI has no read, no io and no os.getenv, so the plugin's source is
# concatenated into the harness: the harness holds the tern stub, the plugin
# holds the code under test, and the assertions live in the harness.
#
# Usage: test/build.sh [path-to-luau]
# The default is $TERNS_LUAU, then a `luau` on PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"
runner="$here/run_tests.luau"
out="${TMPDIR:-/tmp}/tern-dsh-web-tests.luau"

luau="${1:-${TERNS_LUAU:-}}"
if [[ -z "$luau" ]]; then
	if command -v luau >/dev/null 2>&1; then
		luau="$(command -v luau)"
	else
		# No machine-specific fallback: a path baked in here silently stops
		# matching for everyone who clones, which reads as a broken build
		# script rather than a missing CLI.
		echo "no luau CLI: pass one as \$1 or set \$TERNS_LUAU" >&2
		echo "  download: https://github.com/luau-lang/luau/releases" >&2
		exit 1
	fi
fi

python3 - "$runner" "$repo/main.luau" "$out" <<'PY'
import sys

runner_path, plugin_path, out_path = sys.argv[1:4]

with open(runner_path, encoding="utf-8") as fh:
    runner = fh.read()
with open(plugin_path, encoding="utf-8") as fh:
    plugin = fh.read()

ANCHOR = "return [[SOURCE]]"
if ANCHOR not in runner:
    sys.exit("run_tests.luau lost its source anchor")

# A long string breaks on the ]] sequence, and the plugin's source has to
# survive the concatenation unchanged.
if "]]" in plugin:
    sys.exit("main.luau contains ]] which cannot go into a long string")

script = runner.replace(ANCHOR, "return [[" + plugin + "]]", 1)

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(script)
PY

# A native Windows CLI cannot open a POSIX path. Git Bash converts one on its
# own, WSL needs wslpath and Cygwin has cygpath; a Linux CLI is left alone.
arg="$out"
case "$luau" in
	[A-Za-z]:* | *.exe)
		if command -v cygpath >/dev/null 2>&1; then
			arg="$(cygpath -w "$out")"
		elif command -v wslpath >/dev/null 2>&1; then
			arg="$(wslpath -w "$out")"
		fi
		;;
esac

"$luau" "$arg"
