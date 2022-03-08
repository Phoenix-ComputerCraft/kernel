-- UUID generation code

-- Borrowed from https://github.com/mpeterv/sha1
-- Calculates SHA1 for a string, returns it encoded as 40 hexadecimal digits.
local function sha1(str)
    str = str .. "\x80" .. ("\0"):rep(-(#str + 9) % 64) .. (">I8"):pack(#str)
    local h0, h1, h2, h3, h4, w = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0, {}
    for chunk_start = 1, #str, 64 do
        local uint32_start = chunk_start
        for i = 0, 15 do
            w[i] = str:byte(uint32_start) * 0x1000000 + str:byte(uint32_start+1) * 0x10000 + str:byte(uint32_start+2) * 0x100 + str:byte(uint32_start+3)
            uint32_start = uint32_start + 4
        end
        for i = 16, 79 do w[i] = bit32.lrotate(bit32.bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1) end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i <= 19 then f, k = bit32.bxor(d, bit32.band(b, bit32.bxor(c, d))), 0x5A827999
            elseif i <= 39 then f, k = bit32.bxor(b, c, d), 0x6ED9EBA1
            elseif i <= 59 then f, k = bit32.bor(bit32.band(b, bit32.bor(c, d)), bit32.band(c, d)), 0x8F1BBCDC
            else f, k = bit32.bxor(b, c, d), 0xCA62C1D6 end
            local temp = bit32.band(bit32.lrotate(a, 5) + f + e + k + w[i], 0xFFFFFFFF)
            e, d, c, b, a = d, c, bit32.lrotate(b, 30), a, temp
        end
        h0 = bit32.band(h0 + a, 0xFFFFFFFF)
        h1 = bit32.band(h1 + b, 0xFFFFFFFF)
        h2 = bit32.band(h2 + c, 0xFFFFFFFF)
        h3 = bit32.band(h3 + d, 0xFFFFFFFF)
        h4 = bit32.band(h4 + e, 0xFFFFFFFF)
    end
    return {h0, h1, h2, h3, h4}
end

-- Creates version 5 UUIDs from a parent UUID + node name
local function makeUUID(parentUUID, name)
    local hash = sha1(parentUUID:gsub("%X", ""):gsub("%x%x", function(s) return string.char(tonumber(s, 16)) end) .. name)
    local a, b, c, d = hash[1], bit32.bor(bit32.band(hash[2], 0xFFFF0FFF), 0x5000), bit32.bor(bit32.band(hash[3], 0x3FFFFFFF), 0x80000000), hash[4]
    return ("%08x-%04x-%04x-%04x-%04x%08x"):format(a, bit32.rshift(b, 16), bit32.band(b, 0xFFFF), bit32.rshift(c, 16), bit32.band(c, 0xFFFF), d)
end

local PHOENIX_ROOT_UUID = "a6f53b7d-50f3-4e51-adef-8728c83e3f3a"

deviceTreeRoot = {
    id = tostring(os.getComputerID()),
    uuid = makeUUID(PHOENIX_ROOT_UUID, tostring(os.getComputerID())),
    parent = nil,
    displayName = os.getComputerLabel() or "",
    drivers = {},
    metadata = {},      -- external static metadata table for driver use - this MUST NOT be modified after registration!
    internalState = {}, -- internal state table for driver use - this may change during use
                        -- drivers should make their own table inside!!!
    children = {},
    listeners = setmetatable({}, {__mode = "k"}),
}

local deviceUUIDs = {[deviceTreeRoot.uuid] = deviceTreeRoot}
local deviceListeners = {}

function hardware.get(path)
    expect(1, path, "string")
    if path:find("^%x+%-%x+%-%x+%-%x+%-%x+$") then return deviceUUIDs[path]
    elseif path:find("/") then
        -- Absolute path
        local node = deviceTreeRoot
        for name in path:gmatch "^/" do
            node = node.children[name]
            if node == nil then break end
        end
        return node
    else
        -- Search the entire tree for objects with the specified name (slow!)
        local matches = {}
        local function search(node)
            if node.id == path then matches[#matches+1] = node end
            for _, v in pairs(node.children) do search(v) end
        end
        search(deviceTreeRoot)
        return table.unpack(matches)
    end
end

function hardware.path(node)
    expect(1, node, "table")
    expect.field(node, "uuid", "string")
    if not deviceUUIDs[node.uuid] then error("bad argument #1 (invalid node)", 2) end
    local path = node.id
    node = node.parent
    while node do
        path = node.id .. "/" .. path
        node = node.parent
    end
    path = path:gsub("^[^/]+", "")
    return path == "" and "/" or path
end

function hardware.add(parent, name)
    expect(1, parent, "table")
    expect(2, name, "string")
    expect.field(parent, "uuid", "string")
    if not deviceUUIDs[parent.uuid] then return nil, "Invalid parent node" end
    if parent.children[name] then return nil, "Node already exists" end
    local node = {
        id = name,
        uuid = makeUUID(parent.uuid, name),
        parent = parent,
        displayName = "",
        drivers = {},
        metadata = {},
        internalState = {},
        children = {},
        listeners = setmetatable({}, {__mode = "k"}),
    }
    parent.children[name] = node
    deviceUUIDs[node.uuid] = node
    syslog.log({module = "Hardware"}, "Added new device at " .. hardware.path(node))
    for _, v in ipairs(deviceListeners) do
        if (not v.parent or v.parent == parent) and (not v.pattern or name:match(v.pattern)) then
            v.callback(node)
        end
    end
    return node
end

function hardware.remove(node)
    expect(1, node, "table")
    expect.field(node, "uuid", "string")
    if not deviceUUIDs[node.uuid] then return false, "Invalid node" end
    if node == deviceTreeRoot or not node.parent then return false, "Cannot remove root node" end
    for i = #node.drivers, 1, -1 do hardware.deregister(node, node.drivers[i]) end
    -- By this point all children devices should be gone (right?)
    syslog.log({module = "Hardware"}, "Device at " .. hardware.path(node) .. " has been removed")
    node.parent.children[node.id] = nil
    deviceUUIDs[node.uuid] = nil
    node.parent = nil
    return true
end

function hardware.register(node, driver)
    expect(1, node, "table")
    expect(2, driver, "table")
    expect.field(node, "uuid", "string")
    expect.field(driver, "name", "string")
    expect.field(driver, "type", "string")
    expect.field(driver, "properties", "table")
    expect.field(driver, "methods", "table")
    expect.field(driver, "init", "function", "nil")
    expect.field(driver, "deinit", "function", "nil")
    for k in pairs(driver.methods) do
        if type(k) ~= "string" then error("bad method name '" .. tostring(k) .. "' (not a string)", 2) end
        expect.field(driver.methods, k, "function")
    end
    for _, v in ipairs(driver.properties) do
        if type(v) ~= "string" then error("bad property name '" .. tostring(v) .. "' (not a string)", 2) end
        if not driver.methods["get" .. v:sub(1, 1):upper() .. v:sub(2)] then error("bad property '" .. v .. "' (no getter present)", 2) end
    end
    if not deviceUUIDs[node.uuid] then error("bad argument #1 (invalid node)", 2) end
    for _, v in ipairs(node.drivers) do if v == driver then return false end end
    -- TODO: check for method collisions
    node.drivers[#node.drivers+1] = driver
    syslog.log({module = "Hardware"}, "Registered device with type " .. driver.type .. " on device " .. hardware.path(node) .. " using driver " .. driver.name)
    if driver.init then driver.init(node) end
    return true
end

function hardware.register_callback(driver)
    return function(node) return hardware.register(node, driver) end
end

function hardware.deregister(node, driver)
    expect(1, node, "table")
    expect(2, driver, "table")
    expect.field(node, "uuid", "string")
    if not deviceUUIDs[node.uuid] then error("bad argument #1 (invalid node)", 2) end
    for i, v in ipairs(node.drivers) do if v == driver then
        if driver.deinit then driver.deinit(node) end
        table.remove(node.drivers, i)
        syslog.log({module = "Hardware"}, "Driver " .. driver.name .. " has been deregistered from device " .. hardware.path(node))
        return true
    end end
    return false
end

function hardware.listen(callback, parent, pattern)
    expect(1, callback, "function")
    expect(2, parent, "table", "nil")
    expect(3, pattern, "string", "nil")
    if parent then expect.field(parent, "uuid", "string") end
    if pattern and not pcall(string.match, "", pattern) then error("bad argument #3 (invalid pattern)", 2) end
    deviceListeners[#deviceListeners+1] = {callback = callback, parent = parent, pattern = pattern}
end

function hardware.unlisten(callback)
    expect(1, callback, "function")
    local i = 1
    while i < #deviceListeners do
        if deviceListeners[i].callback == callback then table.remove(deviceListeners, i)
        else i = i + 1 end
    end
end

function hardware.broadcast(node, event, param)
    expect(1, node, "table")
    expect(2, event, "table")
    expect.field(node, "uuid", "string")
    if not deviceUUIDs[node.uuid] then error("bad argument #1 (invalid node)", 2) end
    for v in pairs(node.listeners) do v.eventQueue[#v.eventQueue+1] = {event, param} end
end

-- Syscalls

function syscalls.devlookup(process, thread, name)
    expect(1, name, "string")
    local dev = {hardware.get(name)}
    for k, v in ipairs(dev) do dev[k] = hardware.path(v) end
    return dev
end

function syscalls.devinfo(process, thread, device)
    expect(1, device, "string")
    local node = hardware.get(device)
    if not node then return nil end
    local types = {}
    for _, v in ipairs(node.drivers) do types[v.type] = v.name end
    return {
        id = node.id,
        uuid = node.uuid,
        parent = hardware.path(node.parent),
        displayName = node.displayName,
        types = types,
        metadata = deepcopy(node.metadata)
    }
end

function syscalls.devmethods(process, thread, device)
    expect(1, device, "string")
    local node = hardware.get(device)
    if not node then error("No such device", 2) end
    local methods = {}
    for _, v in ipairs(node.drivers) do for k in pairs(v.methods) do methods[#methods+1] = k end end
    return methods
end

function syscalls.devproperties(process, thread, device)
    expect(1, device, "string")
    local node = hardware.get(device)
    if not node then error("No such device", 2) end
    local properties = {}
    for _, v in ipairs(node.drivers) do for _, k in pairs(v.properties) do properties[#properties+1] = k end end
    return properties
end

function syscalls.devchildren(process, thread, device)
    expect(1, device, "string")
    local node = hardware.get(device)
    if not node then error("No such device", 2) end
    local children = {}
    for k in pairs(node.children) do children[#children+1] = k end
    return children
end

function syscalls.devcall(process, thread, device, method, ...)
    expect(1, device, "string")
    expect(2, method, "string")
    local node = hardware.get(device)
    if not node then error("No such device", 2) end
    if node.process and node.process ~= process.id then error("Device is locked", 2) end
    for _, driver in ipairs(node.drivers) do if driver.methods[method] then return driver.methods[method](node, process, ...) end end
    error("No such method", 2)
end

function syscalls.devlisten(process, thread, device, state)
    expect(1, device, "string")
    expect(2, state, "boolean", "nil")
    if state == nil then state = true end
    local node = hardware.get(device)
    if not node then error("No such device", 2) end
    if state then
        for _, v in ipairs(node.listeners) do if v == process then return end end
        node.listeners[process] = true
        process.dependents[#process.dependents+1] = {type = "hardware listen", node = node, gc = function() node.listeners[process] = nil end}
    else
        node.listeners[process] = nil
        for i, v in ipairs(process.dependents) do if v.type == "hardware listen" and v.node == node then table.remove(process.dependents, i) break end end
    end
end

function syscalls.devlock(process, thread, device, wait)
    expect(1, device, "string")
    expect(2, wait, "boolean", "nil")
    if wait == nil then wait = true end
    local node = hardware.get(device)
    if not node then error("No such device", 2) end
    if node.process == nil then
        node.process = process.id
        process.dependents[#process.dependents+1] = {type = "hardware lock", node = node, gc = function() node.process = nil end}
        return true
    elseif node.process == process.id then
        return true
    elseif wait then
        thread.filter = function(process, thread)
            return node.process == nil or node.process == process.id
        end
        return kSyscallYield, "devlock", device, true
    else return false end
end

function syscalls.devunlock(process, thread, device)
    expect(1, device, "string")
    local node = hardware.get(device)
    if not node then error("No such device", 2) end
    if node.process and node.process ~= process.id then error("Device is locked", 2) end
    node.process = nil
    for i, v in ipairs(process.dependents) do if v.type == "hardware lock" and v.node == node then table.remove(process.dependents, i) break end end
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