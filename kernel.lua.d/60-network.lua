local nextHandleID = 0
local httpRequests = {}
local modemOpenCount = {}
local rednetOpenCount = {}
local rednetHandles = {}
local rednetChannel = os.computerID() % 65500
local receivedRednetMessages = {}

-- TODO: fix user:password@domain URIs (uncommon but part of spec)
local function parseURI(uri)
    local info = {scheme = ""}
    for c in uri:match "." do
        if info.fragment then
            if c:match "[%w%-%._~%%@:/!%$&'%(%)%*%+,;=/?]" then info.fragment = info.fragment .. c
            else error("Invalid URI", 3) end
        elseif info.query then
            if c == "#" then info.fragment = ""
            elseif c:match "[%w%-%._~%%@:/!%$&'%(%)%*%+,;=/?]" then info.query = info.query .. c
            else error("Invalid URI", 3) end
        elseif info.path then
            if c == "/" and info.path == "/" and not info.host then info.path, info.host = nil, ""
            elseif c == "?" then info.query = ""
            elseif c == "#" then info.fragment = ""
            elseif c:match "[%w%-%._~%%@:/!%$&'%(%)%*%+,;=/]" then info.path = info.path .. c
            else error("Invalid URI", 3) end
        elseif info.port then
            if tonumber(c) then info.port = info.port .. c
            elseif c == "/" then info.path = "/"
            else error("Invalid URI", 3) end
        elseif info.host then
            if c == "@" and not info.user then info.user, info.host = info.host, ""
            elseif c == ":" then info.port = ""
            elseif c == "/" then info.path = "/"
            elseif c:match "[%w%-%._~%%/!%$&'%(%)%*%+,;=]" then info.host = info.host .. c
            else error("Invalid URI", 3) end
        else
            if c == ":" then info.path = ""
            elseif c:match(info.scheme == "" and "[%a%+%-%.]" or "[%w%+%-%.]") then info.scheme = info.scheme .. c
            else error("Invalid URI", 3) end
        end
    end
    return info
end

