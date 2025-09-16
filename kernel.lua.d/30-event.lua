--- Stores a list of used timers.
timerMap = {}
--- Stores a list of used alarms.
alarmMap = {}

local serviceRegistry = {}

function syscalls.kill(process, thread, pid, signal)
    expect(1, pid, "number")
    expect(2, signal, "number")
    local target = processes[pid]
    if not target then error("No such process", 2) end
    if process.user ~= "root" and process.user ~= target.user then error("Permission denied", 2) end
    --syslog.debug("Sending signal", signal, "to PID", pid)
    if signal == 9 then
        reap_process(target)
        if processes[target.parent] then syscalls.queueEvent(processes[target.parent], nil, "process_complete", {id = pid, result = 9}) end
        processes[pid] = nil
    elseif target.signalHandlers[signal] then
        userModeCallback(target, target.signalHandlers[signal], signal)
    else
        syscalls.queueEvent(target, nil, "signal", {signal = signal})
    end
end

--- Sends a signal to a process from the kernel asynchronously.
function killProcess(pid, signal)
    expect(1, pid, "number")
    expect(2, signal, "number")
    local target = processes[pid]
    if not target then return end
    --syslog.debug("Sending signal", signal, "to PID", pid)
    if signal == 9 then
        reap_process(target)
        if processes[target.parent] then syscalls.queueEvent(processes[target.parent], nil, "process_complete", {id = pid, result = 9}) end
        processes[pid] = nil
    elseif target.signalHandlers[signal] then
        local id = syscalls.newthread(target, nil, target.signalHandlers[signal], signal)
        target.threads[id].name = "<signal handler:" .. signal .. ">"
    else
        syscalls.queueEvent(target, nil, "signal", {signal = signal})
    end
end

function syscalls.signal(process, thread, signal, handler)
    expect(1, signal, "number")
    expect(2, handler, "function", "nil")
    process.signalHandlers[signal] = handler
end

