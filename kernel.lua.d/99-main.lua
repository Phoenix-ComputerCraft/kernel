-- The device tree is initialized only once all kernel modules are fully loaded to avoid losses
xpcall(hardware.register, function(error)
    panic("An error occurred while registering devices: " .. error)
end, deviceTreeRoot, rootDriver)
local empty_packed_table = {n = 0}
local init_process = processes[syscalls.fork(KERNEL, nil, function() end, "init")]
local init_pid = init_process.id
local init_ok, init_err
if args.init then
    init_ok, init_err = pcall(syscalls.exec, init_process, nil, args.initrd and "/init" or args.init)
end
if not init_ok then
    syslog.log({level = "error", process = 0}, "Could not load init:", init_err)
    syslog.log("Could not find provided init, trying default locations")
    for _,v in ipairs{"/sbin/init", "/etc/init", "/bin/init", "/bin/sh"} do
        syslog.log("Trying", v)
        init_ok, init_err = pcall(syscalls.exec, init_process, nil, v)
        if not init_ok then syslog.log({level = "error", process = 0}, "Could not load init:", init_err) end
        if init_ok then break end
    end
    if not init_ok then panic("No working init found") end
end
syslog.log("Starting init from " .. processes[init_pid].name)
local allWaiting = false
local executed = setmetatable({}, {__mode = "k"})
function wakeup(process) if #process.eventQueue > 0 and not executed[process] then allWaiting = false end end

local yield = coroutine.yield
function coroutine.yield(...)
    if coroutine.running() == mainThread then error("attempt to yield from kernel main thread", 2) end
    return yield(...)
end
debug.protect(coroutine.yield)

-- Basic built-in debugger for testing
-- TODO: Improve this A LOT!
eventHooks.key = eventHooks.key or {}
eventHooks.key[#eventHooks.key+1] = function(ev)
    if keysHeld.ctrl and keysHeld.shift and ev[2] == keys.f10 then
        local old = currentTTY
        local tty = terminal.makeTTY(term, term.getSize())
        currentTTY = tty
        terminal.write(tty, "Entering debug console.\n")
        terminal.redraw(tty, true)
        local running = true
        while running do
            terminal.write(tty, "lua> ")
            terminal.redraw(tty)
            while true do
                local ev = {yield()}
                if ev[1] == "char" or ev[1] == "paste" then
                    if tty.flags.cbreak then tty.buffer = tty.buffer .. ev[2]
                    else tty.preBuffer = tty.preBuffer .. ev[2] end
                    if tty.flags.echo then terminal.write(tty, ev[2]) terminal.redraw(tty) end
                elseif ev[1] == "key" then
                    if ev[2] == keys.enter then
                        if tty.flags.cbreak then
                            tty.buffer = tty.buffer .. "\n"
                        else
                            tty.buffer = tty.buffer .. tty.preBuffer .. "\n"
                            tty.preBuffer = ""
                        end
                        if tty.flags.echo then terminal.write(tty, "\n") terminal.redraw(tty) end
                        break
                    elseif ev[2] == keys.backspace then
                        if tty.flags.cbreak then
                            -- TODO: uh, what is this supposed to be?
                        elseif #tty.preBuffer > 0 then
                            tty.preBuffer = tty.preBuffer:sub(1, -2)
                            if tty.flags.echo then terminal.write(tty, "\b \b") terminal.redraw(tty) end
                        end
                    end
                end
            end
            local fn, err = load("return " .. tty.buffer, "=lua", "t", setmetatable({exit = function() running = false end, ps = function() local retval = {} for k, v in pairs(processes) do retval[k] = v.name end return retval end}, {__index = _G}))
            if not fn then fn, err = load(tty.buffer, "=lua", "t", setmetatable({exit = function() running = false end, ps = function() local retval = {} for k, v in pairs(processes) do retval[k] = v.name end return retval end}, {__index = _G})) end
            tty.buffer = ""
            if fn then
                local res = table.pack(pcall(fn))
                if res[1] then
                    for i = 2, res.n do
                        if pretty_print then pretty_print(tty, res[i]) else
                            local s = tostring(res[i]) -- TODO: avoid __tostring injection (?)
                            if type(res[i]) == "table" then
                                local ok, ss = pcall(serialize, res[i])
                                if ok and ss then s = ss end
                            end
                            terminal.write(tty, s .. "\n")
                        end
                    end
                else
                    terminal.write(tty, "\x1b[31m" .. res[2] .. "\x1b[0m\n")
                end
            else
                terminal.write(tty, "\x1b[31m" .. err .. "\x1b[0m\n")
            end
            terminal.redraw(tty)
        end
        currentTTY = old
        terminal.redraw(currentTTY, true)
    end
end

local ttyEvents = {char = true, key = true, key_up = true, mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true, paste = true}

local ok, err = xpcall(function()
while processes[init_pid] do
    if not allWaiting then os.queueEvent("__event_queue_back") end
    while true do
        local ev = table.pack(yield())
        local name = ev[1]
        if name == "__event_queue_back" then break end
        local pushedEvent = false
        if eventHooks[name] then for _, v in ipairs(eventHooks[name]) do pushedEvent = v(ev) or pushedEvent end end
        if eventParameterMap[name] then
            local params = {}
            for i = 2, #eventParameterMap[name] + 1 do
                params[eventParameterMap[name][i-1]] = ev[i]
            end
            if name == "key" or name == "key_up" then
                params.keycode = keymap[params.keycode]
                params.ctrlHeld = keysHeld.ctrl
                params.altHeld = keysHeld.alt
                params.shiftHeld = keysHeld.shift
            end
            if name == "mouse_scroll" then
                params.direction = params.direction > 0
            end
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
    executed = setmetatable({}, {__mode = "k"})
    for pid, process in pairs(processes) do if pid ~= 0 and not process.paused then
        local gotev, ev = false, nil
        local dead = true
        for tid, thread in pairs(process.threads) do
            if not gotev and thread.status == "suspended" then
                ev = table.remove(process.eventQueue, 1) -- TODO: decide whether to optimize this
                gotev = true
            end
            if ev or thread.status ~= "suspended" then
                local allWait
                dead, allWait = executeThread(process, thread, ev or empty_packed_table, dead, allWaiting)
                allWaiting = allWait and allWaiting
            else dead = false end
        end
        if dead then
            process.isDead = true
            if process.lastReturnValue then
                if pid == init_pid then
                    init_retval = process.lastReturnValue.value or process.lastReturnValue.error
                elseif processes[process.parent] then
                    process.lastReturnValue.id = pid
                    processes[process.parent].eventQueue[#processes[process.parent].eventQueue+1] = {"process_complete", process.lastReturnValue}
                end
            end
            reap_process(process)
            processes[pid] = nil
            allWaiting = false
        end
        executed[process] = true
    end end
    --if processes[init_pid].paused then panic("init program paused") end
    terminal.redraw(currentTTY)
end
end, debug.traceback)
if not ok then syslog.log({level = "critical", traceback = true}, err) end
if postkill then postkill() end