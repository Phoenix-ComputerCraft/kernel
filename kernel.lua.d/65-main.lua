-- temp mount
mounts[""] = filesystems[args.rootfs]:new(KERNEL, args.root, {})
G.term = term
syslogs.default.file = filesystem.open(KERNEL, "/var/log/default.log", "a")
syslog.log("Starting init")

local empty_packed_table = {n = 0}
local init_ok, init_pid
if args.init then
    init_ok, init_pid = pcall(syscalls.exec, KERNEL, nil, args.init)
end
if not init_ok then
    syslog.log({level = 4, process = 0}, "Could not load init:", init_pid)
    syslog.log("Could not find provided init, trying default locations")
    for _,v in ipairs{"/sbin/init", "/etc/init", "/bin/init", "/bin/sh"} do
        syslog.log("Trying", v)
        init_ok, init_pid = pcall(syscalls.exec, KERNEL, nil, v)
        if not init_ok then syslog.log({level = 4, process = 0}, "Could not load init:", init_pid) end
        if init_ok then break end
    end
    if not init_ok then panic("No working init found") end
end
local event_queue = {front = 0, back = 0, [0] = empty_packed_table}
local allWaiting = false

while processes[init_pid] do
    if not allWaiting then os.queueEvent("__event_queue_back") end
    while true do
        local ev = table.pack(coroutine.yield())
        if allWaiting or ev[1] == "__event_queue_back" then break end
        event_queue[event_queue.back+1] = ev
        event_queue.back = event_queue.back + 1
    end
    local ev = event_queue[event_queue.front]
    if ev then
        --syslog.debug(event_queue.front, event_queue.back, table.unpack(ev, 1, ev.n))
        event_queue.front = event_queue.front + 1
    else ev = empty_packed_table end
    if ev[1] == "key" and ev[2] == 68 then -- F10 (TODO: get real keys API)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("Entering debug console.")
        local y = 2
        local running = true
        term.setCursorPos(1, y)
        while running do
            local line = ""
            local w, h = term.getSize()
            term.write("lua> ")
            term.setCursorBlink(true)
            while true do
                local ev = {coroutine.yield()}
                if ev[1] == "char" or ev[1] == "paste" then
                    line = line .. ev[2]
                    term.write(ev[2])
                elseif ev[1] == "key" then
                    if ev[2] == 14 and #line > 0 then -- backspace
                        line = line:sub(1, -2)
                        term.setCursorPos(term.getCursorPos() - 1, y)
                        term.write(" ")
                        term.setCursorPos(term.getCursorPos() - 1, y)
                    elseif ev[2] == 28 then -- enter
                        break
                    end
                end
            end
            y = y + 1
            if y > h then
                y = y - 1
                term.scroll(1)
            end
            term.setCursorPos(1, y)
            local fn, err = load("return " .. line, "=lua", "t", setmetatable({exit = function() running = false end}, {__index = _G}))
            if not fn then fn, err = load(line, "=lua", "t", setmetatable({exit = function() running = false end}, {__index = _G})) end
            if fn then
                local res = table.pack(pcall(fn))
                if res[1] then
                    for i = 2, res.n do
                        term.write(tostring(res[i]))
                        y = y + 1
                        if y > h then
                            y = y - 1
                            term.scroll(1)
                        end
                        term.setCursorPos(1, y)
                    end
                else
                    term.setTextColor(16384)
                    term.write(res[2])
                    term.setTextColor(1)
                    y = y + 1
                    if y > h then
                        y = y - 1
                        term.scroll(1)
                    end
                    term.setCursorPos(1, y)
                end
            else
                term.setTextColor(16384)
                term.write(err)
                term.setTextColor(1)
                y = y + 1
                if y > h then
                    y = y - 1
                    term.scroll(1)
                end
                term.setCursorPos(1, y)
            end
        end
        term.setCursorBlink(false)
        term.clear()
    end
    allWaiting = true
    for pid, process in pairs(processes) do if pid ~= 0 then
        local dead = true
        for tid, thread in pairs(process.threads) do
            local args
            if thread.status == "starting" then args = thread.args
            elseif thread.status == "syscall" then args = thread.syscall_return
            elseif thread.status == "preempt" then args = empty_packed_table
            elseif thread.status == "suspended" then args = ev end
            if thread.status ~= "dead" and (not thread.filter or thread.filter(process, thread, ev)) then
                local old_dead = dead
                dead = false
                thread.filter = nil
                local params
                if thread.yielding then
                    --syslog.debug("Resuming yielded syscall")
                    params = {n = thread.syscall_return.n, true, "syscall", thread.yielding, table.unpack(thread.syscall_return, 4, thread.syscall_return.n)}
                    thread.yielding = nil
                else
                    --syslog.debug("Resuming thread", tid)
                    local start = os.epoch "utc"
                    params = table.pack(coroutine.resume(thread.coro, table.unpack(args, 1, args.n)))
                    --syslog.debug("Yield", params.n, table.unpack(params, 1, params.n))
                    process.cputime = process.cputime + (os.epoch "utc" - start) / 1000
                end
                if params[2] == "syscall" then
                    --syslog.debug("Calling syscall", params[3])
                    thread.status = "syscall"
                    allWaiting = false
                    if params[3] and syscalls[params[3]] then
                        thread.syscall_return = table.pack(pcall(syscalls[params[3]], process, thread, table.unpack(params, 4, params.n)))
                        if not thread.syscall_return[1] and type(thread.syscall_return[2]) == "string" then
                            syslog.log({level = 0, category = "Syscall Failure", process = 0}, thread.syscall_return[2])
                            thread.syscall_return[2] = thread.syscall_return[2]:gsub("kernel:%d+: ", "")
                        end
                        if thread.syscall_return[2] == kSyscallYield then thread.yielding = thread.syscall_return[3] end
                    else thread.syscall_return = {false, "No such syscall", n = 2} end
                elseif params[2] == "preempt" then
                    thread.status = "preempt"
                    allWaiting = false
                elseif coroutine.status(thread.coro) == "dead" then
                    thread.status = "dead"
                    thread.return_value = params[2]
                    if not params[1] then syslog.log({level = 4, process = pid, thread = tid, category = "Application Error"}, debug.traceback(thread.coro, params[2])) end
                    -- TODO: handle reaping?
                    dead = old_dead
                else
                    --syslog.debug("Standard yield", params.n, table.unpack(params, 1, params.n))
                    --syslog.debug(debug.traceback(thread.coro))
                    thread.status = "suspended"
                end
            end
        end
        if dead and pid == init_pid then
            init_retval = process.threads[0].return_value
            processes[pid] = nil
        end
    end end
end