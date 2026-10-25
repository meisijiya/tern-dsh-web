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

local function makeCx(name)
	return {
		name = name,
		toast = function(self, level, title, sub)
			table.insert(toasts, { level = level, title = title, sub = sub })
		end,
		pick = function()
			return nil
		end,
		open = function() end,
		prompt = function() end,
		read = function() end,
		-- The plugin looks through the panes for the URL the server printed.
		-- The harness has no panes.
		session = {
			panes = function()
				return {}
			end,
			read = function()
				return ""
			end,
		},
		-- The plugin asks the host for the process list when it wants to know
		-- who holds the port. The harness has no processes of its own.
		procs = {
			list = function()
				return {
					next = function(_, fn)
						fn({ { pid = 1, name = "node.exe", cmd = "node.exe" } }, nil, makeCx("procs"))
					end,
				}
			end,
			signal = function() end,
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
		refresh = function() end,
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

			-- The handle the awaitable form returns.
			local handle = {
				next = function(_, fn)
					local outcome = runOutcome
					if outcome.kind == "raise" then
						error("the program could not be started", 0)
					elseif outcome.kind == "no_result" then
						fn(nil, "spawn failed", makeCx("run"))
					elseif outcome.kind == "ok" then
						fn({ status = 0, stdout = "", stderr = "", timed_out = false }, nil, makeCx("run"))
					else
						fn({ status = 1, stdout = "", stderr = "", timed_out = false }, nil, makeCx("run"))
					end
				end,
			}

			if cb then
				-- The callback form: the plugin uses it for the holder lookup.
				cb({ status = 0, stdout = "", stderr = "", timed_out = false }, makeCx("run"))
			end
			return handle
		end,
	},
	fetch = function(url, opts, cb)
		table.insert(fetchCalls, { url = url, opts = opts })
		-- The port is free: nothing answers it, which is what the plugin
		-- reads as "not running".
		local nothing = { status = 0, body = "", error = "connection refused" }
		if cb then
			cb(nothing, makeCx("fetch"))
		end
		return {
			next = function(_, fn)
				fn(nothing, nil, makeCx("fetch"))
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

-- The plugin registers its commands and its status segment while it loads.
local commands = {}
local segment = nil

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

local function segmentText()
	local nodes = segment()
	return nodes[1].text
end

local function reset()
	toasts = {}
	logs = {}
	timers = {}
	processCalls = {}
	fetchCalls = {}
	runOutcome = { kind = "ok" }
	launcherLog = "dsh-web-launcher: @deepseek-ai/dsh is not installed globally"
	loadPlugin()
end

-- The launcher is behind the segment's menu: the "open" action starts the
-- server when it is not running yet.
local function startThroughMenu()
	local menu = nil
	for _, def in ipairs(commands) do
		if def.id == "menu" then
			menu = def
		end
	end
	assert(menu, "the menu command is registered")

	currentCx.pick = function(self, opts)
		return {
			next = function(_, fn)
				for _, item in ipairs(opts.items) do
					if item.act == "open" then
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

print("--- the launcher succeeds: the segment waits for the readiness poll ---")
reset()
startThroughMenu()
eq(#processCalls, 1, "the launcher ran once")
eq(processCalls[1].argv[1], "node", "through node")
contains(segmentText(), "starting", "the segment says it is starting")

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

print("")
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("harness failed", 0)
end
