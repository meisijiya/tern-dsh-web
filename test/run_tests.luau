-- The launch path of the DSH Web plugin.
--
-- The plugin has no other test, and the launch path is the one place where a
-- missed failure leaves the status segment on "starting" for good: `busy` is
-- the heartbeat's gate, so a launch that failed without saying so stops the
-- heartbeat from ever looking at the port again.
--
-- This harness stubs the tern API, loads the plugin, and drives the ways a
-- launch can end:
--
--   1. the launcher succeeds (status 0): the segment waits for the readiness
--      poll and the busy flag is left set;
--   2. the launcher fails (status 1): the busy flag is cleared, the phase goes
--      to stopped, and the reason from the launcher's log is reported;
--   3. the process could not be started (no result at all): the same.
--
-- It also checks that a launch which already failed is not reported a second
-- time by the readiness poll.
--
-- The three behaviours that a user notices are covered as well:
--
--   4. the Web UI opens in a tab of its own, not beside the cursor;
--   5. a port that answers something other than the Web UI's 401 is only
--      "blocked" when a program other than DSH holds it — DSH's own server
--      answers 404 for a moment while it is coming up;
--   6. the update check does not ask npm for the global root while the
--      remembered one still holds the package: that spawn is what made the
--      plugin report an error at startup.
--
-- The plugin's source is spliced in by test/build.sh: the luau CLI has no
-- read, so the file is concatenated into this script.

local toasts = {}
local logs = {}
local timers = {}
local processCalls = {}
local fetchCalls = {}

-- What the next tern.process.run does. The plugin's launch reads it through
-- the awaitable, so the stub has to model that: a handle whose :next() calls
-- back with the result.
local runOutcome = { kind = "ok" }

-- What the launcher's log says. The launcher writes its own failures with a
-- prefix of its own, so the plugin can tell "the launcher failed" from "the
-- launcher said nothing".
local launcherLog = "dsh-web-launcher: @deepseek-ai/dsh is not installed globally"

-- The port's answer. 0 is a connection error, which is how a free port
-- answers; 401 is the Web UI without its token; anything else is a program
-- that is not the Web UI.
local portStatus = 0

-- The registry's answer. 0 means the registry could not be reached, which
-- keeps the update check out of the way unless a case asks for it.
local registryStatus = 0
local registryBody = ""

-- Who holds the port, as holder.ps1 reports it. The default is DSH itself,
-- which is what the port looks like while the server is still coming up.
local holderIsForeign = false
local DSH_HOLDER = table.concat({
	"PID=41244",
	"NAME=node.exe",
	"CMD=C:\\nvm4w\\nodejs\\node.exe D:\\dev\\npm\\node_global\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js web --no-open",
	"PARENT=gone",
}, "\n")
local FOREIGN_HOLDER = table.concat({
	"PID=321",
	"NAME=other.exe",
	"CMD=C:\\tools\\other.exe",
	"PARENT=gone",
}, "\n")

-- What `npm root -g` prints.
local npmRoot = "D:\\dev\\npm\\node_global\\node_modules\n"

-- The plugin's own key-value store, where it remembers the global root.
local kvStore = {}

-- Whether the harness's DSH process is still there. A stop that has to keep
-- going leaves it alive; a stop that has to finish kills it.
local dshAlive = true
-- Whether a signal actually kills it. A stop that has to keep going needs a
-- process that survives the first signal.
local dshDiesOnSignal = false

-- The window's panes. The host creates a block before an open returns, so
-- the stub does the same: the plugin finds the new pane by the difference.
local panes = {}
local nextPaneId = 100

-- The window's tabs, so a block can be found alone in one or sharing one.
local tabInfos = {}

-- What the plugin asked the host to do with its layout.
local openedUrls = {}
local movedPanes = {}
local namedTabs = {}
local focusedPanes = {}

-- The segment text at every refresh, so a state that only exists between two
-- refreshes can still be seen.
local refreshStates = {}

-- The plugin registers its commands and its status segment while it loads.
local commands = {}
local segment = nil

local function segmentText()
	if segment == nil then
		return ""
	end
	return segment()[1].text
end

