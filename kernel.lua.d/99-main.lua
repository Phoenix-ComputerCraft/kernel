local empty_packed_table = {n = 0}
local init_process = processes[syscalls.fork(KERNEL, nil, function() end, "init")]
local init_pid = init_process.id
local init_ok, init_err
if args.init then
    init_ok, init_err = pcall(syscalls.exec, init_process, nil, args.init)
end
if not init_ok then
    syslog.log({level = 4, process = 0}, "Could not load init:", init_err)
    syslog.log("Could not find provided init, trying default locations")
    for _,v in ipairs{"/sbin/init", "/etc/init", "/bin/init", "/bin/sh"} do
        syslog.log("Trying", v)
        init_ok, init_err = pcall(syscalls.exec, init_process, nil, v)
        if not init_ok then syslog.log({level = 4, process = 0}, "Could not load init:", init_err) end
        if init_ok then break end
    end
    if not init_ok then panic("No working init found") end
end
syslog.log("Starting init from " .. processes[init_pid].name)
local allWaiting = false

-- Basic built-in debugger for testing
-- TODO: Improve this A LOT!
eventHooks.key = eventHooks.key or {}
eventHooks.key[#eventHooks.key+1] = function(ev)
    if ev[2] == keys.f10 then
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
end

local ttyEvents = {char = true, key = true, key_up = true, mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true, paste = true}

local ok, err = xpcall(function()
while processes[init_pid] do
    if not allWaiting then os.queueEvent("__event_queue_back") end
    while true do
        local ev = table.pack(coroutine.yield())
        local name = ev[1]
        if name == "__event_queue_back" then break end
        if eventHooks[name] then for _, v in ipairs(eventHooks[name]) do v(ev) end end
        local pushedEvent = false
        if eventParameterMap[name] then
            local params = {}
            for i = 2, #eventParameterMap[name] + 1 do
                params[eventParameterMap[name][i-1]] = ev[i]
            end
            if name == "key" or name == "key_up" then params.keycode = keymap[params.keycode] end
            if ttyEvents[name] and currentTTY.frontmostProcess then
                currentTTY.frontmostProcess.eventQueue[#currentTTY.frontmostProcess.eventQueue+1] = {name, params}
                pushedEvent = true
            elseif name == "timer" or name == "alarm" then
                local proc
                if name == "timer" then proc = timerMap[ev[2]]
                else proc, params.id = alarmMap[ev[2]], bit32.bor(params.id, 0x80000000) end
                if proc then proc.eventQueue[#proc.eventQueue+1], pushedEvent = {name, params}, true end
            -- TODO: check more events
            end
        end
        if allWaiting and pushedEvent then break end
    end
    allWaiting = true
    for pid, process in pairs(processes) do if pid ~= 0 and not process.paused then
        local gotev, ev = false, nil
        local dead = true
        for tid, thread in pairs(process.threads) do
            if not gotev and thread.status == "suspended" then
                ev = table.remove(process.eventQueue, 1) -- TODO: decide whether to optimize this
                gotev = true
            end
            if ev or thread.status ~= "suspended" then
                dead, allWaiting = executeThread(process, thread, ev or empty_packed_table, dead, allWaiting)
            else dead = false end
        end
        if dead then
            process.isDead = true
            if pid == init_pid then
                init_retval = process.lastReturnValue.value or process.lastReturnValue.error
            elseif processes[process.parent] then
                processes[process.parent].eventQueue[#processes[process.parent].eventQueue+1] = {"process_complete", process.lastReturnValue}
            end
            reap_process(process)
            processes[pid] = nil
            allWaiting = false
        end
    end end
    --if processes[init_pid].paused then panic("init program paused") end
    terminal.redraw(currentTTY)
end
end, debug.traceback)
if not ok then syslog.log({level = 5}, err) end