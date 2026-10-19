// Detached launcher for the DSH Web UI.
//
// Three things had to be true at once, and the obvious route satisfies none of
// them together:
//
//   Detached, so the server outlives every pane, the window and this process.
//   Silent, because a console window flashing up is the whole thing the user
//   sees — and they close it, which kills the server they asked for.
//   Writing its access URL somewhere: `dsh web` prints it, with a fresh token,
//   to stdout only, and without that token the Web UI opens an address that
//   answers 401.
//
// Running `npx ...` through a shell loses the output. npx is a `.cmd` shim whose
// body chains commands with `&`, and that swallows a redirect the way it would
// swallow anything else on the line. So no command line is built here: npx is
// used only to resolve and populate the package cache, and the server is then
// started as the real `node` entry point behind it.

import { spawn, spawnSync } from "node:child_process";
import { accessSync, closeSync, mkdirSync, openSync, readdirSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const [, , rawArgs, logPath, spec] = process.argv;

// Kept as a string so the argument vector survives the boundary unchanged: the
// caller splits it, and DSH reads its flags positionally.
const args = rawArgs === "" ? [] : rawArgs.split(" ");

if (rawArgs === undefined || !logPath || !spec) {
  console.error("usage: launch.mjs <args> <log-path> <npm-spec>");
  process.exit(2);
}

mkdirSync(dirname(logPath), { recursive: true });

// Resolution only. A first run downloads the package here, which is why this is
// a separate, synchronous step instead of being folded into the server launch.
const resolved = spawnSync("npx", ["-y", spec, "--version"], {
  stdio: ["ignore", "ignore", "pipe"],
  shell: true,
  windowsHide: true,
  encoding: "utf8",
});

if (resolved.status !== 0) {
  console.error(
    "could not resolve " + spec + ": " + (resolved.stderr || "").trim(),
  );
  process.exit(1);
}

// npx caches by exact spec under a content-addressed directory, so the entry
// point is whichever cached copy is most recent.
const bin = findEntryPoint(spec);
if (!bin) {
  console.error("resolved " + spec + " but found no entry point in the npx cache");
  process.exit(1);
}

// stdout and stderr are the log file's own descriptor. The child inherits it,
// so the log keeps being written after this process is gone — which matters
// because the URL is printed once the server is listening, minutes after a first
// run starts downloading. Piping instead cannot work: a detached child does not
// hand its pipes to a parent that has already exited.
const fd = openSync(logPath, "w");

const child = spawn(process.execPath, [bin, ...args], {
  detached: true,
  windowsHide: true,
  stdio: ["ignore", fd, fd],
});

child.on("error", (error) => {
  console.error(String(error));
});

child.unref();

// Close our copy without closing the child's; both hold the same descriptor.
closeSync(fd);

function findEntryPoint(npmSpec) {
  // `@deepseek-ai/dsh@latest` names a version range; the cache directory is
  // named after the bare package, so the range is dropped before looking.
  const spec = npmSpec.replace(/@[^@/]*$/, "");

  // npm's cache is configurable, and `npm_config_cache` is not exported into
  // ordinary processes, so npm itself is asked where it keeps things. Guessing
  // the default would silently pick a different cache than the one npx just
  // populated — and a cache directory npx never writes to.
  const cache = spawnSync("npm", ["config", "get", "cache"], {
    stdio: ["ignore", "pipe", "ignore"],
    shell: true,
    windowsHide: true,
    encoding: "utf8",
  }).stdout?.trim();

  const root = join(cache || join(homedir(), "AppData", "Local", "npm-cache"), "_npx");

  let entries;
  try {
    entries = readdirSync(root);
  } catch {
    return null;
  }

  let newest = null;
  let newestTime = -1;
  for (const dir of entries) {
    const candidate = join(root, dir, "node_modules", ...spec.split("/"), "lib", "bin.js");
    try {
      accessSync(candidate);
      const time = statSync(candidate).mtimeMs;
      if (time > newestTime) {
        newestTime = time;
        newest = candidate;
      }
    } catch {
      // Not this directory's copy of the package.
    }
  }
  return newest;
}