function syscalls.queueEvent(process, thread, name, params)
    expect(1, name, "string")
    expect(2, params, "table")
    process.eventQueue[#process.eventQueue+1] = {name, params}
end

function syscalls.sendEvent(process, thread, pid, name, params)
    expect(1, pid, "number")
    expect(2, name, "string")
    local target = processes[pid]
    if not target then return false end
    target.eventQueue[#target.eventQueue+1] = {"remote_event", {type = name, sender = process.id, data = params}}
    wakeup(target)
    return true
end

function syscalls.peekEvent(process, thread)
    local ev = process.eventQueue[#process.eventQueue]
    if not ev then return nil end
    local args = {}
    for k, v in pairs(ev[2]) do args[k] = v end
    return ev[1], args
end

function syscalls.register(process, thread, name)
    expect(1, name, "string")
    if serviceRegistry[name] then return false end
    serviceRegistry[name] = process.id
    process.dependents[#process.dependents+1] = {gc = function() serviceRegistry[name] = nil end}
    return true
end

function syscalls.lookup(process, thread, name)
    expect(1, name, "string")
    return serviceRegistry[name]
end

function syscalls.timer(process, thread, timeout)
    expect(1, timeout, "number")
    local tm = os.startTimer(timeout)
    timerMap[tm] = process
    return bit32.band(tm, 0x7FFFFFFF)
end

-- TODO: Determine the type of time for the alarm + how to expose it to userland
function syscalls.alarm(process, thread, timeout)
    expect(1, timeout, "number")
    local tm = os.setAlarm(timeout)
    alarmMap[tm] = process
    return bit32.bor(tm, 0x80000000)
end

function syscalls.cancel(process, thread, tm)
    expect(1, tm, "number")
    if bit32.btest(tm, 0x80000000) then
        tm = bit32.band(tm, 0x7FFFFFFF)
        if alarmMap[tm] ~= process then error("No such alarm") end
        os.cancelAlarm(tm)
        alarmMap[tm] = nil
    else
        if timerMap[tm] ~= process then error("No such timer") end
        os.cancelTimer(tm)
        timerMap[tm] = nil
    end
end

eventHooks.terminate = eventHooks.terminate or {}
eventHooks.terminate[#eventHooks.terminate+1] = function()
    if currentTTY.frontmostProcess then syscalls.kill(KERNEL, nil, currentTTY.frontmostProcess.id, 2) terminal.write(currentTTY, "^T") end
end

eventParameterMap = {
    alarm = {"id"},
    char = {"character"},
    key = {"keycode", "isRepeat"},
    key_up = {"keycode"},
    mouse_click = {"button", "x", "y"},
    mouse_drag = {"button", "x", "y"},
    mouse_up = {"button", "x", "y"},
    mouse_scroll = {"direction", "x", "y"},
    paste = {"text"},
    redstone = {},
    term_resize = {},
    timer = {"id"},
    turtle_inventory = {}
}

do
    local maxkey = 0
    for _, v in pairs(keys) do if type(v) == "number" then maxkey = math.max(maxkey, v) end end
    if table.create then keymap = table.create(maxkey, 0) else
        -- We're using some sneaky hacks here to be able to ensure the LUT is allocated as an array and not a hashmap
        -- Essentially, we load a pre-assembled function with the instructions `NEWTABLE 0 $maxkey 0; RETURN 0 2`
        -- This depends on the Lua version, so we implement it specially for each version detected
        -- (Note: This no longer works as of CC:T 1.109, but we'll keep it here because it's cool.)
        local code
        local dump_ok, template = pcall(string.dump, function() end)
        if dump_ok then
            local tabsize = (function(x)
                if x < 8 then return x end
                local e = 0
                while x >= 128 do x, e = bit32.rshift(x + 0xf, 4), e + 4 end
                while x >= 16 do x, e = bit32.rshift(x + 1, 1), e + 1 end
                return bit32.bor((e + 1) * 8, x - 8)
            end)(maxkey)
            syslog.debug("Key table sizes:", maxkey, tabsize)
            if _VERSION == "Lua 5.1" then code = template:sub(1, 12) .. ("I" .. template:byte(9) .. "IIBBBBIIIIIIII"):pack(0, 0, 0, 0, 0, 0, 1, 2, tabsize * 0x800000 + 10, 0x0100001E, 0, 0, 0, 0, 0)
            elseif _VERSION == "Lua 5.2" then code = template:sub(1, 18) .. ("IIBBBIIIIIIIIII"):pack(0, 0, 0, 0, 1, 2, tabsize * 0x800000 + 11, 0x0100001F, 0, 0, 0, 0, 0, 0, 0)
            elseif _VERSION == "Lua 5.3" then code = template:sub(1, 17 + ("jn"):packsize()) .. ("BBIIBBBIIIIIIIII"):pack(0, 0, 0, 0, 0, 0, 1, 2, tabsize * 0x800000 + 11, 0x01000026, 0, 0, 0, 0, 0, 0)
            elseif _VERSION == "Lua 5.4" then code = template:sub(1, 15 + ("jn"):packsize()) .. ("BBBBBBBBIIIBBBBBBB"):pack(0, 0x80, 0x80, 0x80, 0, 0, 1, 0x83, 0x00000013, maxkey * 0x80 + 82, 0x00008048, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80) end
            if code then
                local fn, err = load(code, nil, "b")
                if fn then keymap = fn() else syslog.debug("Could not load key table code:", err) end
            end
        end
        if not keymap then
            -- Fall back on text Lua allocation method
            --- Stores a mapping of CraftOS keys to Phoenix keycodes.
            keymap = load("return {" .. ("nil,"):rep(maxkey) .. "}")()
        end
    end
    -- Letters, numpad numbers and function keys are easy
    for i = 0x61, 0x7A do keymap[keys[string.char(i)]] = i end
    for i = 0x81, 0x99 do if keys["f" .. bit32.band(i, 31)] then keymap[keys["f" .. bit32.band(i, 31)]] = i end end
    for i = 0xA0, 0xA9 do keymap[keys["numPad" .. bit32.band(i, 15)]] = i end
    -- The rest have to be added manually
    keymap[keys.backspace] = 0x08
    keymap[keys.tab] = 0x09
    keymap[keys.enter or keys["return"]] = 0x0A
    keymap[keys.space] = 0x20
    keymap[keys.apostrophe] = 0x27
    keymap[keys.comma] = 0x2C
    keymap[keys.minus] = 0x2D
    keymap[keys.period] = 0x2E
    keymap[keys.slash] = 0x2F
    keymap[keys.zero] = 0x30
    keymap[keys.one] = 0x31
    keymap[keys.two] = 0x32
    keymap[keys.three] = 0x33
    keymap[keys.four] = 0x34
    keymap[keys.five] = 0x35
    keymap[keys.six] = 0x36
    keymap[keys.seven] = 0x37
    keymap[keys.eight] = 0x38
    keymap[keys.nine] = 0x39
    keymap[keys.semicolon or keys.semiColon] = 0x3B
    keymap[keys.equals] = 0x3D
    keymap[keys.leftBracket] = 0x5B
    keymap[keys.backslash] = 0x5C
    keymap[keys.rightBracket] = 0x5D
    keymap[keys.grave] = 0x60
    keymap[keys.delete] = 0x7F
    keymap[keys.insert] = 0x80
    if keys.convert then keymap[keys.convert] = 0x9A end
    if keys.noconvert then keymap[keys.noconvert] = 0x9B end
    if keys.kana then keymap[keys.kana] = 0x9C end
    if keys.kanji then keymap[keys.kanji] = 0x9D end
    if keys.yen then keymap[keys.yen] = 0x9E end
    keymap[keys.numPadDecimal] = 0x9F
    keymap[keys.numPadAdd] = 0xAA
    keymap[keys.numPadSubtract] = 0xAB
    if keys.numPadMultiply then keymap[keys.numPadMultiply] = 0xAC end
    keymap[keys.numPadDivide] = 0xAD
    keymap[keys.numPadEqual or keys.numPadEquals] = 0xAE
    keymap[keys.numPadEnter] = 0xAF
    keymap[keys.leftCtrl] = 0xB0
    keymap[keys.rightCtrl] = 0xB1
    keymap[keys.leftAlt] = 0xB2
    keymap[keys.rightAlt] = 0xB3
    keymap[keys.leftShift] = 0xB4
    keymap[keys.rightShift] = 0xB5
    if keys.leftSuper then keymap[keys.leftSuper] = 0xB6 end
    if keys.rightSuper then keymap[keys.rightSuper] = 0xB7 end
    keymap[keys.capsLock] = 0xB8
    keymap[keys.numLock] = 0xB9
    keymap[keys.scrollLock or keys.scollLock] = 0xBA
    if keys.printScreen then keymap[keys.printScreen] = 0xBB end
    keymap[keys.pause] = 0xBC
    if keys.menu then keymap[keys.menu] = 0xBD end
    if keys.stop then keymap[keys.stop] = 0xBE end
    if keys.ax then keymap[keys.ax] = 0xBF end
    keymap[keys.up] = 0xC0
    keymap[keys.down] = 0xC1
    keymap[keys.left] = 0xC2
    keymap[keys.right] = 0xC3
    keymap[keys.pageUp] = 0xC4
    keymap[keys.pageDown] = 0xC5
    keymap[keys.home] = 0xC6
    keymap[keys["end"]] = 0xC7
    if keys.circumflex or keys.cimcumflex then keymap[keys.circumflex or keys.cimcumflex] = 0xC8 end
    if keys.at then keymap[keys.at] = 0xC9 end
    if keys.colon then keymap[keys.colon] = 0xCA end
    if keys.underscore then keymap[keys.underscore] = 0xCB end
end
