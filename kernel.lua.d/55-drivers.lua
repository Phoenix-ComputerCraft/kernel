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

local function getNodeById(name)
    if localPeripherals[name] then
        if deviceTreeRoot.children[name] then
            return deviceTreeRoot.children[name]
        end
    else
        -- We don't know the parent of this peripheral, so we have to traverse all modems :(
        for k in pairs(localPeripherals) do
            if peripheral.getType(k) == "modem" and not peripheral.call(k, "isWireless") and deviceTreeRoot.children[k] and deviceTreeRoot.children[k].children[name] then
                return deviceTreeRoot.children[k].children[name]
            end
        end
    end
end

local function checkCall(self)
    self.internalState.peripheral = self.internalState.peripheral or {}
    if not self.internalState.peripheral.call then self.internalState.peripheral.call = peripheral.call end
end

local function shadowTable(process, mt)
    mt.__metatable = {}
    for _, v in pairs(mt) do
        setfenv(v, process.env)
        debug.protect(v)
    end
    return setmetatable({}, mt)
end

local function peripheralTypeCallback(driver, type)
    return function(node)
        local types, fn
        if node.parent == deviceTreeRoot then types, fn = {peripheral.getType(node.id)}, peripheral.call
        else types, fn = {peripheral.call(node.parent.id, "getTypeRemote", node.id)}, function(...) return peripheral.call(node.parent.id, "callRemote", node.id, ...) end end
        for _, v in ipairs(types) do if v == type then node.internalState.peripheral = {call = fn} return hardware.register(node, driver) end end
    end
end

local function register(type)
    return hardware.listen(peripheralTypeCallback(drivers["peripheral_" .. type], type), deviceTreeRoot)
end

local function noArgMethod(method)
    return function(self)
        return self.internalState.peripheral.call(self.id, method)
    end
end

local function noArgRootMethod(method)
    return function(self, process)
        if process.user ~= "root" then error("Permission denied", 0) end
        return self.internalState.peripheral.call(self.id, method)
    end
end

local function oneArgMethod(method)
    return function(...)
        local types = {...}
        return function(self, process, value)
            expect(1, value, table.unpack(types))
            return self.internalState.peripheral.call(self.id, method, value)
        end
    end
end

local function oneArgRootMethod(method)
    return function(...)
        local types = {...}
        return function(self, process, value)
            expect(1, value, table.unpack(types))
            if process.user ~= "root" then error("Permission denied", 0) end
            return self.internalState.peripheral.call(self.id, method, value)
        end
    end
end

--#region Root driver

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

function drivers.root.methods:getIsOn(process)
    return true
end

function drivers.root.methods:getId(process)
    return os.getComputerID()
end

function drivers.root.methods:getLabel(process)
    return os.getComputerLabel()
end

function drivers.root.methods:setLabel(process, label)
    expect(1, label, "string", "nil")
    os.setComputerLabel(label)
end

function drivers.root.methods:turnOn(process) end -- do nothing

function drivers.root.methods:shutdown(process)
    if process.user ~= "root" then error("Permission denied", 2) end
    syslog.log("System is shutting down.")
    killall()
    hardware.deregister(deviceTreeRoot, drivers.root)
    os.shutdown()
    while true do coroutine.yield() end
end

function drivers.root.methods:reboot(process)
    if process.user ~= "root" then error("Permission denied", 2) end
    syslog.log("System is restarting.")
    killall()
    hardware.deregister(deviceTreeRoot, drivers.root)
    os.reboot()
    while true do coroutine.yield() end
end

function drivers.root:init()
    for v in pairs(localPeripherals) do
        if peripheral.isPresent(v) then
            hardware.add(self, v)
        end
    end
    self.displayName = os.getComputerLabel()
end

function drivers.root:deinit()
    for v in pairs(localPeripherals) do
        if peripheral.isPresent(v) and self.children[v] then
            hardware.remove(self.children[v])
        end
    end
end

