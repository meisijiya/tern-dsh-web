-- DSH Web — the status line carries a DSH button: click it for a menu that
-- opens, stops, restarts or updates the DeepSeek Harness Web UI.
--
-- The server is launched detached, on purpose. Run in a pane it would look
-- tidier, but that pane becomes a trap: closing it — the ordinary way to tidy
-- the window — takes the server down with it. Detached, the server outlives
-- every pane, the window and the plugin reload.
--
-- Detaching costs the token. `dsh web` prints its access URL, with a token, to
-- stdout and nowhere else, so the launch redirects stdout to a log file and the
-- token is read back out of that.

local PORT = 3080
local ORIGIN = "http://127.0.0.1:" .. PORT
local REGISTRY = "https://registry.npmjs.org/@deepseek-ai/dsh/latest"
local TOKEN_URL = "http://127%.0%.0%.1:" .. PORT .. "/%?token=%S+"

-- The server's own arguments. The package is started through `node <bin.js>`
-- rather than through the `dsh.cmd` shim: a shim chains its commands with `&`,
-- which swallows a stdout redirect, and the launch URL has to survive to be read
-- back.
local SERVER_ARGS = { "web", "--no-open" }

-- Where the detached server's stdout lands. Truncated on every launch so a
-- token from a previous run can never be mistaken for this one's.
local LOG_PATH = tern.plugin.data .. "/dsh-web.log"

-- The package the server runs, and the one a `dsh plugin add …` in a terminal
-- installs into: one global copy, so the plugin the user manages and the host
-- that loads it can never be two different versions.
local PACKAGE = "@deepseek-ai/dsh"

-- launch.mjs locates that global package, then starts it as a detached `node`
-- process with the log file as its own stdout descriptor. It comes back as soon
-- as the server is detached; the server itself outlives every pane, the window
-- and this plugin.
--
-- Its timeout has to cover a first start, since locating the package is a
-- synchronous `npm root -g` before the spawn.
local LAUNCHER = tern.plugin.dir .. "/launch.mjs"

local function launch_argv()
	return { "node", LAUNCHER, table.concat(SERVER_ARGS, " "), LOG_PATH }
end

local PROBE_TIMEOUT_MS = 1_500
local POLL_MS = 700
local READY_MS = 600_000
-- How often to re-check a phase this window did not change itself.
local HEARTBEAT_MS = 15_000
local HOLDER_TIMEOUT_MS = 8_000
local FREE_MAX_ROUNDS = 25
local STOP_POLL_MS = 400
local STOP_MAX_ROUNDS = 25
local FETCH_TIMEOUT_MS = 10_000
local PROCESS_TIMEOUT_MS = 30_000

local STOPPED, STARTING, RUNNING, BLOCKED = "stopped", "starting", "running", "blocked"

local state = {
	phase = STOPPED,
	-- Why the port is unusable, when phase is BLOCKED.
	blocked = nil,
	-- Set while a start or a stop is in flight, so the heartbeat leaves it alone.
	busy = false,
	-- The process holding the port, when it is not DSH.
	holder = nil,
	-- nil = not looked yet, "" = up to date, otherwise the newer version.
	update = nil,
	installed = nil,
	latest = nil,
}

-- Used before its natural home in the update section: pane diagnostics
local function trim(text)
	return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

local function mark(phase)
	state.phase = phase
	tern.chrome.refresh()
end

local function refresh()
	tern.chrome.refresh()
end

--------------------------------------------------------------------- probing

-- Any HTTP answer means something is listening on the port; the status code
-- itself does not matter (the Web UI answers 401 until the token is supplied),
-- a connection error is the only "not up" signal.
local function probe(up, down, busy)
	tern.fetch(ORIGIN, { method = "GET", timeout_ms = PROBE_TIMEOUT_MS }):next(function(result, _, fetchCx)
		if result == nil or result.status == 0 then
			down(fetchCx)
			return
		end
		-- Something answers on the port, but the Web UI answers 401 until the
		-- token is supplied and any other service answers something else entirely.
		-- Distinguishing the two stops a launch into a port another program owns.
		if result.status == 401 then
			up(fetchCx)
		else
			busy(fetchCx, "port " .. PORT .. " answers HTTP " .. result.status .. " — that is not the DSH Web UI")
		end
	end)
