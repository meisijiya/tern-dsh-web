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
// The package is the globally installed one: `npm i -g @deepseek-ai/dsh`. That
// is the same copy the `dsh` command runs, so `dsh plugin add …` in a terminal
// and the server this launches can never be two different versions — which is
// exactly what happened while an npx cache copy sat alongside it, since nothing
// tied the two lifetimes together.
//
// The entry point is started through `node` rather than through the `dsh.cmd`
// shim: a shim chains its commands with `&`, which swallows a stdout redirect,
// and the launch URL has to survive to be read back.

import { spawn, spawnSync } from "node:child_process";
import { accessSync, closeSync, mkdirSync, openSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const [, , rawArgs, logPath] = process.argv;

// Kept as a string so the argument vector survives the boundary unchanged: the
// caller splits it, and DSH reads its flags positionally.
const args = rawArgs === "" ? [] : rawArgs.split(" ");

if (rawArgs === undefined || !logPath) {
  console.error("usage: launch.mjs <args> <log-path>");
  process.exit(2);
}

mkdirSync(dirname(logPath), { recursive: true });

// The log file is created before the package is resolved, so a launcher that
// cannot find DSH says so there — the plugin reads this same file to explain a
// failed start, and an absent file leaves it with nothing to report.
const fd = openSync(logPath, "w");

const bin = findEntryPoint();
if (!bin) {
  const message =
    "dsh-web-launcher: @deepseek-ai/dsh is not installed globally — " +
    "run `npm i -g @deepseek-ai/dsh`, then start DSH Web again";
  writeFileSync(logPath, message + "\n");
  closeSync(fd);
  console.error(message);
  process.exit(1);
}

// stdout and stderr are the log file's own descriptor. The child inherits it,
// so the log keeps being written after this process is gone — which matters
// because the URL is printed once the server is listening, long after the
// launcher returned. Piping instead cannot work: a detached child does not
// hand its pipes to a parent that has already exited.
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

function findEntryPoint() {
  for (const root of globalRoots()) {
    const candidate = join(root, "@deepseek-ai", "dsh", "lib", "bin.js");
    try {
      accessSync(candidate);
      return candidate;
    } catch {
      // Not this global root's copy of the package.
    }
  }
  return null;
}

// npm owns where a global install lands and the answer differs per machine and
// per version manager, so npm is asked rather than guessed. `npm_config_prefix`
// is not exported into ordinary processes either, so reading the environment
// would be as likely to be undefined as the cache path it replaced.
function globalRoots() {
  const roots = [];
  const add = (dir) => {
    // npm can fail outright — no npm on PATH at all — and a null root would
    // then reach `join` and take the launcher down instead of letting it
    // report that DSH is not installed.
    if (typeof dir === "string" && dir !== "" && !roots.includes(dir)) {
      roots.push(dir);
    }
  };

  // `npm root -g` is the global `node_modules` itself.
  add(npmOutput(["root", "-g"]));

  // `npm prefix -g` is one level above it on Windows, where a `-g` install puts
  // packages under `<prefix>\node_modules` while the prefix itself holds the
  // bin shims. Kept as a second root so a prefix that reports something other
  // than what `root` did still resolves.
  const prefix = npmOutput(["prefix", "-g"]);
  if (prefix !== null) {
    add(join(prefix, "node_modules"));
  }

  return roots;
}

function npmOutput(npmArgs) {
  // On Windows `npm` is an `npm.cmd` shim, so it needs the shell to be found;
  // a bare name fails with "program not found".
  const result = spawnSync("npm", npmArgs, {
    stdio: ["ignore", "pipe", "ignore"],
    shell: true,
    windowsHide: true,
    encoding: "utf8",
  });

  if (result.status !== 0) {
    return null;
  }
  return result.stdout?.trim() ?? null;
}