local function makeCx(name)
	return {
		name = name,
		toast = function(self, level, title, sub)
			table.insert(toasts, { level = level, title = title, sub = sub })
		end,
		pick = function()
			return nil
		end,
		-- A URL open creates a browser block, and the host creates it before
		-- the open returns.
		open = function(self, url)
			table.insert(openedUrls, url)
			nextPaneId += 1
			table.insert(panes, { pane = nextPaneId, kind = "browser", url = url })
			return nextPaneId
		end,
		prompt = function() end,
		read = function() end,
		-- The plugin looks through the panes for the URL the server printed.
		-- The harness has no panes of its own.
		session = {
			panes = function()
				return panes
			end,
			tabs = function()
				return tabInfos
			end,
			-- A browser block that has loaded reads back as a browser block.
			-- The server's own pane has no text to read in the harness.
			read = function(_, pane)
				for _, info in ipairs(panes) do
					if info.pane == pane and info.kind == "browser" then
						return { kind = "browser" }
					end
				end
				return ""
			end,
		},
		-- The block moves into a tab of its own once it is open.
		layout = {
			focus = function(self, pane)
				table.insert(focusedPanes, pane)
			end,
			move_to_new_tab = function(self, pane)
				table.insert(movedPanes, pane)
				local tab = 900 + #movedPanes
				for _, info in ipairs(panes) do
					if info.pane == pane then
						info.tab = tab
					end
				end
				table.insert(tabInfos, { id = tab, panes = 1 })
				return tab
			end,
			name_tab = function(self, tab, name)
				table.insert(namedTabs, { tab = tab, name = name })
				for _, info in ipairs(tabInfos) do
					if info.id == tab then
						info.name = name
					end
				end
			end,
		},
		-- The plugin asks the host for the process list when it wants to know
		-- who holds the port. The harness has a DSH of its own, so a stop has
		-- something to stop. The process stays alive until a case says
		-- otherwise, so a stop that is meant to keep going does.
		procs = {
			list = function()
				local processes = {}
				if dshAlive then
					table.insert(processes, {
						pid = 1,
						name = "node.exe",
						command = {
							"node",
							"D:\\dev\\npm\\node_global\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js",
							"web",
						},
					})
				end
				return {
					next = function(_, fn)
						fn({
							["local"] = true,
							sample = 1,
							total = 1,
							more = false,
							processes = processes,
						}, nil, makeCx("procs"))
					end,
				}
			end,
			signal = function()
				-- A signalled DSH is gone unless the case wants the stop to
				-- keep going: a process that ignores the signal leaves the
				-- escalation running, which is what the stopping state is.
				if dshDiesOnSignal then
					dshAlive = false
				end
			end,
		},
	}
end

local currentCx = makeCx("current")