end

------------------------------------------------------------------- the server

-- `dsh web` prints `dsh web: http://127.0.0.1:3080/?token=…`. That token is
-- required — the bare origin answers 401 and the block shows a load failure —
-- so the address that actually works comes from the server's own output.
--
-- Every pane is scanned, not just the one this plugin opened: the server may
-- have been started by an earlier click, by another window, or by hand, and its
-- token line lives wherever it was launched. The reverse order puts the newest
-- pane first, which is the likeliest server.
local function token_url_in(read)
	if type(read) ~= "string" then
		return nil
	end
	return string.match(read, TOKEN_URL)
end

local function server_pane(cx)
	local panes = cx.session:panes()
	for i = #panes, 1, -1 do
		if token_url_in(cx.session:read(panes[i].pane, { as = "text" })) ~= nil then
			return panes[i].pane
		end
	end
	return nil
end

-- The detached server writes its token to LOG_PATH. A server someone started by
-- hand still prints into a pane instead, so the panes stay a valid place to look
-- even though this plugin no longer opens one of its own.
local function token_url(cx)
	if tern.fs.exists(LOG_PATH) then
		local found = token_url_in(tern.fs.read(LOG_PATH, 262144))
		if found ~= nil then
			return found
		end
	end
	local pane = server_pane(cx)
	if pane == nil then
		return nil
	end
	return token_url_in(cx.session:read(pane, { as = "text" }))
end

------------------------------------------------------------------- opening