eventHooks.peripheral = eventHooks.peripheral or {}
eventHooks.peripheral[#eventHooks.peripheral+1] = function(ev)
    if localPeripherals[ev[2]] then
        local node, err = hardware.add(deviceTreeRoot, ev[2])
        if node then hardware.broadcast(deviceTreeRoot, "device_added", {device = hardware.path(node)})
        else syslog.log({level = "error", module = "Hardware"}, "Could not create new device: " .. err) end
    else
        -- We don't know the parent of this peripheral, so we have to traverse all modems :(
        for k in pairs(localPeripherals) do
            if peripheral.getType(k) == "modem" and not peripheral.call(k, "isWireless") and peripheral.call(k, "isPresentRemote", ev[2]) then
                if not deviceTreeRoot.children[k] then hardware.add(deviceTreeRoot, k) end
                local node, err = hardware.add(deviceTreeRoot.children[k], ev[2])
                if node then hardware.broadcast(deviceTreeRoot.children[k], "device_added", {device = hardware.path(node)})
                else syslog.log({level = "error", module = "Hardware"}, "Could not create new device: " .. err) end
                break
            end
        end
    end
end

eventHooks.peripheral_detach = eventHooks.peripheral_detach or {}
eventHooks.peripheral_detach[#eventHooks.peripheral_detach+1] = function(ev)
    local node = getNodeById(ev[2])
    if not node then
        syslog.log({level = "notice", module = "Hardware"}, "Received " .. ev[1] .. " event for device ID " .. ev[2] .. ", but no device node was found; ignoring")
        return
    end
    local path, parent = hardware.path(node), node.parent
    hardware.remove(node)
    hardware.broadcast(parent, "device_removed", {device = path})
end

rootDriver = drivers.root

--#endregion
--#region Command block peripheral

drivers.peripheral_command = {
    name = "peripheral_command",
    type = "command",
    properties = {
        "command"
    },
    methods = {}
}

drivers.peripheral_command.methods.getCommand = noArgRootMethod "getCommand"
drivers.peripheral_command.methods.setCommand = oneArgRootMethod "setCommand" ("string")
drivers.peripheral_command.methods.run = noArgRootMethod "runCommand"

function drivers.peripheral_command:init()
    checkCall(self)
    self.displayName = "Command block at " .. self.id
end

register "command"

--#endregion
--#region Computer peripheral

drivers.peripheral_computer = {
    name = "peripheral_computer",
    type = "computer",
    properties = {
        "isOn",
        "id",
        "label"
    },
    methods = {}
}

drivers.peripheral_computer.methods.getIsOn = noArgMethod "isOn"
drivers.peripheral_computer.methods.getId = noArgMethod "getID"
drivers.peripheral_computer.methods.getLabel = noArgMethod "getLabel"
drivers.peripheral_computer.methods.turnOn = noArgRootMethod "turnOn"
drivers.peripheral_computer.methods.shutdown = noArgRootMethod "shutdown"
drivers.peripheral_computer.methods.reboot = noArgRootMethod "reboot"

function drivers.peripheral_command:init()
    checkCall(self)
    local label = self.internalState.peripheral.call(self.id, "getLabel")
    self.displayName = (label or ("Computer " .. self.internalState.peripheral.call(self.id, "getID"))) .. " at " .. self.id
end

register "computer"

--#endregion
--#region Disk drive peripheral

drivers.peripheral_drive = {
    name = "peripheral_drive",
    type = "drive",
    properties = {
        "state"
    },
    methods = {}
}

function drivers.peripheral_drive.methods:getState(process)
    if not self.internalState.peripheral.call(self.id, "isDiskPresent") then return nil end
    return {
        isAudio = self.internalState.peripheral.call(self.id, "hasAudio"),
        label = self.internalState.peripheral.call(self.id, "getDiskLabel"),
        id = self.internalState.peripheral.call(self.id, "getDiskID")
    }
end

drivers.peripheral_drive.methods.setLabel = oneArgMethod "setDiskLabel" ("string", "nil")

function drivers.peripheral_drive.methods:play(process)
    if not self.internalState.peripheral.call(self.id, "hasAudio") then error("Inserted disk is not an audio disc", 2) end
    return self.internalState.peripheral.call(self.id, "playAudio")
end

drivers.peripheral_drive.methods.stop = noArgMethod "stopAudio"
drivers.peripheral_drive.methods.eject = noArgMethod "ejectDisk"
drivers.peripheral_drive.methods.insert = oneArgRootMethod "insertDisk" ("string")

function drivers.peripheral_drive:init()
    checkCall(self)
    self.displayName = (peripheral.call(self.id, "getDiskLabel") or "No disk") .. " on drive " .. self.id
end

register "device"

eventHooks.disk = eventHooks.disk or {}
eventHooks.disk[#eventHooks.disk+1] = function(ev)
    local node = getNodeById(ev[2])
    if not node then
        syslog.log({level = "notice", module = "Hardware"}, "Received " .. ev[1] .. " event for device ID " .. ev[2] .. ", but no device node was found; ignoring")
        return
    end
    hardware.broadcast(node, "disk", {device = hardware.path(node)})
end

eventHooks.disk_eject = eventHooks.disk_eject or {}
eventHooks.disk_eject[#eventHooks.disk_eject+1] = function(ev)
    local node = getNodeById(ev[2])
    if not node then
        syslog.log({level = "notice", module = "Hardware"}, "Received " .. ev[1] .. " event for device ID " .. ev[2] .. ", but no device node was found; ignoring")
        return
    end
    hardware.broadcast(node, "disk_eject", {device = hardware.path(node)})
end

--#endregion
--#region Generic energy storage peripheral

drivers.peripheral_energy_storage = {
    name = "peripheral_energy_storage",
    type = "energy_storage",
    properties = {
        "energy",
        "capacity"
    },
    methods = {}
}

drivers.peripheral_energy_storage.methods.getEnergy = noArgMethod "getEnergy"
drivers.peripheral_energy_storage.methods.getCapacity = noArgMethod "getEnergyCapacity"

function drivers.peripheral_energy_storage:init()
    checkCall(self)
    self.displayName = "Energy storage block at " .. self.id
end

register "energy_storage"

--#endregion
--#region Generic fluid storage peripheral

drivers.peripheral_fluid_storage = {
    name = "peripheral_fluid_storage",
    type = "fluid_storage",
    properties = {
        "tanks"
    },
    methods = {}
}

drivers.peripheral_fluid_storage.methods.getTanks = noArgMethod "tanks"

function drivers.peripheral_fluid_storage.methods:push(process, to, limit, name)
    expect(1, to, "string")
    expect(2, limit, "number", "nil")
    expect(3, name, "string", "nil")
    local target
    local targets = {hardware.get(to)}
    if #targets == 1 then target = targets[1]
    else for _, v in ipairs(targets) do if v.parent == self.parent then target = v break end end end
    if not target then error("No such device", 0)
    elseif target.parent ~= self.parent then error("Devices must be on the same network", 0) end
    local ok = false
    for _, v in ipairs(target.drivers) do if v == drivers.peripheral_fluid_storage then ok = true break end end
    if not ok then error("Target device is not a fluid storage block", 0) end
    return self.internalState.peripheral.call(self.id, "pushFluid", target.id, limit, name)
end

function drivers.peripheral_fluid_storage.methods:pull(process, from, limit, name)
    expect(1, from, "string")
    expect(2, limit, "number", "nil")
    expect(3, name, "string", "nil")
    local target
    local targets = {hardware.get(from)}
    if #targets == 1 then target = targets[1]
    else for _, v in ipairs(targets) do if v.parent == self.parent then target = v break end end end
    if not target then error("No such device", 0)
    elseif target.parent ~= self.parent then error("Devices must be on the same network", 0) end
    local ok = false
    for _, v in ipairs(target.drivers) do if v == drivers.peripheral_fluid_storage then ok = true break end end
    if not ok then error("Target device is not a fluid storage block", 0) end
    return self.internalState.peripheral.call(self.id, "pullFluid", target.id, limit, name)
end

function drivers.peripheral_fluid_storage:init()
    checkCall(self)
    self.displayName = "Fluid storage block at " .. self.id
end

register "fluid_storage"

--#endregion
--#region Generic inventory peripheral

drivers.peripheral_inventory = {
    name = "peripheral_inventory",
    type = "inventory",
    properties = {
        "size",
        "items"
    },
    methods = {}
}

drivers.peripheral_inventory.methods.getSize = noArgMethod "size"
drivers.peripheral_inventory.methods.getItems = noArgMethod "list"
drivers.peripheral_inventory.methods.detail = oneArgMethod "getItemDetail" ("number")
drivers.peripheral_inventory.methods.limit = oneArgMethod "getItemLimit" ("number")

function drivers.peripheral_inventory.methods:push(process, to, slot, limit, toSlot)
    expect(1, to, "string")
    expect(2, slot, "number")
    expect(3, limit, "number", "nil")
    expect(4, toSlot, "number", "nil")
    local target
    local targets = {hardware.get(to)}
    if #targets == 1 then target = targets[1]
    else for _, v in ipairs(targets) do if v.parent == self.parent then target = v break end end end
    if not target then error("No such device", 0)
    elseif target.parent ~= self.parent then error("Devices must be on the same network", 0) end
    local ok = false
    for _, v in ipairs(target.drivers) do if v == drivers.peripheral_inventory then ok = true break end end
    if not ok then error("Target device is not an inventory block", 0) end
    return self.internalState.peripheral.call(self.id, "pushItems", target.id, slot, limit, toSlot)
end

function drivers.peripheral_inventory.methods:pull(process, from, slot, limit, toSlot)
    expect(1, from, "string")
    expect(2, slot, "number")
    expect(3, limit, "number", "nil")
    expect(4, toSlot, "number", "nil")
    local target
    local targets = {hardware.get(from)}
    if #targets == 1 then target = targets[1]
    else for _, v in ipairs(targets) do if v.parent == self.parent then target = v break end end end
    if not target then error("No such device", 0)
    elseif target.parent ~= self.parent then error("Devices must be on the same network", 0) end
    local ok = false
    for _, v in ipairs(target.drivers) do if v == drivers.peripheral_inventory then ok = true break end end
    if not ok then error("Target device is not an inventory block", 0) end
    return self.internalState.peripheral.call(self.id, "pullItems", target.id, slot, limit, toSlot)
end

function drivers.peripheral_inventory:init()
    checkCall(self)
    self.displayName = "Inventory at " .. self.id
end

register "inventory"

--#endregion
--#region Monitor peripheral

--#endregion
--#region Printer peripheral

drivers.peripheral_printer = {
    name = "peripheral_printer",
    type = "printer",
    properties = {
        "inkLevel",
        "paperLevel"
    },
    methods = {}
}

drivers.peripheral_printer.methods.getInkLevel = noArgMethod "getInkLevel"
drivers.peripheral_printer.methods.getPaperLevel = noArgMethod "getPaperLevel"

-- This is most definitely overengineered
function drivers.peripheral_printer.methods:page(process)
    if self.internalState.printer.open then
        self.internalState.peripheral.call(self.id, "endPage")
        self.internalState.printer.open = false
    end
    if not self.internalState.peripheral.call(self.id, "newPage") then return nil end
    self.internalState.printer.open = true
    local title, x, y
    local function write(...)
        if not self.internalState.printer.open then error("attempt to use closed page", 2) end
        return self.internalState.peripheral.call(self.id, "write", ...)
    end
    local function close()
        if not self.internalState.printer.open then return true end
        if not self.internalState.peripheral.call(self.id, "endPage") then return false end
        self.internalState.printer.open = false
    end
    setfenv(write, process.env)
    setfenv(close, process.env)
    debug.protect(write)
    debug.protect(close)
    return shadowTable(process, {
        __index = function(_, idx)
            if not self.internalState.printer.open then error("attempt to use closed page", 2) end
            if idx == "size" then
                local width, height = self.internalState.peripheral.call(self.id, "getPageSize")
                return shadowTable(process, {
                    __index = function(_, idx)
                        if idx == "width" then return width
                        elseif idx == "height" then return height end
                    end,
                    __newindex = function()
                        error("Cannot modify read-only table", 2)
                    end
                })
            elseif idx == "cursor" then
                x, y = self.internalState.peripheral.call(self.id, "getCursorPos")
                return shadowTable(process, {
                    __index = function(_, idx)
                        if idx == "x" then return x
                        elseif idx == "y" then return y end
                    end,
                    __newindex = function(_, idx, val)
                        if idx == "x" then
                            x = val
                            self.internalState.peripheral.call(self.id, "setCursorPos", x, y)
                        elseif idx == "y" then
                            y = val
                            self.internalState.peripheral.call(self.id, "setCursorPos", x, y)
                        else error("Cannot modify member '" .. idx .. "'", 2) end
                    end
                })
            elseif idx == "title" then return title
            elseif idx == "isOpen" then return self.internalState.printer.open
            elseif idx == "write" then return write
            elseif idx == "close" then return close end
        end,
        __newindex = function(_, idx, val)
            if not self.internalState.printer.open then error("attempt to use closed page", 2) end
            if idx == "cursor" then
                if type(val) ~= "table" then error("bad value for 'cursor' (expected table, got " .. type(val) .. ")", 2) end
                expect.field(val, "x", "number")
                expect.field(val, "y", "number")
                x, y = val.x, val.y
                self.internalState.peripheral.call(self.id, "setCursorPos", x, y)
            elseif idx == "title" then
                if type(val) ~= "string" and val ~= nil then error("bad value for 'title' (expected string, got " .. type(val) .. ")", 2) end
                title = val
                self.internalState.peripheral.call(self.id, "setPageTitle", title)
            else error("Cannot modify member '" .. idx .. "'", 2) end
        end
    })
end

function drivers.peripheral_printer:init()
    checkCall(self)
    self.displayName = "Speaker at " .. self.id
    self.internalState.printer = {open = false}
end

register "printer"

--#endregion
--#region Speaker peripheral

drivers.peripheral_speaker = {
    name = "peripheral_speaker",
    type = "speaker",
    properties = {},
    methods = {}
}

function drivers.peripheral_speaker.methods:playNote(process, instrument, volume, pitch)
    expect(1, instrument, "string")
    expect(2, volume, "number", "nil")
    expect(3, pitch, "number", "nil")
    if volume then expect.range(volume, 0, 3) end
    if pitch then expect.range(pitch, 0, 24) end
    return self.internalState.peripheral.call(self.id, "playNote", instrument, volume, pitch)
end

function drivers.peripheral_speaker.methods:playSound(process, name, volume, speed)
    expect(1, name, "string")
    expect(2, volume, "number", "nil")
    expect(3, speed, "number", "nil")
    if volume then expect.range(volume, 0, 3) end
    if speed then expect.range(speed, 0.5, 2.0) end
    return self.internalState.peripheral.call(self.id, "playNote", name, volume, speed)
end

function drivers.peripheral_speaker.methods:playAudio(audio, volume)
    expect(1, audio, "table")
    expect(2, volume, "number", "nil")
    if volume then expect.range(volume, 0, 3) end
    return self.internalState.peripheral.call(self.id, "playAudio", audio, volume)
end

drivers.peripheral_speaker.methods.stop = noArgMethod "stop"

function drivers.peripheral_command:init()
    checkCall(self)
    self.displayName = "Speaker at " .. self.id
end

register "speaker"

eventHooks.speaker_audio_empty = eventHooks.speaker_audio_empty or {}
eventHooks.speaker_audio_empty[#eventHooks.speaker_audio_empty+1] = function(ev)
    local node = getNodeById(ev[2])
    if not node then
        syslog.log({level = "notice", module = "Hardware"}, "Received " .. ev[1] .. " event for device ID " .. ev[2] .. ", but no device node was found; ignoring")
        return
    end
    hardware.broadcast(node, "speaker_audio_empty", {device = hardware.path(node)})
end

--#endregion
--#region Modem peripheral

--#endregion
