-- Phoenix Kernel v0.1
--
-- Copyright (c) 2021 JackMacWindows. All rights reserved.
-- This is a PRE-RELEASE BUILD! Redistribution of this file is not permitted.
-- See the Phoenix EULA (https://github.com/Phoenix-ComputerCraft/kernel/blob/master/LICENSE.md) for more information.

args = {
    init = "/sbin/init.lua",
    root = "/root",
    rootfstype = "craftos",
    preemptive = true,
    quantum = 2000,
    splitkernpath = "/boot/kernel.lua.d",
    loglevel = 0,
    console = "tty1"
}

syscalls = {}
processes = {
    [0] = {
        name = "kernel",
        id = 0,
        user = "root",
        dir = "/",
        dependents = {}
    }
}
KERNEL = processes[0]

kSyscallYield = {}

process = {}
filesystem = {}
terminal = {}
user = {}
syslog = {}

eventHooks = {}

-- ==== LOADER ====

for _, v in ipairs(fs.list(fs.combine(args.root, args.splitkernpath))) do
    local file, err = fs.open(fs.combine(args.root, args.splitkernpath, v), "rb")
    if not file then panic("Could not read kernel part " .. v .. ": " .. err) end
    local fn, err = (loadstring or load)(file.readAll(), "@" .. fs.combine(args.root, args.splitkernpath, v))
    file.close()
    if not fn then panic("Could not load kernel part " .. v .. ": " .. err) end
    fn()
end

-- == END LOADER ==

if init_retval ~= nil then
    term.setTextColor(16384)
    term.write(tostring(init_retval))
    term.setCursorPos(1, select(2, term.getCursorPos()) + 1)
end
panic("init program exited")
