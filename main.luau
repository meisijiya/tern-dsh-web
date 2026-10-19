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

local ORIGIN = "http://127.0.0.1:3080"
local REGISTRY = "https://registry.npmjs.org/@deepseek-ai/dsh/latest"
local TOKEN_URL = "http://127%.0%.0%.1:3080/%?token=%S+"

-- `@latest` rather than the bare spec: npx keys its install cache by the exact
-- spec, so a bare `@deepseek-ai/dsh` stays pinned to whatever it first resolved
-- and no published update would ever be picked up. Naming the version range
-- makes a new release land in a fresh cache directory on the next launch.
--
-- `-y` is required: without it npx asks "Ok to proceed? (y)" on the first
-- install, and nothing in a non-interactive pane ever answers it.
local SPEC = "@deepseek-ai/dsh@latest"

-- The server's own arguments. npx is only used to resolve the package, never to
-- run it: a `.cmd` shim chains its commands with `&`, which swallows a stdout
-- redirect, and the launch URL has to survive to be read back.
local SERVER_ARGS = { "web", "--no-open" }

-- Where the detached server's stdout lands. Truncated on every launch so a
-- token from a previous run can never be mistaken for this one's.
local LOG_PATH = tern.plugin.data .. "/dsh-web.log"

-- launch.mjs resolves the package, then starts the server as a detached
-- `node` process with the log file as its own stdout descriptor. It comes back
-- as soon as the server is detached; the server itself outlives every pane, the
-- window and this plugin.
--
-- Its timeout has to cover a first run's download, since the resolution step is
-- synchronous and happens before the spawn.
local LAUNCHER = tern.plugin.dir .. "/launch.mjs"

local function launch_argv()
	return { "node", LAUNCHER, table.concat(SERVER_ARGS, " "), LOG_PATH, SPEC }
end

local PROBE_TIMEOUT_MS = 1_500
local POLL_MS = 700
local READY_MS = 600_000
-- How often to re-check a phase this window did not change itself.
local HEARTBEAT_MS = 15_000
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
			busy(fetchCx, "port 3080 answers HTTP " .. result.status .. " — that is not the DSH Web UI")
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
	if string.find(body, "EADDRINUSE", 1, true) ~= nil then
		return "port 3080 is already taken by another process"
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

	-- The awaitable form is used rather than the callback form because the
	-- callback's context is absent, and a detached start has nothing else to
	-- toast through: the window context that asked for it is long gone by the
	-- time the launcher returns.
	tern.process.run(launch_argv(), { timeout_ms = READY_MS })

	cx:toast("info", "Starting DSH Web", "the first run downloads the package, which takes minutes")

	wait_until_ready(tern.now() + READY_MS, function(readyCx)
		state.busy = false
		readyCx:toast("success", "DSH Web is up", ORIGIN)
		open_web_ui(readyCx)
	end, function(giveUpCx, why)
		state.busy = false
		giveUpCx:toast("error", "DSH Web did not start", why or diagnose_failure())
	end)
end

------------------------------------------------------------------- stopping

-- The server is started as `node <cache>/.../@deepseek-ai/dsh/lib/bin.js`, so
-- the entry point is what identifies it. Matching the package name alone is not
-- enough on its own: `npx -y @deepseek-ai/dsh@latest` is a `.cmd` shim that
-- spells the package with forward slashes while the entry point spells it with
-- Windows backslashes, and matching only one of the two kills the wrapper and
-- leaves the real server holding the port.
--
-- Either spelling is therefore accepted, and the node that owns the entry point
-- is the one that has to die.
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

-- The installed version is read out of npm's own npx cache rather than by
-- running the CLI: `npx <spec> --version` for a spec that is not cached yet
-- downloads the whole package, so a version check would cost the same 464 MB as
-- a first launch. Every cached `@deepseek-ai/dsh` is read instead, and their
-- set answers the only question that matters — is the published version already
-- on disk.
--
-- On Windows `npm` is an `npm.cmd` shim, so it is spawned through `cmd /c`; a
-- bare name fails with "program not found".
local cache_dir_resolved = false

local function npm_cache_dir(onDone)
	local cached = tern.kv.get("npm_cache")
	if cache_dir_resolved then
		onDone(cached)
		return
	end
	cache_dir_resolved = true

	local argv = tern.runtime.os == "windows"
		and { "cmd", "/c", "npm", "config", "get", "cache" }
		or { "npm", "config", "get", "cache" }

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
		tern.kv.set("npm_cache", dir)
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

-- Every `@deepseek-ai/dsh` npx has cached.
local function cached_versions(onDone)
	npm_cache_dir(function(dir)
		local versions = {}
		if dir == nil then
			onDone(versions)
			return
		end
		local base = dir .. "/_npx"
		local ok, entries = pcall(tern.fs.list, base)
		if not ok or type(entries) ~= "table" then
			onDone(versions)
			return
		end
		for _, entry in ipairs(entries) do
			local manifest = base .. "/" .. entry .. "/node_modules/@deepseek-ai/dsh/package.json"
			if tern.fs.exists(manifest) then
				local read = tern.fs.read(manifest, 65536)
				local decoded, payload = pcall(tern.json.decode, read or "")
				if decoded and type(payload) == "table" and type(payload.version) == "string" then
					versions[#versions + 1] = payload.version
				end
			end
		end
		onDone(versions)
	end)
end

local function settle_update(latest, cached)
	state.latest = latest
	state.cached = cached

	local best = nil
	for _, version in ipairs(cached) do
		best = newer(version, best) or best
	end
	state.installed = best

	local have = false
	for _, version in ipairs(cached) do
		if version == latest then
			have = true
			break
		end
	end

	if latest == nil then
		state.update = nil
	elseif have then
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
		cached_versions(function(cached)
			settle_update(latest, cached)
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

-- Updating is stop-then-start: `@latest` in the launch spec makes the next
-- start resolve the newer release instead of the pinned cache entry.
local function update(cx)
	stop(cx, launch)
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
			label = "Port 3080 is taken by another program",
			icon = "md-alert",
			act = "noop",
			detail = state.blocked,
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
		elseif act == "check_port" then
			probe(function(upCx)
				mark(RUNNING)
				open_web_ui(upCx)
			end, function(downCx)
				mark(STOPPED)
				downCx:toast("info", "Port 3080 is free", "DSH Web is not running")
			end, function(busyCx, why)
				mark(BLOCKED)
				state.blocked = why
				busyCx:toast("error", "Port 3080 still belongs to another program", why)
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
		mark(BLOCKED)
		state.blocked = why
		busyCx:toast("error", "Port 3080 belongs to another program", why)
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
	-- While a start or a stop is in flight the port is expected to be
	-- unreachable, and that is not evidence of anything: a first run can spend
	-- minutes downloading with nothing listening. Reading the phase back here
	-- would rewrite "starting" as "stopped" and then let a second start race
	-- the first.
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
	end, function()
		if state.phase ~= observed then
			return
		end
		mark(BLOCKED)
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

watch()
reschedule()

tern.process.run({"cmd","/c","echo probe-injected"}, { timeout_ms = 2000 })

cached_check()
