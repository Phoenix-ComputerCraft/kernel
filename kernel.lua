-- Phoenix Kernel v0.0.8
--
-- Copyright (c) 2021-2025 JackMacWindows. All rights reserved.
-- This is a PRE-RELEASE BUILD! Redistribution of this file is not permitted.
-- See the Phoenix EULA (https://github.com/Phoenix-ComputerCraft/kernel/blob/master/LICENSE.md) for more information.

--- Version number of Phoenix.
PHOENIX_VERSION = "0.0.8"
--- Build string of Phoenix.
PHOENIX_BUILD = "PRERELEASE NONFREE $BUILD_DATE$"

--- Stores the start time of the kernel.
systemStartTime = os.epoch "utc"

--- Stores all kernel arguments passed on the command line.
args = {
    init = "/sbin/init.lua",
    root = "/root",
    rootfstype = "craftos",
    preemptive = true,
    quantum = 20000,
    splitkernpath = "/boot/kernel.lua.d",
    loglevel = 1,
    console = "tty1",
    traceback = true
}

--- Contains every syscall defined in the kernel.
syscalls = {}
--- Stores all currently running processes.
---@type Process[]
processes = {
    [0] = {
        name = "kernel",
        id = 0,
        user = "root",
        dir = "/",
        root = "/",
        env = _G,
        vars = {},
        dependents = {}
    }
}
--- Stores a quick reference to the kernel process object.
KERNEL = processes[0]
--- Stores all currently loaded kernel modules.
modules = {}
--- Stores a list of hooks to call on certain CraftOS events. Each entry has the
-- event name as a key, and a list of functions to call as the value. The
-- functions are called with a single table parameter with the event parameters.
eventHooks = {}
-- Stores a list of functions to call before clean shutdown.
shutdownHooks = {}
-- Stores functions that are used for debug hooks.
debugHooks = setmetatable({}, {__mode = "k"})

-- Unique keys for certain internal uses.
kSyscallYield = {}
kSyscallComplete = {}

--- Process API
process = {}
--- Filesystem API
filesystem = {}
--- Terminal API
terminal = {}
--- System logger API
syslog = {}
--- Hardware API
hardware = {}

if discord then discord("Phoenix", "Booting Phoenix " .. PHOENIX_VERSION) end

-- ==== LOADER ====

for _, v in ipairs(fs.list(fs.combine(args.root, args.splitkernpath))) do
    local file, err = fs.open(fs.combine(args.root, args.splitkernpath, v), "rb")
    if not file then (panic or error)("Could not read kernel part " .. v .. ": " .. err) end
    local fn, err = (loadstring or load)(file.readAll(), "=kernel:" .. v, "t", _ENV)
    file.close()
    if not fn then (panic or error)("Could not load kernel part " .. v .. ": " .. err) end
    fn(...)
end

-- == END LOADER ==

if init_retval ~= nil then
    syslog.log({level = 4}, "init exited with result", init_retval)
end
panic("init program exited")