local function open_web_ui(cx)
	-- Clicking again should reveal the Web UI, not stack up copies of it. An
	-- existing block is reused only when its page is actually alive: one left
	-- behind by a stopped server carries the same address but failed to load,
	-- and focusing that would show a dead page instead of a working one.
	--
	-- The stored address has the token stripped once the page has loaded, so the
	-- origin is what both kinds of block agree on.
	for _, pane in ipairs(cx.session:panes()) do
		if pane.kind == "browser" and pane.url ~= nil and string.sub(pane.url, 1, #ORIGIN) == ORIGIN then
			local read = cx.session:read(pane.pane)
			if type(read) == "table" and read.kind == "browser" and read.error == nil then
				cx.layout:focus(pane.pane)
				return
			end
		end
	end

	cx:open(token_url(cx) or ORIGIN)
end

-- A launch that fails says why in its log. Reading it turns "it did not come
-- up" into something the user can act on — most often a port another process
-- already holds.
local function log_text()
	if not tern.fs.exists(LOG_PATH) then
		return nil
	end
	return tern.fs.read(LOG_PATH, 262144)
end

local function diagnose_failure()
	local body = log_text()
	if body == nil then
		return "the launcher produced no output — see " .. LOG_PATH
	end
	-- The launcher writes its own failures with this prefix, so a launch that
	-- never reached the server says why instead of "gave up waiting".
	for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
		if string.find(line, "dsh-web-launcher:", 1, true) == 1 then
			return trim(string.sub(line, #"dsh-web-launcher: "))
		end
	end
	if string.find(body, "EADDRINUSE", 1, true) ~= nil then
		return "port " .. PORT .. " is already taken by another process"
	end
	for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
		if string.find(line, "startup failed", 1, true) ~= nil then
			return trim(line)
		end
	end
	return "see " .. LOG_PATH
end

local function wait_until_ready(deadline, onReady, onGiveUp)
	probe(function(fetchCx)
		mark(RUNNING)
		onReady(fetchCx)
	end, function(fetchCx)
		if tern.now() >= deadline then
			mark(STOPPED)
			onGiveUp(fetchCx, "gave up waiting — " .. diagnose_failure())
			return
		end
		tern.timer(POLL_MS, function(timerCx)
			local body = log_text()
			if body ~= nil and string.find(body, "startup failed", 1, true) ~= nil then
				mark(STOPPED)
				onGiveUp(timerCx, diagnose_failure())
				return
			end
			wait_until_ready(deadline, onReady, onGiveUp)
		end)
	end, function(busyCx, why)
		-- A third party owns the port, so waiting cannot help.
		mark(STOPPED)
		onGiveUp(busyCx, why)
	end)
end

------------------------------------------------------------------- launching

-- Starting the server takes no pane and therefore no focused pane to sit
-- beside: a detached launch has nothing to attach to, and refusing to start
-- without one would be an arbitrary restriction.
local function launch(cx)
	mark(STARTING)

	-- A stale log would let the token from the previous run be read as this one's.
	if tern.fs.exists(LOG_PATH) then
		tern.fs.remove(LOG_PATH)
	end

	state.busy = true

	-- The launcher runs through a callback rather than as an awaitable: the
	-- awaitable form runs the process in the foreground, so it would hold this
	-- window's VM for as long as the launcher takes — up to READY_MS — and no
	-- timer would fire while it waited, neither the heartbeat nor the
	-- readiness poll. The callback form runs it in the background and hands a
	-- fresh context back, and that context is what the toast below goes
	-- through: the context that asked for the start is long gone by then.
	--
	-- A spawn failure raises (node missing from PATH, for one). It is caught
	-- here because `busy` is the heartbeat's gate: an exception would leave it
	-- set, and the segment would stay on "starting" until a reload.
	local ok, err = pcall(function()
		tern.process.run(launch_argv(), { timeout_ms = READY_MS }, function(_, procCx)
			-- The callback's context is what the toast goes through, and the type
			-- makes it optional, so it is checked before it is used. The
			-- readiness poll below gets its own context and does not need it.
			if procCx ~= nil then
				procCx:toast("info", "Starting DSH Web", "waiting for it to answer on " .. ORIGIN)
			end

			wait_until_ready(tern.now() + READY_MS, function(readyCx)
				state.busy = false
				readyCx:toast("success", "DSH Web is up", ORIGIN)
				open_web_ui(readyCx)
			end, function(giveUpCx, why)
				state.busy = false
				giveUpCx:toast("error", "DSH Web did not start", why or diagnose_failure())
			end)
		end)
	end)
	if not ok then
		state.busy = false
		mark(STOPPED)
		cx:toast("error", "DSH Web did not start", tostring(err))
	end
end

------------------------------------------------------------------- stopping

-- The server is started as `node <global>/node_modules/@deepseek-ai/dsh/lib/bin.js`,
-- so the entry point is what identifies it. Both slash spellings are accepted
-- because the same path reaches Windows differently depending on which tool
-- spelled it — npm's shims and error messages use forward slashes, a resolved
-- `node_modules` path uses backslashes — and matching only one of the two leaves
-- the real server holding the port.
local function names_the_package(arg)
	if string.find(arg, "@deepseek-ai", 1, true) == nil then
		return false
	end
	return string.find(arg, "/dsh", 1, true) ~= nil
		or string.find(arg, "\\dsh", 1, true) ~= nil
end

local function dsh_pids(list)
	local pids = {}
	if list == nil or not list["local"] then
		return pids
	end
	for _, proc in ipairs(list.processes) do
		for _, arg in ipairs(proc.command or {}) do
			if names_the_package(arg) then
				pids[#pids + 1] = proc.pid
				break
			end
		end
	end
	return pids
end

------------------------------------------------- whoever else owns the port

-- A blocked port is one of two situations. Either a DSH survived Stop, which the
-- process match already covers. Or something that is not DSH holds the socket: a
-- leftover helper whose parent died, another tool, a second server. The port's
-- answer does not say which -- DSH answers 401 and a stranger answers 200, but
-- that is one data point, not an identity -- so the holder is looked up in the
-- OS and shown to the user by name.
--
-- Tern cannot answer this itself: ProcessInfo carries no ports and ProcessQuery
-- has no port filter, and its inventory is the plugin's process view, which need
-- not include something started outside Tern. holder.ps1 does the lookup.
local HOLDER_SCRIPT = tern.plugin.dir .. "/holder.ps1"

local function parse_holder(stdout)
	local holder = nil
	for line in string.gmatch(stdout or "", "[^\r\n]+") do
		local key, value = string.match(line, "^([A-Z]+)=(.*)$")
		if key ~= nil then
			if holder == nil then
				holder = {}
			end
			holder[key] = trim(value)
		end
	end
	return holder
end

-- "recovery.js -- .../dshmarket/lib/recovery.js" is more use than the whole
-- command line: a hundred characters of a temporary recovery path tells the user
-- nothing at a glance that its name does not.
local function holder_label(holder)
	local name = holder.NAME or "?"
	local cmd = holder.CMD or ""
	local base = name:match("[^\\/]+$") or name

	local script = cmd:match("([^\\/]+%.js)%s") or cmd:match("([^\\/]+%.exe)%s")
	if script ~= nil and script ~= base then
		return base .. "  --  " .. script
	end
	return base
end

-- `onFree` covers both "nothing is listening" and "the holder exited between the
-- two lookups inside the script": for the caller they are the same outcome, and
-- the common case is that race rather than a genuinely free port.
local function query_holder(cx, onFound, onFree)
	if tern.runtime.os ~= "windows" then
		onFree(cx)
		return
	end

	local argv = {
		"powershell",
		"-NoProfile",
		"-ExecutionPolicy",
		"Bypass",
		"-File",
		HOLDER_SCRIPT,
		tostring(PORT),
	}

	-- A spawn failure raises (no powershell, for one), and a holder lookup is
	-- not worth an exception: the callers read "nobody found" as "nothing is
	-- holding the port", which is the outcome they already read from a holder
	-- that exited between the two lookups. An exception would also leave `busy`
	-- set in the caller that asked for the lookup, and the heartbeat would
	-- never look at the port again.
	local ok = pcall(function()
		tern.process.run(argv, { timeout_ms = HOLDER_TIMEOUT_MS }):next(function(result, _, runCx)
			if result == nil or result.status ~= 0 then
				onFree(runCx)
				return
			end
			local holder = parse_holder(result.stdout)
			if holder == nil or tonumber(holder.PID) == nil then
				onFree(runCx)
				return
			end
			onFound(runCx, holder)
		end)
	end)
	if not ok then
		onFree(cx)
	end
end

-- Every route into the blocked state goes through here, so the holder is looked
-- up once and the menu can name it instead of leaving the user to find out
-- through the task manager.
local function enter_blocked(cx, why, toastTitle)
	mark(BLOCKED)
	state.blocked = why
	query_holder(cx, function(heldCx, holder)
		state.holder = holder
		refresh()
	end, function()
		state.holder = nil
	end)
	if toastTitle ~= nil then
		cx:toast("error", toastTitle, why)
	end
end

-- Killing whatever holds the port is destructive to something this plugin did
-- not start, so it is never done unasked: the name and the PID are shown first,
-- and declining leaves everything alone.
local function free_port_and_restart(cx)
	state.busy = true

	query_holder(cx, function(foundCx, holder)
		local pid = tonumber(holder.PID)
		if pid == nil then
			state.busy = false
			foundCx:toast("error", "Could not read the port holder", holder.PID)
			return
		end

		state.holder = holder

		foundCx:pick({
			placeholder = "Kill pid " .. pid .. "?",
			icon = "md-alert",
			items = {
				{
					label = "Kill it and start DSH Web",
					icon = "md-power",
					act = "yes",
					detail = holder_label(holder),
				},
				{ label = "Leave it alone", icon = "md-close", act = "no" },
			},
		}):next(function(choice, _, pickCx)
			if choice == nil or choice.act ~= "yes" then
				state.busy = false
				return
			end

			-- Escalate the way Stop does: ask politely, then insist. The loop ends
			-- by giving up rather than by starting anyway, because starting into a
			-- held port is the failure this exists to prevent.
			local attempts = 0
			local function signal_and_wait(sigCx)
				if attempts > FREE_MAX_ROUNDS then
					state.busy = false
					state.holder = nil
					mark(STOPPED)
					sigCx:toast(
						"error",
						"Port " .. PORT .. " is still held",
						"pid " .. pid .. " survived -- stopped instead of starting into it"
					)
					return
				end

				-- It can exit on its own between the lookup and the signal, which is
				-- the outcome that was wanted.
				pcall(function()
					sigCx.procs:signal(pid, attempts == 0 and "terminate" or "kill")
				end)
				attempts += 1

				tern.timer(STOP_POLL_MS, function(pollCx)
					query_holder(pollCx, function()
						-- Still there: go round again with a harder signal.
						signal_and_wait(pollCx)
					end, function(freeCx)
						state.busy = false
						state.holder = nil
						if tern.fs.exists(LOG_PATH) then
							tern.fs.remove(LOG_PATH)
						end
						mark(STOPPED)
						launch(freeCx)
					end)
				end)
			end

			signal_and_wait(pickCx)
		end)
	end, function(freeCx)
		-- Nothing there after all: the holder exited between the probe that said
		-- blocked and this lookup, which is the common case rather than an error.
		state.busy = false
		state.holder = nil
		mark(STOPPED)
		freeCx:toast("info", "Port " .. PORT .. " is free now", "starting DSH Web")
		launch(freeCx)
	end)
end

-- Stopping has to wait for the processes to actually be gone. `terminate` only
-- asks a process to begin shutting down, and a plugin host takes long enough
-- over it that a fixed delay is a race: starting the replacement early hands it
-- an EADDRINUSE while the old one still holds the socket. The signal escalates
-- to `kill` after the first round for a process that ignores the polite one.
--
-- `after` runs only once nothing is left. Restarting over a survivor would
-- produce exactly the failure this is here to prevent, so a stuck process is
-- reported instead.
local function stop(cx, after, round)
	-- Held for the whole escalation, including every retry round, and released
	-- on each exit below. The heartbeat must not read an unreachable port as a
	-- stopped server while the old one is still being asked to shut down.
	state.busy = true

	local attempts = round or 0

	cx.procs:list({ limit = 500 }):next(function(list, _, listCx)
		local doomed = dsh_pids(list)

		if #doomed > 0 and attempts < STOP_MAX_ROUNDS then
			for _, pid in ipairs(doomed) do
				-- A process can exit between the sample and the signal; one that does
				-- is already stopped, which is the outcome we wanted anyway.
				pcall(function()
					listCx.procs:signal(pid, attempts == 0 and "terminate" or "kill")
				end)
			end

			if attempts == 0 then
				listCx:toast("info", "Stopping DSH Web", "waiting for it to release the port")
			end

			tern.timer(STOP_POLL_MS, function(pollCx)
				stop(pollCx, after, attempts + 1)
			end)
			return
		end

		if #doomed > 0 then
			state.busy = false
			mark(STOPPED)
			listCx:toast(
				"error",
				"DSH Web would not stop",
				#doomed .. " process(es) survived — stopped here instead of restarting"
			)
			return
		end

		-- The log holds the token of a server that no longer exists; leaving it
		-- would let a later launch open a dead address.
		if tern.fs.exists(LOG_PATH) then
			tern.fs.remove(LOG_PATH)
		end

		state.busy = false
		mark(STOPPED)
		if attempts == 0 then
			listCx:toast("success", "DSH Web stopped")
		end

		if after ~= nil then
			after(listCx)
		end
	end)
end

------------------------------------------------------------------- updating

local function fetch_latest(onDone)
	tern.fetch(REGISTRY, { timeout_ms = FETCH_TIMEOUT_MS }):next(function(result, _, fetchCx)
		if result == nil then
			onDone(nil, "no result", fetchCx)
			return
		end
		if result.error ~= nil then
			onDone(nil, result.error, fetchCx)
			return
		end
		if result.status ~= 200 then
			onDone(nil, "HTTP " .. result.status, fetchCx)
			return
		end

		local ok, payload = pcall(tern.json.decode, result.body)
		if not ok or type(payload) ~= "table" or type(payload.version) ~= "string" then
			onDone(nil, "unreadable registry reply", fetchCx)
			return
		end
		onDone(payload.version, nil, fetchCx)
	end)
end

-- The installed version is read out of the global install's package.json rather
-- than by running the CLI: `npm i -g` for a version that is not installed yet
-- re-downloads and rewrites the very copy the running server was started from,
-- so a version check would be an update in disguise.
--
-- On Windows `npm` is an `npm.cmd` shim, so it is spawned through `cmd /c`; a
-- bare name fails with "program not found".
local global_root_resolved = false

local function npm_global_root(onDone)
	local cached = tern.kv.get("npm_global_root")
	if global_root_resolved then
		onDone(cached)
		return
	end
	global_root_resolved = true

	local argv = tern.runtime.os == "windows"
		and { "cmd", "/c", "npm", "root", "-g" }
		or { "npm", "root", "-g" }

	tern.process.run(argv, { timeout_ms = PROCESS_TIMEOUT_MS }, function(result, _, procCx)
		if result == nil or result.status ~= 0 then
			onDone(cached)
			return
		end
		local dir = trim(result.stdout)
		if dir == "" then
			onDone(cached)
			return
		end
		tern.kv.set("npm_global_root", dir)
		onDone(dir)
	end)
end

-- Newest of two semver-ish strings; `1.2.0-rc.3` sorts below `1.2.0-rc.10` the
-- way npm orders prereleases, so the numeric parts compare as numbers.
local function parse_version(text)
	if type(text) ~= "string" then
		return nil
	end
	local major, minor, patch, rest = string.match(text, "^(%d+)%.(%d+)%.(%d+)(.*)$")
	if major == nil then
		return nil
	end
	local tag, num = "", nil
	local pre = string.match(rest, "^%-(.+)$")
	if pre ~= nil and pre ~= "" then
		local letters, digits = string.match(pre, "^(%a+)(%d*)$")
		tag = letters or pre
		num = tonumber(digits)
	end
	return {
		major = tonumber(major),
		minor = tonumber(minor),
		patch = tonumber(patch),
		tag = tag,
		num = num,
	}
end

-- `b` is the incumbent and may be nil while the first candidate is being seeded.
local function newer(a, b)
	if b == nil then
		return a
	end
	local va, vb = parse_version(a), parse_version(b)
	if va == nil or vb == nil then
		return nil
	end
	for _, part in ipairs({ "major", "minor", "patch" }) do
		if va[part] ~= vb[part] then
			return va[part] > vb[part] and a or nil
		end
	end
	-- A release outranks its own prereleases.
	if va.tag ~= vb.tag then
		if va.tag == "" then
			return a
		end
		if vb.tag == "" then
			return nil
		end
		return va.tag > vb.tag and a or nil
	end
	if (va.num or 0) ~= (vb.num or 0) then
		return (va.num or 0) > (vb.num or 0) and a or nil
	end
	return nil
end

-- The version of the one copy the server runs, or nil when there is none yet.
local function installed_version(onDone)
	npm_global_root(function(root)
		if root == nil then
			onDone(nil)
			return
		end
		local manifest = root .. "/@deepseek-ai/dsh/package.json"
		if not tern.fs.exists(manifest) then
			onDone(nil)
			return
		end
		local read = tern.fs.read(manifest, 65536)
		local decoded, payload = pcall(tern.json.decode, read or "")
		if decoded and type(payload) == "table" and type(payload.version) == "string" then
			onDone(payload.version)
		else
			onDone(nil)
		end
	end)
end

local function settle_update(latest, installed)
	state.latest = latest
	state.installed = installed

	if latest == nil then
		state.update = nil
	elseif newer(latest, installed) == nil then
		-- Equal, or the installed copy is ahead of the published tag — a
		-- prerelease the registry already points at. Nothing to install.
		state.update = ""
	else
		state.update = latest
	end
	refresh()
end

local function check_update(announce, onVerdict)
	fetch_latest(function(latest, why, latestCx)
		if latest == nil then
			if onVerdict ~= nil then
				onVerdict(false)
			end
			if announce then
				latestCx:toast("error", "Could not reach the npm registry", (why or "unknown") .. " — " .. REGISTRY)
			end
			return
		end
		installed_version(function(installed)
			settle_update(latest, installed)
			if onVerdict ~= nil then
				onVerdict(true)
			end
			if not announce then
				return
			end
			if state.update == "" then
				latestCx:toast("success", "DSH is up to date", state.installed)
			else
				latestCx:toast("info", "DSH update available", (state.installed or "not installed") .. " → " .. state.update)
			end
		end)
	end)
end

local checked_this_window = false

-- Once per window load. `tern.now()` is a per-VM monotonic clock, so a timestamp
-- written by another window cannot be compared against it: the difference goes
-- negative and every later window would read it as "checked a moment ago".
local function cached_check()
	if checked_this_window then
		return
	end
	checked_this_window = true
	check_update(false, nil)
end

-- Updating is install-then-restart, and the order is the point: the global
-- copy is the one the running server was started from, so it has to be replaced
-- with the server stopped rather than underneath it.
local function update(cx)
	local target = state.update

	stop(cx, function(stopCx)
		state.busy = true

		local tail = { PACKAGE .. "@" .. target, "--no-audit", "--no-fund" }
		local argv = tern.runtime.os == "windows"
			and { "cmd", "/c", "npm", "i", "-g", tail[1], tail[2], tail[3] }
			or { "npm", "i", "-g", tail[1], tail[2], tail[3] }

		stopCx:toast("info", "Installing DSH " .. target, "a global install replaces the copy the server runs")

		-- A spawn failure raises (npm missing from PATH, for one). It is caught
		-- here because `busy` is the heartbeat's gate: an exception would leave
		-- it set, and the heartbeat would never look at the port again.
		local ok, err = pcall(function()
			tern.process.run(argv, { timeout_ms = READY_MS }, function(result, _, procCx)
				state.busy = false

				if result == nil or result.status ~= 0 then
					mark(STOPPED)
					local why = result == nil and "npm did not run" or trim(result.stderr or "")
					procCx:toast(
						"error",
						"Could not install DSH " .. target,
						(why ~= "" and why or "npm exited with " .. tostring(result.status))
							.. " — DSH Web is stopped"
					)
					return
				end

				state.installed = target
				state.update = ""
				refresh()
				launch(procCx)
			end)
		end)
		if not ok then
			state.busy = false
			mark(STOPPED)
			stopCx:toast("error", "Could not install DSH " .. target, tostring(err) .. " — DSH Web is stopped")
		end
	end)
end

---------------------------------------------------------------------- menu

local function menu(cx)
	local running = state.phase == RUNNING or state.phase == STARTING
	local blocked = state.phase == BLOCKED

	local items = {}

	if blocked then
		-- Launching into a port another program owns only produces a second
		-- failure, so the blocked state offers the way out instead of a start.
		table.insert(items, {
			label = "Port " .. PORT .. " is taken by another program",
			icon = "md-alert",
			act = "noop",
			detail = state.blocked,
		})
		table.insert(items, {
			label = "Free port " .. PORT .. " and restart",
			icon = "md-broom",
			act = "force_restart",
			detail = state.holder
				and (holder_label(state.holder) .. "  --  pid " .. (state.holder.PID or "?"))
				or "look up what is holding it",
		})
		table.insert(items, { label = "Check again", icon = "md-refresh", act = "check_port" })
	else
		table.insert(items, { label = "Open Web UI", icon = "md-web", act = "open", current = running })
		if running then
			table.insert(items, { label = "Restart", icon = "md-refresh", act = "restart" })
			table.insert(items, { label = "Stop", icon = "md-power", act = "stop" })
		end
	end

	-- Both versions are spelled out. "Up to date 0.2.0-rc.2" reads like a
	-- promise; the user has to see which version is installed and which one the
	-- registry offers before they can tell whether an update is worth taking.
	if state.update == nil then
		table.insert(items, { label = "Check for updates…", icon = "md-cloud-outline", act = "check" })
	elseif state.update == "" then
		table.insert(items, {
			label = "Up to date",
			icon = "md-check",
			act = "noop",
			detail = "installed " .. (state.installed or "unknown") .. " · latest " .. state.latest,
		})
	else
		table.insert(items, {
			label = "Update to " .. state.update,
			icon = "md-download",
			act = "update",
			detail = "installed " .. (state.installed or "none") .. " → latest " .. state.update,
		})
	end

	cx:pick({ items = items, placeholder = "DSH Web", icon = "md-web" }):next(function(choice, _, pickCx)
		if choice == nil then
			return
		end
		local act = choice.act
		if act == "open" then
			if state.phase == STOPPED then
				launch(pickCx)
			else
				open_web_ui(pickCx)
			end
		elseif act == "force_restart" then
			free_port_and_restart(pickCx)
		elseif act == "check_port" then
			probe(function(upCx)
				mark(RUNNING)
				open_web_ui(upCx)
			end, function(downCx)
				mark(STOPPED)
				downCx:toast("info", "Port " .. PORT .. " is free", "DSH Web is not running")
			end, function(busyCx, why)
				enter_blocked(busyCx, why, "Port " .. PORT .. " still belongs to another program")
			end)
		elseif act == "stop" then
			stop(pickCx)
		elseif act == "restart" then
			stop(pickCx, launch)
		elseif act == "update" then
			update(pickCx)
		elseif act == "check" then
			check_update(true)
		end
	end)
end

---------------------------------------------------------------- registration

-- Registered at entry load, not under tern.on("window_start"): a reload re-runs
-- the entry but does not fire window_start again, so registrations made there
-- would vanish until the window itself restarted.
tern.chrome.status(function()
	local label = state.phase == STOPPED and "DSH" or ("DSH " .. state.phase)
	if state.update ~= nil and state.update ~= "" then
		label = label .. " ↑"
	end

	local tone = "muted"
	if state.phase == RUNNING then
		tone = "success"
	elseif state.phase == STARTING or state.phase == BLOCKED then
		tone = "warning"
	end
	if state.update ~= nil and state.update ~= "" and state.phase ~= BLOCKED then
		tone = "info"
	end

	return { {
		text = label,
		icon = "md-web",
		tone = tone,
		command = "plugin.dsh-web.menu",
	} }
end)

tern.command({
	id = "menu",
	title = "DSH Web…",
	icon = "md-web",
	run = menu,
})

-- Set the segment's initial state rather than assuming "stopped": a DSH started
-- outside Tern is already listening by the time the entry loads.
local function sync_phase()
	probe(function(fetchCx)
		mark(RUNNING)
	end, function(fetchCx)
		mark(STOPPED)
	end, function(busyCx, why)
		enter_blocked(busyCx, why, "Port " .. PORT .. " belongs to another program")
	end)
end

sync_phase()

-- The server is detached, so it can stop for reasons this window never sees:
-- the user closing its console, a crash, a reboot. Probing once at load would
-- leave the segment claiming "running" long after the port is gone, and every
-- menu action would then fail against a server that is not there.
--
-- The phase under test is captured now, not read back from `state`, so the
-- poll cannot mistake a transition it did not observe for a dead server.
local function watch()
	-- While a start, a stop or an update is in flight the port is expected to be
	-- unreachable, and that is not evidence of anything: the busier of these can
	-- hold it closed for minutes. Reading the phase back here would rewrite
	-- "starting" as "stopped" and then let a second start race the first.
	if state.busy then
		return
	end

	local observed = state.phase
	probe(function()
		if state.phase ~= observed then
			-- The user started or stopped it in the meantime; their transition wins.
			return
		end
		mark(RUNNING)
	end, function()
		if state.phase ~= observed then
			return
		end
		mark(STOPPED)
	end, function(heartCx, why)
		if state.phase ~= observed then
			return
		end
		-- No toast: the heartbeat repeats, and a blocked port nobody is looking
		-- at is not worth interrupting for every few seconds.
		--
		-- The reason is the one the probe found: `state.blocked` is nil on the
		-- first block and the reason of an earlier block after that, and the
		-- menu shows this one as the detail of the blocked row.
		enter_blocked(heartCx, why, nil)
	end)
end

-- tern.timer fires once and there is no repeating form, so the next check is
-- scheduled by the check itself. (tern.set_interval does not exist; passing it
-- takes the whole entry down at load.)
local function reschedule()
	tern.timer(HEARTBEAT_MS, function()
		watch()
		reschedule()
	end)
end

-- One heartbeat chain per window. A reload re-runs the entry, and a second
-- chain would probe the port and refresh the chrome twice every 15 seconds.
-- Worse, each chain writes into the state table of the run that made it, so an
-- older chain would keep working on a table the current segment no longer
-- reads. The guard is the one the sibling plugin uses for its poll chain
-- (tern-minimax-quota/main.luau), so the pattern is not new here.
local heartbeat_started = false

local function start_heartbeat()
	if heartbeat_started then
		return
	end
	heartbeat_started = true
	watch()
	reschedule()
end

start_heartbeat()

cached_check()
