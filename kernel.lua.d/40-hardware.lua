do
    local message = "List of attached peripherals:\n"
    for _, v in ipairs{"top", "bottom", "left", "right", "front", "back"} do
        if peripheral.isPresent(v) then
            local typ = peripheral.getType(v)
            message = message .. v .. "\t" .. typ .. "\n"
            if typ == "modem" and not peripheral.call(v, "isWireless") then
                for _, w in ipairs(peripheral.call(v, "getNamesRemote")) do
                    message = message .. "\t" .. w .. "\t" .. peripheral.call(v, "getTypeRemote", w) .. "\n"
                end
            end
        end
    end
    syslog.log(message)
end

local function killall()
    syslog.log("Sending SIGTERM to all processes")
    local living = false
    for pid, process in pairs(processes) do if pid ~= 0 then
        syscalls.kill(KERNEL, nil, pid, 15)
        local gotev, ev = false, nil
        local dead = true
        for tid, thread in pairs(process.threads) do
            if not gotev and thread.status == "suspended" then
                ev = table.remove(process.eventQueue, 1) -- TODO: decide whether to optimize this
                gotev = true
            end
            if ev or thread.status ~= "suspended" then dead = executeThread(process, thread, ev or {n = 0}, dead, true)
            else dead = false end
        end
        if dead then
            process.isDead = true
            if process.parent ~= 0 and processes[process.parent] then
                processes[process.parent].eventQueue[#processes[process.parent].eventQueue+1] = {"process_complete", process.lastReturnValue}
            end
            reap_process(process)
            processes[pid] = nil
        else living = true end
    end end
    terminal.redraw(currentTTY)
    if living then
        syslog.log("Sending SIGKILL to all processes")
        for pid in pairs(processes) do if pid ~= 0 then syscalls.kill(KERNEL, nil, pid, 9) end end
    end
end

function syscalls.shutdown(process, thread)
    if process.user ~= "root" then return false end
    syslog.log("System is shutting down.")
    killall()
    os.shutdown()
    while true do coroutine.yield() end
end

function syscalls.reboot(process, thread)
    if process.user ~= "root" then return false end
    syslog.log("System is restarting.")
    killall()
    os.reboot()
    while true do coroutine.yield() end
end

function syscalls.computerid(process, thread)
    return os.computerID()
end

function syscalls.gethostname(process, thread)
    return os.computerLabel()
end

function syscalls.sethostname(process, thread, name)
    return os.setComputerLabel(name)
end

function syscalls.version(process, thread, buildnum)
    if buildnum then return PHOENIX_BUILD
    else return PHOENIX_VERSION end
end

function syscalls.cchost(process, thread)
    return _HOST
end

-- TODO: temporary?
function syscalls.serialize(process, thread, value)
    return serialize(value)
end