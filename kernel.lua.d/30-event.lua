function syscalls.kill(process, thread, pid, signal)
    expect(1, pid, "number")
    expect(2, signal, "number")
    local target = processes[pid]
    if not target then error("No such process", 2) end
    if process.user ~= "root" and process.user ~= target.user then error("Permission denied", 2) end
    syslog.debug("Sending signal", signal, "to PID", pid)
    if signal == 9 then
        reap_process(target)
        if processes[target.parent] then syscalls.queueEvent(processes[target.parent], nil, "process_complete", {id = pid, result = 9}) end
        processes[pid] = nil
    elseif target.signalHandlers[signal] then
        userModeCallback(target, target.signalHandlers[signal])
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
    if not target then error("No such process", 2) end
    -- TODO: figure out filtering
    target.eventQueue[#target.eventQueue+1] = {"remote_event", {type = name, sender = process.id, data = params}}
    return true
end

eventHooks.terminate = eventHooks.terminate or {}
eventHooks.terminate[#eventHooks.terminate+1] = function()
    if currentTTY.frontmostProcess then syscalls.kill(KERNEL, nil, currentTTY.frontmostProcess.id, 2) terminal.write(currentTTY, "^T") end
end

eventParameterMap = {
    alarm = {"id"},
    char = {"character"},
    disk = {"side"},
    disk_eject = {"side"},
    http_check = {"url", "isValid", "error"},
    http_failure = {"url", "error", "handle"},
    http_success = {"url", "handle"},
    key = {"keycode", "isRepeat"},
    key_up = {"keycode"},
    monitor_resize = {"side"},
    monitor_touch = {"side", "x", "y"},
    mouse_click = {"button", "x", "y"},
    mouse_drag = {"button", "x", "y"},
    mouse_up = {"button", "x", "y"},
    mouse_scroll = {"direction", "x", "y"},
    paste = {"text"},
    peripheral = {"side"},
    peripheral_detach = {"side"},
    redstone = {},
    term_resize = {},
    timer = {"id"},
    turtle_inventory = {},
    websocket_closed = {"url"},
    websocket_failure = {"url", "error"},
    websocket_success = {"url", "handle"},
    websocket_message = {"url", "message", "isBinary"}
}