eventHooks.http_success = eventHooks.http_success or {}
eventHooks.http_success[#eventHooks.http_success+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.handle, info.status = ev[3], "open"
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = "open"}}
        httpRequests[ev[2]] = nil
    else syslog.log({level = "notice"}, "Received HTTP response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.http_failure = eventHooks.http_failure or {}
eventHooks.http_failure[#eventHooks.http_failure+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        if ev[4] then info.handle, info.status = ev[3], "open"
        else info.status, info.error = "error", ev[3] end
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = info.status}}
        httpRequests[ev[2]] = nil
    else syslog.log({level = "notice"}, "Received HTTP response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_success = eventHooks.websocket_success or {}
eventHooks.websocket_success[#eventHooks.websocket_success+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.handle, info.status = ev[3], "open"
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = "open"}}
    else syslog.log({level = "notice"}, "Received WebSocket response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_failure = eventHooks.websocket_failure or {}
eventHooks.websocket_failure[#eventHooks.websocket_failure+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.status, info.error = "error", ev[3]
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = info.status}}
    else syslog.log({level = "notice"}, "Received WebSocket response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_message = eventHooks.websocket_message or {}
eventHooks.websocket_message[#eventHooks.websocket_message+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        -- TODO: decide whether to transcode if the requested encoding doesn't match the message
        info.buffer = info.buffer .. ev[3]
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_data_ready", {id = info.id}}
    else syslog.log({level = "notice"}, "Received WebSocket response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_closed = eventHooks.websocket_closed or {}
eventHooks.websocket_closed[#eventHooks.websocket_closed+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.status = "closed"
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = info.status}}
        httpRequests[ev[2]] = nil
    else syslog.log({level = "notice"}, "Received WebSocket message for " .. ev[2] .. " but it's not open; ignoring.") end
end

eventHooks.modem_message = eventHooks.modem_message or {}
eventHooks.modem_message[#eventHooks.modem_message+1] = function(ev)
    if rednetOpenCount[ev[2]] and (ev[3] == rednetChannel or ev[3] == 65535) and
       type(ev[5]) == "table" and type(ev[5].nMessageID) == "number" and
       ev[5].nMessageID == ev[5].nMessageID and not receivedRednetMessages[ev[5].nMessageID] and
       ((ev[5].nRecipient and ev[5].nRecipient == os.computerID()) or ev[3] == 65535) then
        if rednetHandles[ev[5].nSender] then
            for _, v in ipairs(rednetHandles[ev[5].nSender]) do
                if not v.protocol or v.protocol == ev[5].sProtocol then
                    v.buffer[#v.buffer+1] = deepcopy(ev[5].message)
                    receivedRednetMessages[ev[5].nMessageID] = os.clock() + 9.5
                    v.process.eventQueue[#v.process.eventQueue+1] = {"handle_data_ready", {id = v.id}}
                end
            end
        end
        if rednetHandles[0xFFFFFFFF] then
            for _, v in ipairs(rednetHandles[0xFFFFFFFF]) do
                if not v.protocol or v.protocol == ev[5].sProtocol then
                    v.buffer[#v.buffer+1] = deepcopy(ev[5].message)
                    receivedRednetMessages[ev[5].nMessageID] = os.clock() + 9.5
                    v.process.eventQueue[#v.process.eventQueue+1] = {"handle_data_ready", {id = v.id}}
                end
            end
        end
        for k, v in pairs(receivedRednetMessages) do if v < os.clock() then receivedRednetMessages[k] = nil end end
    end
end

-- TODO: Fix handle:read() not being equivalent to handle:read("*l")

local function httpHandler(process, options)
    expect.field(options, "encoding", "string", "nil")
    expect.field(options, "headers", "table", "nil")
    expect.field(options, "method", "string", "nil")
    expect.field(options, "redirect", "boolean", "nil")
    local info = {status = "ready", process = process, id = nextHandleID}
    local obj = {id = nextHandleID}
    nextHandleID = nextHandleID + 1
    function obj:status()
        return info.status, info.error
    end
    function obj:read(mode, ...)
        if info.status ~= "open" then error("attempt to read from a " .. info.status .. " handle", 2) end
        if mode == nil then return end
        if type(mode) ~= "string" and type(mode) ~= "number" then error("bad argument (expected string or number, got " .. type(mode) .. ")", 2) end
        mode = mode:gsub("^%*", "")
        if mode == "a" then return info.handle.readAll(), self:read(...)
        elseif mode == "l" then return info.handle.readLine(false), self:read(...)
        elseif mode == "L" then return info.handle.readLine(true), self:read(...)
        elseif mode == "n" then
            local str
            repeat
                str = info.handle.read(1)
                if not str then return nil end
            until tonumber(str)
            while true do
                local c = info.handle.read(1)
                if not c or not c:match "%d" then break end
                str = str .. c
            end
            return tonumber(str), self:read(...)
        elseif type(mode) == "number" then return info.handle.read(mode), self:read(...)
        else error("bad argument (invalid mode '" .. mode .. "')", 2) end
    end
    function obj:write(...)
        if info.status ~= "ready" then error("attempt to write to a " .. info.status .. " handle", 2) end
        local data
        if select("#", ...) > 0 then
            data = ""
            for _, v in ipairs{...} do data = data .. tostring(v) end
        end
        local url = options.url .. "#" .. info.id
        local ok, err = http.request{url = url, body = data, headers = options.headers, binary = options.encoding == "binary", method = options.method, redirect = options.redirect}
        if ok then
            httpRequests[url] = info
            info.status = "connecting"
        else info.status, info.error = "error", err end
    end
    function obj:close()
        if info.status ~= "open" then error("attempt to close a " .. info.status .. " handle", 2) end
        info.handle.close()
        info.status = "closed"
    end
    function obj:responseHeaders()
        if info.status ~= "open" then error("attempt to read from a " .. info.status .. " handle", 2) end
        return info.handle.getResponseHeaders()
    end
    function obj:responseCode()
        if info.status ~= "open" then error("attempt to read from a " .. info.status .. " handle", 2) end
        return info.handle.getResponseCode()
    end
    return obj
end

local function wsHandler(process, options)
    expect.field(options, "encoding", "string", "nil")
    expect.field(options, "headers", "table", "nil")
    local info = {process = process, id = nextHandleID, buffer = ""}
    local obj = {id = nextHandleID}
    nextHandleID = nextHandleID + 1
    function obj:status()
        return info.status, info.error
    end
    function obj:read(mode, ...)
        if info.status ~= "open" then error("attempt to read from a " .. info.status .. " handle", 2) end
        if mode == nil then return end
        if type(mode) ~= "string" and type(mode) ~= "number" then error("bad argument (expected string or number, got " .. type(mode) .. ")", 2) end
        if info.buffer == "" then return nil end
        mode = mode:gsub("^%*", "")
        if mode == "a" then
            local str = info.buffer
            info.buffer = ""
            return str
        elseif mode == "l" then
            local str, pos = info.buffer:match "^([^\n]*)\n?()"
            if str then
                info.buffer = info.buffer:sub(pos)
                return str, self:read(...)
            else return nil end
        elseif mode == "L" then
            local str, pos = info.buffer:match "^([^\n]*\n?)()"
            if str then
                info.buffer = info.buffer:sub(pos)
                return str, self:read(...)
            else return nil end
        elseif mode == "n" then
            local str, pos = info.buffer:match "(%d+)()"
            if str then
                info.buffer = info.buffer:sub(pos)
                return tonumber(str), self:read(...)
            else return nil end
        elseif type(mode) == "number" then
            local str = info.buffer:sub(1, mode)
            info.buffer = info.buffer:sub(mode + 1)
            return str, self:read(...)
        else error("bad argument (invalid mode '" .. mode .. "')", 2) end
    end
    function obj:write(data, ...)
        if info.status ~= "open" then error("attempt to write to a " .. info.status .. " handle", 2) end
        info.handle.send(tostring(data), options.encoding == "binary")
        if select("#", ...) > 0 then return self:write(...) end
    end
    function obj:close()
        if info.status ~= "open" then error("attempt to close a " .. info.status .. " handle", 2) end
        info.handle.close()
        info.status = "closed"
    end
    local url = options.url .. "#" .. info.id
    local ok, err = http.websocket(url, options.headers)
    if ok then
        httpRequests[url] = info
        info.status = "connecting"
    else return nil, err end
    return obj
end

-- TODO: consider adding hostname lookup
local function rednetHandler(process, options)
    expect.field(options, "device", "string", "nil")
    local modems
    if options.device then modems = {hardware.get(options.device)}
    else modems = {hardware.find("modem")} end
    if #modems == 0 then error("Could not find a modem", 2) end
    for _, v in ipairs(modems) do
        if not rednetOpenCount[v] then
            hardware.call(process, v, "open", rednetChannel)
            hardware.call(process, v, "open", 65535)
            rednetOpenCount[v] = 1
        else rednetOpenCount[v] = rednetOpenCount[v] + 1 end
    end
    local uri = parseURI(options.url)
    if not uri.host then error("Missing host", 2) end
    local id
    if uri.host:match "^%d+$" then id = tonumber(uri.host)
    elseif uri.host:match "^%d+%.%d+$" then id = tonumber(uri.host:match "^%d+") * 0x1000000 + tonumber(uri.host:match "^%d+%.(%d+)")
    elseif uri.host:match "^%d+%.%d+%.%d+$" then id = tonumber(uri.host:match "^(%d+)") * 0x1000000 + tonumber(uri.host:match "^%d+%.(%d+)") * 0x10000 + tonumber(uri.host:match "^%d+%.%d+%.(%d+)")
    elseif uri.host:match "^%d+%.%d+%.%d+%.%d+$" then id = tonumber(uri.host:match "^(%d+)") * 0x1000000 + tonumber(uri.host:match "^%d+%.(%d+)") * 0x10000 + tonumber(uri.host:match "^%d+%.%d+%.(%d+)") * 0x100 + tonumber(uri.host:match "^%d+%.%d+%.%d+%.(%d+)")
    else error("Invalid IP address", 2) end
    local info = {process = process, id = nextHandleID, buffer = {}, protocol = uri.scheme:match "rednet%+(.+)"}
    local obj = {id = nextHandleID}
    nextHandleID = nextHandleID + 1
    function obj:status()
        return info.closed and "closed" or "open"
    end
    function obj:read(mode, ...)
        if info.closed then error("attempt to read from a " .. info.status .. " handle", 2) end
        if mode == nil then return end
        if type(mode) ~= "string" and type(mode) ~= "number" then error("bad argument (expected string or number, got " .. type(mode) .. ")", 2) end
        if #info.buffer == 0 then return nil end
        mode = mode:gsub("^%*", "")
        if mode == "a" then
            return table.remove(info.buffer, 1)
        elseif mode == "l" then
            info.buffer[1] = tostring(info.buffer[1])
            local str, pos = info.buffer[1]:match "^([^\n]*)\n?()"
            if str then
                info.buffer[1] = info.buffer[1]:sub(pos)
                return str, self:read(...)
            else
                table.remove(info.buffer, 1)
                return self:read(mode, ...)
            end
        elseif mode == "L" then
            info.buffer[1] = tostring(info.buffer[1])
            local str, pos = info.buffer[1]:match "^([^\n]*\n?)()"
            if str then
                info.buffer[1] = info.buffer[1]:sub(pos)
                return str, self:read(...)
            else
                table.remove(info.buffer, 1)
                return self:read(mode, ...)
            end
        elseif mode == "n" then
            info.buffer[1] = tostring(info.buffer[1])
            local str, pos = info.buffer[1]:match "(%d+)()"
            if str then
                info.buffer[1] = info.buffer[1]:sub(pos)
                return tonumber(str), self:read(...)
            else
                table.remove(info.buffer, 1)
                return self:read(mode, ...)
            end
        elseif type(mode) == "number" then
            local str = ""
            while #str < mode do
                info.buffer[1] = tostring(info.buffer[1])
                str = str .. info.buffer[1]:sub(1, mode - #str)
                info.buffer[1] = info.buffer[1]:sub(mode - #str + 1)
                if info.buffer[1] == "" then table.remove(info.buffer, 1) end
                if #info.buffer == 0 then break end
            end
            return str, self:read(...)
        else error("bad argument (invalid mode '" .. mode .. "')", 2) end
    end
    function obj:write(data, ...)
        if info.closed then error("attempt to write to a " .. info.status .. " handle", 2) end
        local msgid = math.random(1, 0x7FFFFFFF)
        local msg = {
            nMessageID = msgid,
            nRecipient = id,
            nSender = os.computerID(),
            message = data,
            sProtocol = info.protocol
        }
        if id == os.computerID() then
            for _, v in ipairs(modems) do
                os.queueEvent("modem_message", v.id, rednetChannel, rednetChannel, msg, 0)
            end
        else
            receivedRednetMessages[msgid] = os.clock() + 9.5
            for _, v in ipairs(modems) do
                hardware.call(process, v, "transmit", id % 65500, rednetChannel, msg)
                hardware.call(process, v, "transmit", 65533, rednetChannel, msg)
            end
        end
        if select("#", ...) > 0 then return self:write(...) end
    end
    function obj:close()
        if info.closed then error("attempt to close a " .. info.status .. " handle", 2) end
        for _, v in ipairs(modems) do
            rednetOpenCount[v] = rednetOpenCount[v] - 1
            if rednetOpenCount[v] == 0 then
                hardware.call(process, v, "close", rednetChannel)
                hardware.call(process, v, "close", 65535)
                rednetOpenCount[v] = nil
            end
        end
        info.status = "closed"
    end
    return obj
end

local function pspHandler(process, options)

end

--- Stores all URI scheme handlers using Lua patterns as keys.
uriSchemes = {
    ["https?"] = httpHandler,
    ["wss?"] = wsHandler,
    ["rednet"] = rednetHandler,
    ["rednet%+%a+"] = rednetHandler,
    ["psp"] = pspHandler
}

function syscalls.connect(process, thread, options)
    -- TODO: set the environment & protect all functions
end

function syscalls.listen(process, thread, uri)

end

function syscalls.unlisten(process, thread, uri)

end

function syscalls.ipconfig(process, thread, device, info)

end

function syscalls.routelist(process, thread, num)

end

function syscalls.routeadd(process, thread, options)

end

function syscalls.routedel(process, thread, source, num)

end

function syscalls.arplist(process, thread, device)

end

function syscalls.arpadd(process, thread, device, ip, id)

end

function syscalls.arpdel(process, thread, device, ip)

end

function syscalls.netcontrol(process, thread, ip, type, err)

end

function syscalls.netevent(process, thread, state)

end

function syscalls.checkuri(process, thread, uri)

end