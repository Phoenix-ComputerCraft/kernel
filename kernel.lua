-- Phoenix Kernel v0.0.1
--
-- Copyright (c) 2021-2022 JackMacWindows. All rights reserved.
-- This is a PRE-RELEASE BUILD! Redistribution of this file is not permitted.
-- See the Phoenix EULA (https://github.com/Phoenix-ComputerCraft/kernel/blob/master/LICENSE.md) for more information.

--- Version number of Phoenix.
PHOENIX_VERSION = "0.0.1"
--- Build string of Phoenix.
PHOENIX_BUILD = "PRERELEASE NONFREE $BUILD_DATE$"

--- Stores the start time of the kernel.
systemStartTime = os.epoch "utc"

--- Stores all kernel arguments passed on the command line.
args = {
    init = "/bin/cash.lua",
    root = "/root",
    rootfstype = "craftos",
    preemptive = true,
    quantum = 2000000,
    splitkernpath = "/boot/kernel.lua.d",
    loglevel = 1,
    console = "tty1"
}

--- Contains every syscall defined in the kernel.
syscalls = {}
--- Stores all currently running processes.
processes = {
    [0] = {
        name = "kernel",
        id = 0,
        user = "root",
        dir = "/",
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

-- Unique keys for certain internal uses.
kSyscallYield = {}

--- Process API
process = {}
--- Filesystem API
filesystem = {}
--- Terminal API
terminal = {}
--- User API
user = {}
--- System logger API
syslog = {}
--- Hardware API
hardware = {}

-- ==== LOADER ====

for _, v in ipairs(fs.list(fs.combine(args.root, args.splitkernpath))) do
    local file, err = fs.open(fs.combine(args.root, args.splitkernpath, v), "rb")
    if not file then panic("Could not read kernel part " .. v .. ": " .. err) end
    local fn, err = (loadstring or load)(file.readAll(), --[["@" .. fs.combine(args.root, args.splitkernpath, v)]] "=kernel:" .. v)
    file.close()
    if not fn then panic("Could not load kernel part " .. v .. ": " .. err) end
    fn(...)
end

-- == END LOADER ==

if init_retval ~= nil then
    syslog.log({level = 4}, "init exited with result", init_retval)
end
panic("init program exited")