tern = {
	now = function()
		return 1000
	end,
	chrome = {
		status = function() end,
		refresh = function()
			table.insert(refreshStates, segmentText())
		end,
	},
	command = function() end,
	block = { define = function() end },
	ui = {
		col = function() end,
		section = function() end,
		text = function() end,
		table = function() end,
		span = function() end,
	},
	fs = {
		exists = function()
			return true
		end,
		read = function()
			return launcherLog
		end,
		remove = function() end,
		write = function() end,
	},
	json = {
		decode = function()
			return { version = "1.2.3" }
		end,
	},
	kv = {
		get = function(key)
			return kvStore[key]
		end,
		set = function(key, value)
			kvStore[key] = value
		end,
	},
	env = function()
		return nil
	end,
	secrets = {
		get = function()
			return {
				next = function(_, fn)
					fn(nil, "no secret", makeCx("secrets"))
				end,
			}
		end,
		set = function()
			return {
				next = function(_, fn)
					fn(nil, nil, makeCx("secrets"))
				end,
			}
		end,
	},
	process = {
		run = function(argv, opts, cb)
			table.insert(processCalls, { argv = argv, opts = opts })

			-- Each program answers differently: the launcher fails or not as
			-- the case says, the holder lookup reports who holds the port, and
			-- npm reports where the global root is.
			local result = { status = 0, stdout = "", stderr = "", timed_out = false }
			if argv[1] == "powershell" then
				result.stdout = holderIsForeign and FOREIGN_HOLDER or DSH_HOLDER
			elseif argv[1] == "cmd" and argv[3] == "npm" then
				result.stdout = npmRoot
			elseif runOutcome.kind == "fail" then
				result.status = 1
			elseif runOutcome.kind == "no_result" then
				result = nil
			end

			-- The handle the awaitable form returns.
			local handle = {
				next = function(_, fn)
					if runOutcome.kind == "raise" then
						error("the program could not be started", 0)
					elseif runOutcome.kind == "no_result" then
						fn(nil, "spawn failed", makeCx("run"))
					else
						fn(result, nil, makeCx("run"))
					end
				end,
			}

			if cb then
				-- The callback form: the plugin uses it for the npm root.
				cb(result, makeCx("run"))
			end
			return handle
		end,
	},
	fetch = function(url, opts, cb)
		table.insert(fetchCalls, { url = url, opts = opts })
		-- The port and the registry answer differently.
		local reply
		if string.find(url, "registry.npmjs.org", 1, true) ~= nil then
			reply = { status = registryStatus, body = registryBody, error = nil }
		else
			reply = { status = portStatus, body = "", error = nil }
		end
		if cb then
			cb(reply, makeCx("fetch"))
		end
		return {
			next = function(_, fn)
				fn(reply, nil, makeCx("fetch"))
			end,
		}
	end,
	timer = function(ms, fn)
		table.insert(timers, { ms = ms, fn = fn })
		return {
			cancel = function() end,
		}
	end,
	log = {
		debug = function() end,
		info = function() end,
		warn = function(message)
			table.insert(logs, tostring(message))
		end,
		error = function(message)
			table.insert(logs, tostring(message))
		end,
	},
	plugin = {
		dir = "C:/plugin",
		data = "C:/data",
	},
	runtime = {
		os = "windows",
	},
}

-- The plugin reads the operating system through the global os.
local RealOs = os
os = {
	time = function()
		return RealOs and RealOs.time and RealOs.time() or 0
	end,
	execute = function()
		return true, ""
	end,
}

-- The plugin's own source, spliced in below the stub.
local function plugin_source()
	return [[SOURCE]]
end

-- ==== STUB-END ====

local passed, failed = 0, 0

