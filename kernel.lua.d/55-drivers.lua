local driverTemplate = {
    name = "root",
    type = "computer",
    properties = {
        "label",
        "id"
    },
    methods = {
        getLabel = function() end,
        setLabel = function(label) end,
        getId = function() end,
        shutdown = function() end,
        reboot = function() end
    },
    init = function(node)
        -- initialize node
    end,
    deinit = function(node)
        -- deinitialize node
    end
}

local localPeripherals = {top = true, bottom = true, left = true, right = true, front = true, back = true}

local drivers = {}

local function peripheralTypeCallback(driver, type)
    return function(node)
        local types
        if node.parent == deviceTreeRoot then types = {peripheral.getType(node.id)}
        else types = {peripheral.call(node.parent.id, "getTypeRemote", node.id)} end
        for _, v in ipairs(types) do if v == type then return hardware.register(node, driver) end end
    end
end

-- Root driver

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

drivers.root = {
    name = "root",
    type = "computer",
    properties = {
        "isOn",
        "id",
        "label"
    },
    methods = {}
}

function drivers.root.methods.getIsOn(node, process)
    return true
end

function drivers.root.methods.getId(node, process)
    return os.getComputerID()
end

function drivers.root.methods.getLabel(node, process)
    return os.getComputerLabel()
end

function drivers.root.methods.setLabel(node, process, label)
    expect(1, label, "string", "nil")
    os.setComputerLabel(label)
end

function drivers.root.methods.turnOn(node, process) end -- do nothing

function drivers.root.methods.shutdown(node, process)
    if process.user ~= "root" then error("Permission denied", 2) end
    syslog.log("System is shutting down.")
    killall()
    hardware.deregister(deviceTreeRoot, drivers.root)
    os.shutdown()
    while true do coroutine.yield() end
end

function drivers.root.methods.reboot(node, process)
    if process.user ~= "root" then error("Permission denied", 2) end
    syslog.log("System is restarting.")
    killall()
    hardware.deregister(deviceTreeRoot, drivers.root)
    os.reboot()
    while true do coroutine.yield() end
end

function drivers.root.init(node)
    for v in pairs(localPeripherals) do
        if peripheral.isPresent(v) then
            hardware.add(node, v)
        end
    end
    node.displayName = os.getComputerLabel()
end

function drivers.root.deinit(node)
    for v in pairs(localPeripherals) do
        if peripheral.isPresent(v) and node.children[v] then
            hardware.remove(node.children[v])
        end
    end
end

-- Disk drive peripheral

drivers.peripheral_drive = {
    name = "peripheral_drive",
    type = "drive",
    properties = {
        "state"
    },
    methods = {}
}

function drivers.peripheral_drive.methods.getState(node, process)
    if not node.internalState.peripheral_call(node.id, "isDiskPresent") then return nil end
    return {
        isAudio = node.internalState.peripheral_call(node.id, "hasAudio"),
        label = node.internalState.peripheral_call(node.id, "getDiskLabel"),
        id = node.internalState.peripheral_call(node.id, "getDiskID")
    }
end

function drivers.peripheral_drive.methods.setLabel(node, process, label)
    expect(1, label, "string", "nil")
    node.internalState.peripheral_call(node.id, "setDiskLabel", label)
end

function drivers.peripheral_drive.methods.play(node, process)
    if not node.internalState.peripheral_call(node.id, "hasAudio") then error("Inserted disk is not an audio disc", 2) end
    node.internalState.peripheral_call(node.id, "playAudio")
end

function drivers.peripheral_drive.methods.stop(node, process)
    node.internalState.peripheral_call(node.id, "stopAudio")
end

function drivers.peripheral_drive.methods.eject(node, process)
    node.internalState.peripheral_call(node.id, "ejectDisk")
end

function drivers.peripheral_drive.methods.insert(node, process, path)
    expect(1, path, "string")
    if process.user ~= "root" then error("Permission denied", 2) end
    node.internalState.peripheral_call(node.id, "insertDisk", path)
end

function drivers.peripheral_drive.init(node)
    if not node.internalState.peripheral_call then node.internalState.peripheral_call = peripheral.call end
    node.displayName = (peripheral.call(node.id, "getDiskLabel") or "Empty drive") .. " on drive " .. node.id
end

hardware.listen(peripheralTypeCallback(drivers.peripheral_drive, "drive"), deviceTreeRoot)



eventHooks.peripheral = eventHooks.peripheral or {}
eventHooks.peripheral[#eventHooks.peripheral+1] = function(ev)
    if localPeripherals[ev[2]] then
        hardware.add(deviceTreeRoot, ev[2])
    else
        -- We don't know the parent of this peripheral, so we have to traverse all modems :(
        for k in pairs(localPeripherals) do
            if peripheral.getType(k) == "modem" and not peripheral.call(k, "isWireless") and peripheral.call(k, "isPresentRemote", ev[2]) then
                if not deviceTreeRoot.children[k] then hardware.add(deviceTreeRoot, k) end
                hardware.add(deviceTreeRoot.children[k], ev[2])
                break
            end
        end
    end
end

eventHooks.peripheral_detach = eventHooks.peripheral_detach or {}
eventHooks.peripheral_detach[#eventHooks.peripheral_detach+1] = function(ev)
    if localPeripherals[ev[2]] then
        if deviceTreeRoot.children[ev[2]] then hardware.remove(deviceTreeRoot.children[ev[2]]) end
    else
        -- We don't know the parent of this peripheral, so we have to traverse all modems :(
        for k in pairs(localPeripherals) do
            if peripheral.getType(k) == "modem" and not peripheral.call(k, "isWireless") and deviceTreeRoot.children[k] and deviceTreeRoot.children[k].children[ev[2]] then
                hardware.remove(deviceTreeRoot.children[k].children[ev[2]])
                break
            end
        end
    end
end

rootDriver = drivers.root