local function eq(actual, expected, what)
	if actual == expected then
		passed += 1
		print("ok   " .. what)
	else
		failed += 1
		print("FAIL " .. what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
	end
end

local function contains(haystack, needle, what)
	if string.find(haystack, needle, 1, true) ~= nil then
		passed += 1
		print("ok   " .. what)
	else
		failed += 1
		print("FAIL " .. what .. ": " .. tostring(needle) .. " not in " .. tostring(haystack))
	end
end

local function notContains(haystack, needle, what)
	if string.find(haystack, needle, 1, true) == nil then
		passed += 1
		print("ok   " .. what)
	else
		failed += 1
		print("FAIL " .. what .. ": " .. tostring(needle) .. " in " .. tostring(haystack))
	end
end

-- The plugin's state is module-local, so each case loads the plugin afresh:
-- a case that started from the phase the previous one left behind would drive
-- the menu's other branch.
local function loadPlugin()
	commands = {}
	segment = nil
	tern.command = function(def)
		table.insert(commands, def)
	end
	tern.chrome.status = function(fn)
		segment = fn
	end
	local chunk = loadstring(plugin_source())
	assert(chunk, "the plugin source does not parse")
	chunk()
end

local function reset()
	toasts = {}
	logs = {}
	timers = {}
	processCalls = {}
	fetchCalls = {}
	refreshStates = {}
	openedUrls = {}
	movedPanes = {}
	namedTabs = {}
	focusedPanes = {}
	panes = {}
	nextPaneId = 100
	tabInfos = {}
	kvStore = {}
	dshAlive = true
	dshDiesOnSignal = false
	runOutcome = { kind = "ok" }
	portStatus = 0
	registryStatus = 0
	registryBody = ""
	holderIsForeign = false
	launcherLog = "dsh-web-launcher: @deepseek-ai/dsh is not installed globally"
	loadPlugin()
end

-- The items the menu offered last time it was opened, so a case can ask
-- what the user was given rather than only what they picked.
local menuItems = {}

-- The launcher is behind the segment's menu: the "open" action starts the
-- server when it is not running yet.
local function runMenu(act)
	local menu = nil
	for _, def in ipairs(commands) do
		if def.id == "menu" then
			menu = def
		end
	end
	assert(menu, "the menu command is registered")

	currentCx.pick = function(self, opts)
		menuItems = {}
		for _, item in ipairs(opts.items) do
			table.insert(menuItems, item)
		end
		return {
			next = function(_, fn)
				for _, item in ipairs(opts.items) do
					if item.act == act then
						fn(item, nil, makeCx("pick"))
						return
					end
				end
				fn(nil, nil, makeCx("pick"))
			end,
		}
	end
	menu.run(currentCx)
end

local function startThroughMenu()
	runMenu("open")
end

-- The failure report is made from a timer: the await hook it would
-- otherwise run on has a 50 ms budget, and reading the launcher's log there
-- blows it.
local function runTimers()
	-- The last timer registered is the one the failure report runs on; the
	-- earlier ones are the readiness poll and the heartbeat.
	local timer = timers[#timers]
	if timer == nil then
		return
	end
	pcall(timer.fn, makeCx("timer"))
end

-- Every timer that is armed, in the order it was armed. The holder lookup
-- and the npm root both work through timers, so a case that wants their
-- answers has to let them run.
--
-- The waves are bounded: the heartbeat re-arms itself, so draining without a
-- bound would never end.
local function runAllTimers()
	for _ = 1, 8 do
		if #timers == 0 then
			return
		end
		local armed = timers
		timers = {}
		for _, timer in ipairs(armed) do
			pcall(timer.fn, makeCx("timer"))
		end
	end
end

-- Runs the last timer armed with this delay and takes it out of the queue.
-- A case that has to run one particular timer in a particular order needs to
-- say which one, and the delay is what tells them apart.
local function fireLastTimer(ms)
	local index = nil
	for i, timer in ipairs(timers) do
		if timer.ms == ms then
			index = i
		end
	end
	if index == nil then
		return false
	end
	local timer = table.remove(timers, index)
	pcall(timer.fn, makeCx("timer"))
	return true
end

-- The delays the plugin's own timers use: a zero-delay one does the work,
-- and the longer one waits.
local WORK_MS = 0
local STOP_POLL_MS = 400
local HEARTBEAT_MS = 15_000

print("--- the launcher succeeds: the segment waits for the readiness poll ---")
reset()
startThroughMenu()
eq(#processCalls, 1, "the launcher ran once")
eq(processCalls[1].argv[1], "node", "through node")
contains(segmentText(), "starting", "the segment says it is starting")

print("--- the launcher fails: the segment says why ---")
reset()
runOutcome = { kind = "fail" }
startThroughMenu()
eq(#processCalls, 1, "the launcher ran once")
runTimers()
local sawError = false
for _, toast in ipairs(toasts) do
	if toast.level == "error" and string.find(toast.sub or "", "not installed globally", 1, true) ~= nil then
		sawError = true
	end
end
eq(sawError, true, "the failure is reported with the launcher's own reason")
eq(segmentText(), "DSH", "the segment says it is stopped")

print("--- the launcher fails: the report does not wait for the poll ---")
-- The launcher writes its own failure into its log with a prefix of its
-- own, and exits non-zero. That reason is reported as soon as the
-- launcher is done: the readiness poll would otherwise keep going for
-- another ten minutes and report the same thing a second time.
reset()
launcherLog = "dsh-web-launcher: @deepseek-ai/dsh is not installed globally"
runOutcome = { kind = "fail" }
startThroughMenu()
eq(#processCalls, 1, "the launcher ran once")
runTimers()
local sawLauncherReason = false
for _, toast in ipairs(toasts) do
	if toast.level == "error" and string.find(toast.sub or "", "not installed globally", 1, true) ~= nil then
		sawLauncherReason = true
	end
end
eq(sawLauncherReason, true, "the launcher's own reason is reported")
-- The reason is the launcher's, not the generic fallback.
local sawGeneric = false
for _, toast in ipairs(toasts) do
	if toast.level == "error" and string.find(toast.sub or "", "gave up waiting", 1, true) ~= nil then
		sawGeneric = true
	end
end
eq(sawGeneric, false, "and it did not wait for the poll to time out")

print("--- the process cannot be started at all: the same ---")
reset()
runOutcome = { kind = "no_result" }
startThroughMenu()
eq(#processCalls, 1, "the launcher ran once")
runTimers()
local sawSpawnError = false
for _, toast in ipairs(toasts) do
	if toast.level == "error" then
		sawSpawnError = true
	end
end
eq(sawSpawnError, true, "the failure is reported")
eq(segmentText(), "DSH", "the segment says it is stopped")

print("--- a launch that failed does not also time out ten minutes later ---")
reset()
runOutcome = { kind = "fail" }
startThroughMenu()
local toastsAfterFailure = #toasts
-- The readiness poll is the timer chain the plugin armed. Firing it now must
-- not produce a second failure report.
--
-- One round only: the poll re-arms itself, and firing it again would
-- recurse forever.
local fired = 0
for _, timer in ipairs(timers) do
	if fired >= 1 then
		break
	end
	fired += 1
	local ok = pcall(timer.fn, makeCx("poll"))
	if not ok then
		failed += 1
		print("FAIL the poll raised")
	end
end
eq(#toasts, toastsAfterFailure, "the failed launch was not reported a second time")

print("--- the Web UI opens in a tab of its own ---")
reset()
-- The server answers with the Web UI's 401, so the plugin knows it is up
-- and the menu offers the Web UI rather than a start.
portStatus = 401
loadPlugin()
eq(segmentText(), "DSH running", "the segment says it is running")
runMenu("open")
eq(#openedUrls, 1, "the Web UI was opened once")
eq(openedUrls[1], "http://127.0.0.1:3080", "it is the server's own address")
eq(#movedPanes, 1, "the block was moved into a tab of its own")
eq(#namedTabs, 1, "the tab was named")
eq(namedTabs[1] and namedTabs[1].name or "", "DSH Web", "after the thing it shows")

print("--- clicking again reuses the open Web UI ---")
reset()
portStatus = 401
loadPlugin()
runMenu("open")
eq(#openedUrls, 1, "the Web UI was opened once")
runMenu("open")
eq(#openedUrls, 1, "it was not opened a second time")
eq(#movedPanes, 1, "and no second block was moved into a tab")
eq(#focusedPanes, 1, "the open block was brought forward")
eq(focusedPanes[1], 101, "and it was the one already open")
local sawAlreadyOpen = false
for _, toast in ipairs(toasts) do
	if string.find(toast.title or "", "already open", 1, true) ~= nil then
		sawAlreadyOpen = true
	end
end
eq(sawAlreadyOpen, true, "the click was answered")

print("--- a block that is no longer on screen is given a tab again ---")
reset()
portStatus = 401
loadPlugin()
runMenu("open")
-- A closed tab parks the block in the deck: it is alive, but the user
-- cannot see it, and focusing it alone would show nothing.
panes[1].parked = true
panes[1].tab = nil
tabInfos = {}
runMenu("open")
eq(#openedUrls, 1, "no second block was opened")
eq(#movedPanes, 2, "the parked block was given a tab of its own")
eq(movedPanes[2], 101, "and it was the block that was already open")
eq(namedTabs[2] and namedTabs[2].name or "", "DSH Web", "and the tab was named after it")

print("--- a block sharing a tab is given one of its own ---")
reset()
portStatus = 401
loadPlugin()
runMenu("open")
-- A block the user opened by hand sits beside other blocks; the plugin's
-- Web UI belongs in a tab of its own.
panes[1].tab = 500
table.insert(tabInfos, { id = 500, panes = 2 })
runMenu("open")
eq(#openedUrls, 1, "no second block was opened")
eq(#movedPanes, 2, "the block was moved out of the shared tab")
eq(namedTabs[2] and namedTabs[2].name or "", "DSH Web", "and the new tab was named")

print("--- a port DSH itself holds is starting, not blocked ---")
reset()
-- DSH answers 404 for a moment after it binds the port and before its Web
-- UI is mounted. That is not another program owning the port.
portStatus = 404
loadPlugin()
runAllTimers()
contains(segmentText(), "starting", "the segment says it is starting")
notContains(segmentText(), "blocked", "and not that the port is taken")
for _, toast in ipairs(toasts) do
	if toast.level == "error" then
		failed += 1
		print("FAIL a toast about the port being taken was shown")
	end
end

print("--- a port another program holds is blocked ---")
reset()
portStatus = 404
holderIsForeign = true
loadPlugin()
runAllTimers()
contains(segmentText(), "blocked", "the segment says the port is taken")
local sawBlockedToast = false
for _, toast in ipairs(toasts) do
	if toast.level == "error" and string.find(toast.title or "", "another program", 1, true) ~= nil then
		sawBlockedToast = true
	end
end
eq(sawBlockedToast, true, "and it says so")

print("--- the update check does not ask npm while the root still holds the package ---")
reset()
-- The registry answers, so the update check runs, and the root is the one
-- the plugin remembered: asking npm again would spawn a process while the
-- window is still loading, which is what made the plugin report an error at
-- startup.
registryStatus = 200
registryBody = '{"version":"9.9.9"}'
kvStore["npm_global_root"] = "D:\\dev\\npm\\node_global\\node_modules"
loadPlugin()
runAllTimers()
local askedNpm = false
for _, call in ipairs(processCalls) do
	if call.argv[1] == "cmd" and call.argv[3] == "npm" then
		askedNpm = true
	end
end
eq(askedNpm, false, "npm was not asked for the root")

print("--- the update check asks npm when the root no longer holds the package ---")
reset()
registryStatus = 200
registryBody = '{"version":"9.9.9"}'
loadPlugin()
runAllTimers()
askedNpm = false
for _, call in ipairs(processCalls) do
	if call.argv[1] == "cmd" and call.argv[3] == "npm" then
		askedNpm = true
	end
end
eq(askedNpm, true, "npm was asked for the root")

print("--- a launch that meets DSH's own 404 keeps waiting ---")
reset()
-- DSH answers 404 for about a second after it binds the port. A launch that
-- reads that as "another program owns the port" fails the start it just
-- performed.
portStatus = 404
startThroughMenu()
runAllTimers()
contains(segmentText(), "starting", "the segment says it is starting")
notContains(segmentText(), "blocked", "and not that the port is taken")
local sawLaunchError = false
for _, toast in ipairs(toasts) do
	if toast.level == "error" then
		sawLaunchError = true
	end
end
eq(sawLaunchError, false, "the start did not fail over a 404")

print("--- stopping says so while it happens ---")
reset()
portStatus = 401
loadPlugin()
runMenu("stop")
-- The stop is visible between the moment it starts and the moment the
-- processes are gone.
runAllTimers()
local sawStopping = false
for _, text in ipairs(refreshStates) do
	if string.find(text, "stopping", 1, true) ~= nil then
		sawStopping = true
	end
end
eq(sawStopping, true, "the segment said it was stopping")

print("--- a stop that was replaced does not mute the heartbeat ---")
reset()
portStatus = 401
-- The DSH goes away when it is signalled, so the second stop has nothing
-- left to do and finishes.
dshDiesOnSignal = true
loadPlugin()
-- The first stop starts and reaches its poll.
runMenu("stop")
fireLastTimer(WORK_MS)
-- A second stop replaces it and runs to the end.
runMenu("stop")
fireLastTimer(WORK_MS)
eq(segmentText(), "DSH", "the server is stopped")
-- The replaced stop's own poll fires afterwards. It must not take the
-- heartbeat's silence with it: a stale round that owns the busy flag
-- leaves the segment believing the server is still up, forever.
fireLastTimer(STOP_POLL_MS)
fireLastTimer(WORK_MS)
fireLastTimer(HEARTBEAT_MS)
eq(segmentText(), "DSH running", "the heartbeat still watches the port")

print("--- the menu still offers Restart and Stop while stopping ---")
reset()
portStatus = 401
loadPlugin()
runMenu("stop")
runAllTimers()
-- The menu is opened again while the stop is still running.
runMenu("noop")
local offered = {}
for _, item in ipairs(menuItems) do
	offered[item.label] = true
end
eq(offered["Restart"] == true, true, "Restart is offered")
eq(offered["Stop"] == true, true, "Stop is offered")
local webCurrent = nil
for _, item in ipairs(menuItems) do
	if item.label == "Open Web UI" then
		webCurrent = item.current
	end
end
eq(webCurrent, false, "the Web UI is offered, but not as the current state")

print("")
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("harness failed", 0)
end
