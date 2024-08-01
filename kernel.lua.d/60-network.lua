-- TODO: fix user:password@domain URIs (uncommon but part of spec)
local function parseURI(uri)
    local info = {scheme = ""}
    for c in uri:gmatch "." do
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
    if info.port then info.port = tonumber(info.port) end
    return info
end

local function ipToNumber(ip)
    if ip:match "^%d+$" then return tonumber(ip)
    elseif ip:match "^%d+%.%d+$" then return tonumber(ip:match "^%d+") * 0x1000000 + tonumber(ip:match "^%d+%.(%d+)")
    elseif ip:match "^%d+%.%d+%.%d+$" then return tonumber(ip:match "^(%d+)") * 0x1000000 + tonumber(ip:match "^%d+%.(%d+)") * 0x10000 + tonumber(ip:match "^%d+%.%d+%.(%d+)")
    elseif ip:match "^%d+%.%d+%.%d+%.%d+$" then return tonumber(ip:match "^(%d+)") * 0x1000000 + tonumber(ip:match "^%d+%.(%d+)") * 0x10000 + tonumber(ip:match "^%d+%.%d+%.(%d+)") * 0x100 + tonumber(ip:match "^%d+%.%d+%.%d+%.(%d+)")
    else error("Invalid IP address", 2) end
end

local function numberToIP(num)
    if not num then return nil end
    return ("%d.%d.%d.%d"):format(bit32.band(bit32.rshift(num, 24), 0xFF), bit32.band(bit32.rshift(num, 16), 0xFF), bit32.band(bit32.rshift(num, 8), 0xFF), bit32.band(num, 0xFF))
end

local function randomString(len)
    local s = ""
    for i = 1, len do s = s .. string.char(math.random(0, 255)) end
    return s
end

local function prefixToMask(num) return bit32.bnot(2^(32-num)-1) end

local function maskToPrefix(mask)
    local n = 0
    while bit32.btest(mask, 0x80000000) do mask, n = bit32.lshift(mask, 1), n + 1 end
    return n
end

local function checkModem(node)
    if not node then error("No such device") end
    for _, v in pairs(node.drivers) do if v.type == "modem" then return node end end
    error("Not a modem")
end

local nextHandleID = 0

--#region Network stack implementation

local ipconfig = {}
local routes = {maxn = 0, [0] = {}}
local arptable = {}
local protocols = {send = {}, recv = {}}
local openSockets = {}
local openSocketIDs = {}
local networkListeners = setmetatable({}, {__mode = "k"})
local waiting = {arp = {}, socket = {}}
local usedMessageIDs = {}

--[[
    socket object:
    * ip: IP address of the remote host
    * port: Port of the remote host
    * localPort: Receive port on the local host
    * id: ID of the socket/handle
    * sendSeq: last sequence acknowledged by peer [SND.UNA]
    * sendSeqNext: next sender sequence to peer [SND.NXT]
    * sendSeqMax: maximum sequence to peer (for window) [SND.WND]
      - on close, this is set to the sequence for the FIN message
    * recvSeq: next expected received sequence from peer [RCV.NXT]
    * recvSeqMax: maximum sequence from peer (for window) [RCV.WND]
    * status: status of socket (listening, syn-sent, syn-received, connected, fin-wait, closing, close-wait [LAST-ACK], time-wait, closed)
    * nextUpdate: time that the next update can be triggered
    * process?: process that opened the socket
    * retryCount: number of retries in the current state
    * error?: an error status if something went wrong
    * outQueue: list of messages that were sent but not ACKed
    * nextAck?: whether the next timer should be for sending an ACK
    * buffer: data queue for the socket (string)
]]

-- TODO: Make a final decision on whether to use channels for PSP ports.
-- There's a limit on open channels, so that would arbitrarily limit
-- the number of sockets that could be open at once, much below the
-- port exhaustion limit. However, putting everything on the same
-- channel may cause too much chatter on the channel.

function protocols.send.link(info, destination, message)
    expect(2, destination, "number", "nil")
    expect.field(info, "device", "table")
    local obj = {
        PhoenixNetworking = true,
        type = "link",
        source = os.computerID(),
        destination = destination,
        payload = message
    }
    if destination == os.computerID() then os.queueEvent("modem_message", info.device.id, info.outPort or 0, info.inPort or 0, obj, 0)
    else hardware.call(info.process or KERNEL, info.device, "transmit", info.outPort or 0, info.inPort or 0, obj) end
end

function protocols.send.arp_request(info, ip)
    expect.field(info, "device", "table")
    expect(2, ip, "string")
    hardware.call(info.process or KERNEL, info.device, "transmit", 0, 0, {
        PhoenixNetworking = true,
        type = "arp",
        reply = false,
        source = os.computerID(),
        sourceIP = ipconfig[info.device.uuid] and numberToIP(ipconfig[info.device.uuid].ip),
        destinationIP = ip
    })
end

function protocols.send.arp_reply(info, destination, destIP)
    expect.field(info, "device", "table")
    expect(2, destination, "number")
    expect(3, destIP, "string", "nil")
    hardware.call(info.process or KERNEL, info.device, "transmit", 0, 0, {
        PhoenixNetworking = true,
        type = "arp",
        reply = true,
        source = os.computerID(),
        sourceIP = numberToIP(ipconfig[info.device.uuid].ip),
        destination = destination,
        destinationIP = destIP
    })
end

function protocols.send.internet(info, destination, message)
    expect(2, destination, "number")
    local msg = {PhoenixNetworking = true, type = "internet", hopsLeft = 15, payload = message, destination = numberToIP(destination)}
    local id = randomString(32)
    msg.messageID = id
    --usedMessageIDs[id] = os.epoch "utc"
    local v
    for i = routes.maxn, 0, -1 do if routes[i] then
        for _, rt in ipairs(routes[i]) do
            if bit32.band(rt.source, rt.sourceNetmask) == bit32.band(destination, rt.sourceNetmask) and
               (not v or maskToPrefix(rt.sourceNetmask) > maskToPrefix(v.sourceNetmask)) then v = rt end
        end
    end end
    if not v then return protocols.recv.control({}, {
        PhoenixNetworking = true,
        messageType = "unreachable",
        error = "No route to host",
        payload = msg
    }) end
    if v.action == "unicast" and ipconfig[v.device.uuid] and ipconfig[v.device.uuid].up then
        info.device = v.device
        msg.source = numberToIP(ipconfig[v.device.uuid].ip)
        if arptable[v.device.uuid] and arptable[v.device.uuid][v.destination] then return protocols.send.link(info, arptable[v.device.uuid][v.destination], msg) end
        local sent = false
        local timer
        local function arp_reply(_, ip, dest)
            if not sent and ipToNumber(ip) == v.destination then
                sent = true
                protocols.send.link(info, dest, msg)
            end
            if sent then for i, f in ipairs(waiting.arp) do if f == arp_reply then table.remove(waiting.arp, i) break end end end
        end
        local function timer_func(ev)
            if ev[2] == timer then
                if not sent then protocols.recv.control({}, {
                    PhoenixNetworking = true,
                    messageType = "unreachable",
                    error = "No route to host",
                    payload = msg
                }) end
                sent = true
                for i, v in ipairs(eventHooks.timer) do if v == timer_func then table.remove(eventHooks.timer, i) break end end
                for i, f in ipairs(waiting.arp) do if f == arp_reply then table.remove(waiting.arp, i) break end end
            end
        end
        waiting.arp[#waiting.arp+1] = arp_reply
        protocols.send.arp_request(info, numberToIP(v.destination))
        eventHooks.timer = eventHooks.timer or {}
        eventHooks.timer[#eventHooks.timer+1] = timer_func
        timer = os.startTimer(2)
        return
    elseif v.action == "broadcast" and ipconfig[v.device.uuid] and ipconfig[v.device.uuid].up then
        info.device = v.device
        msg.source = numberToIP(ipconfig[v.device.uuid].ip)
        return protocols.send.link(info, nil, msg)
    elseif v.action == "local" and ipconfig[v.device.uuid] and ipconfig[v.device.uuid].up then
        info.device = v.device
        msg.source = numberToIP(ipconfig[v.device.uuid].ip)
        if arptable[v.device.uuid] and arptable[v.device.uuid][destination] then return protocols.send.link(info, arptable[v.device.uuid][destination], msg) end
        local sent = false
        local timer
        local function arp_reply(_, ip, dest)
            if not sent and ipToNumber(ip) == destination then
                sent = true
                protocols.send.link(info, dest, msg)
            end
            if sent then for i, f in ipairs(waiting.arp) do if f == arp_reply then table.remove(waiting.arp, i) break end end end
        end
        local function timer_func(ev)
            if ev[2] == timer then
                if not sent then protocols.recv.control({}, {
                    PhoenixNetworking = true,
                    messageType = "unreachable",
                    error = "No route to host",
                    payload = msg
                }) end
                sent = true
                for i, v in ipairs(eventHooks.timer) do if v == timer_func then table.remove(eventHooks.timer, i) break end end
            end
        end
        waiting.arp[#waiting.arp+1] = arp_reply
        protocols.send.arp_request(info, numberToIP(destination))
        eventHooks.timer = eventHooks.timer or {}
        eventHooks.timer[#eventHooks.timer+1] = timer_func
        timer = os.startTimer(2)
        return
    elseif v.action == "unreachable" then
        return protocols.recv.control({}, {
            PhoenixNetworking = true,
            messageType = "unreachable",
            error = "Destination unreachable",
            payload = msg
        })
    elseif v.action == "prohibit" then
        return protocols.recv.control({}, {
            PhoenixNetworking = true,
            messageType = "unreachable",
            error = "Prohibited",
            payload = msg
        })
    elseif v.action == "blackhole" then
        return
    end
end

function protocols.send.control(info, destination, type, err, packet)
    expect(3, type, "string")
    expect(4, err, "string", "nil")
    return protocols.send.internet(info, destination, {
        PhoenixNetworking = true,
        type = "control",
        messageType = type,
        error = err,
        payload = packet
    })
end

protocols.send.socket = {}

function protocols.send.socket.connect(info, ip, port, socket)
    for i = 1, 16384 do
        local p = math.random(49152, 65535)
        if not openSockets[p] or not openSockets[p][port] then socket.localPort = p break end
    end
    if not socket.localPort then error("Too many open sockets") end
    socket.id = nextHandleID
    nextHandleID = nextHandleID + 1
    socket.ip = ip
    socket.port = port
    socket.sendSeq = math.floor(math.random()*0x10000000000)
    socket.sendSeqNext = socket.sendSeq + 2
    socket.sendSeqMax = socket.sendSeq + 256
    info.outPort = port
    info.inPort = socket.localPort
    networkListeners[socket] = function(p)
        if p.type == "control" and p.payload.destination == numberToIP(ip) then
            socket.status = "error"
            socket.error = p.error
            return true
        end
        return false
    end
    protocols.send.internet(info, ip, {
        PhoenixNetworking = true,
        type = "socket",
        sequence = socket.sendSeqNext - 1,
        windowSize = 256,
        synchronize = true
    })
    local ok, err = pcall(hardware.call, info.process or KERNEL, info.device, "open", socket.localPort)
    if not ok then
        protocols.send.internet(info, ip, {
            PhoenixNetworking = true,
            type = "socket",
            sequence = socket.sendSeqNext,
            windowSize = 0,
            reset = true
        })
        socket.status = "error"
        socket.error = err
        return false
    end
    socket.status = "syn-sent"
    socket.nextUpdate = os.epoch "utc" + 5000
    socket.process = info.process
    socket.retryCount = 0
    openSockets[socket.localPort] = openSockets[socket.localPort] or {}
    openSockets[socket.localPort][port] = socket
    openSocketIDs[socket.id] = socket
end

function protocols.send.socket.data(info, message, socket)
    info.outPort = socket.port
    info.inPort = socket.localPort
    message.PhoenixNetworking = true
    message.type = "socket"
    if not message.sequence then
        message.sequence = socket.sendSeqNext
        socket.sendSeqNext = socket.sendSeqNext + 1
    end
    message.acknowledgement = message.acknowledgement or (socket.recvSeq - 1)
    socket.nextAck = nil
    if not message.final then message.windowSize = 256 end -- TODO: adjustable?
    return protocols.send.internet(info, socket.ip, message)
end

function protocols.send.socket.ack(info, num, socket)
    return protocols.send.socket.data(info, {acknowledgement = num}, socket)
end

function protocols.send.socket.reset(info, ip, port, seq, ack, inPort)
    info.outPort = port
    info.inPort = inPort or port
    return protocols.send.internet(info, ip, {
        PhoenixNetworking = true,
        type = "socket",
        sequence = seq,
        acknowledgement = ack,
        reset = true
    })
end

local function socket_read(socket, mode, ...)
    mode = mode or "*l"
    if type(mode) ~= "string" and type(mode) ~= "number" then error("bad argument (expected string or number, got " .. type(mode) .. ")", 2) end
    if socket.buffer == "" then return nil end
    mode = mode:gsub("^%*", "")
    if mode == "a" then
        local str = socket.buffer
        socket.buffer = ""
        return str
    elseif mode == "l" then
        local str, pos = socket.buffer:match "^([^\n]*)\n?()"
        if str then
            socket.buffer = socket.buffer:sub(pos)
            if select("#", ...) > 0 then return str, socket_read(socket, ...)
            else return str end
        else return nil end
    elseif mode == "L" then
        local str, pos = socket.buffer:match "^([^\n]*\n?)()"
        if str then
            socket.buffer = socket.buffer:sub(pos)
            if select("#", ...) > 0 then return str, socket_read(socket, ...)
            else return str end
        else return nil end
    elseif mode == "n" then
        local str, pos = socket.buffer:match "(%d+)()"
        if str then
            socket.buffer = socket.buffer:sub(pos)
            if select("#", ...) > 0 then return tonumber(str), socket_read(socket, ...)
            else return tonumber(str) end
        else return nil end
    elseif type(mode) == "number" then
        local str = socket.buffer:sub(1, mode)
        socket.buffer = socket.buffer:sub(mode + 1)
        if select("#", ...) > 0 then return str, socket_read(socket, ...)
        else return str end
    else error("bad argument (invalid mode '" .. mode .. "')", 2) end
end

local function socket_write(socket, data, ...)
    data = tostring(data)
    socket.outQueue[socket.sendSeqNext] = data
    protocols.send.socket.data({}, {payload = data}, socket)
    if select("#", ...) > 0 then return socket_write(socket, ...) end
end

function syscalls.__socketcall(process, thread, id, method, ...)
    local socket = openSocketIDs[id]
    if not socket then error("No such socket") end
    local realProcess = process
    while process ~= socket.process do
        if process == nil then error("No such socket") end
        process = processes[process.parent or -1]
    end
    if method == "close" then
        socket.sendSeqMax = socket.sendSeqNext
        protocols.send.socket.data({}, {final = true}, socket)
        socket.status = "fin-wait"
    elseif method == "read" then return socket_read(socket, ...)
    elseif method == "write" then return socket_write(socket, ...)
    elseif method == "transfer" then socket.process = realProcess
    else error("No such method") end
end

local do_syscall = do_syscall

local function makePSPHandle(socket)
    local obj = setmetatable({id = socket.id}, {__name = "socket"})
    function obj:localIP()
        return socket.localIP
    end
    function obj:status()
        if socket.status == "listening" or socket.status == "syn-sent" or socket.status == "syn-received" then return "connecting"
        elseif socket.status == "connected" or socket.buffer ~= "" then return "open"
        elseif socket.status == "error" then return "error", socket.error
        else return "closed" end
    end
    function obj:read(mode, ...)
        if socket.status ~= "connected" and socket.status ~= "close-wait" and socket.status ~= "closed" then error("attempt to read from a " .. socket.status .. " handle", 2) end
        return do_syscall("__socketcall", socket.id, "read", mode, ...)
    end
    function obj:write(data, ...)
        if socket.status ~= "connected" then error("attempt to write to a " .. socket.status .. " handle", 2) end
        return do_syscall("__socketcall", socket.id, "write", data, ...)
    end
    function obj:close()
        if socket.status == "closing" or socket.status == "fin-wait" or socket.status == "closed" then return end
        if not (socket.status == "listening" or socket.status == "syn-sent" or socket.status == "syn-received" or socket.status == "connected") then error("attempt to close a " .. socket.status .. " handle", 2) end
        return do_syscall("__socketcall", socket.id, "close")
    end
    function obj:transfer()
        return do_syscall("__socketcall", socket.id, "transfer")
    end
    return obj
end

-- prefilled entries in info: channel, replyChannel, device

function protocols.recv.link(info, message)
    expect.field(message, "source", "number")
    expect.field(message, "destination", "number")
    expect.field(message, "payload", "table")
    syslog.debug("Received link message from", message.source, "to", message.destination)
    if message.destination ~= os.computerID() then return end
    info.sourceID = message.source
    assert(message.payload.PhoenixNetworking)
    expect.field(message.payload, "type", "string")
    if not protocols.recv[message.payload.type] then error("Unknown protocol '" .. message.payload.type .. "'") end
    return protocols.recv[message.payload.type](info, message.payload)
end

function protocols.recv.arp(info, message)
    expect.field(message, "source", "number")
    expect.field(message, "reply", "boolean")
    syslog.debug("Received arp message from", message.source)
    if not message.reply and message.destinationIP and message.sourceIP ~= message.destinationIP then
        local ip = ipToNumber(expect.field(message, "destinationIP", "string"))
        if ipconfig[info.device.uuid] and ipconfig[info.device.uuid].ip == ip then
            protocols.send.arp_reply(info, message.source, message.sourceIP)
        end
    end
    if message.sourceIP then
        local ip = ipToNumber(expect.field(message, "sourceIP", "string"))
        arptable[info.device.uuid] = arptable[info.device.uuid] or {}
        arptable[info.device.uuid][ip] = message.source
        -- copy the table so we don't skip any if the function modifies the table
        local tmp = {}
        for i, v in ipairs(waiting.arp) do tmp[i] = v end
        for _, v in ipairs(tmp) do v(v, message.sourceIP, message.source) end
    end
end

function protocols.recv.internet(info, message)
    info.sourceIP = ipToNumber(expect.field(message, "source", "string"))
    local dest = ipToNumber(expect.field(message, "destination", "string"))
    info.localIP = dest
    syslog.debug("Received internet message from", message.source, "to", message.destination)
    expect.field(message, "payload", "table")
    if usedMessageIDs[expect.field(message, "messageID", "number", "string")] then return end
    usedMessageIDs[message.messageID] = os.epoch "utc"
    if not ipconfig[info.device.uuid] or ipconfig[info.device.uuid].ip ~= dest then return end
    info.ipPacket = message
    assert(message.payload.PhoenixNetworking)
    expect.field(message.payload, "type", "string")
    if not protocols.recv[message.payload.type] then error("Unknown protocol '" .. message.payload.type .. "'") end
    return protocols.recv[message.payload.type](info, message.payload)
end

function protocols.recv.control(info, message)
    expect.field(message, "messageType", "string")
    syslog.debug("Received control message", message.messageType)
    local retval = false
    if message.messageType == "ping" then protocols.send.control({device = info.device}, info.sourceIP, "pong", nil, info.ipPacket)
    else for _, v in pairs(networkListeners) do retval = v{type = "control", messageType = message.messageType, error = message.error, payload = message.payload, sender = numberToIP(info.sourceIP)} or retval end end
    return retval
end

function protocols.recv.socket(info, message)
    expect.field(message, "sequence", "number")
    expect.field(message, "acknowledgement", "number", "nil")
    expect.field(message, "windowSize", "number", "nil")
    expect.field(message, "payload", "string", "nil")
    if info.channel == 0 or info.replyChannel == 0 then syslog.debug("Received socket event on channel 0; discarding.") return end
    local socket = (openSockets[info.channel] or {})[info.replyChannel] or (openSockets[info.channel] or {}).listen
    if not socket then
        if message.acknowledgement then protocols.send.socket.reset(info, info.sourceIP, info.replyChannel, message.acknowledgement, nil, info.channel)
        else protocols.send.socket.reset(info, info.sourceIP, info.replyChannel, 0, message.sequence + (message.windowSize or 0), info.channel) end
        return
    end
    do
        local s = {}
        for k, v in pairs(socket) do if k ~= "process" then s[k] = v end end
        syslog.debug("Received socket message:", serialize(message), "\nSocket info:", serialize(s))
    end
    if socket.status == "listening" then
        if message.reset then return end
        if message.acknowledgement then
            protocols.send.socket.reset(info, info.sourceIP, info.replyChannel, message.acknowledgement, nil, info.channel)
            return
        end
        if not message.synchronize then return end
        socket.ip = info.sourceIP
        socket.localIP = numberToIP(info.localIP)
        socket.port = info.replyChannel
        socket.recvSeq = message.sequence + 1
        socket.recvSeqMax = socket.recvSeq + (message.windowSize or 0)
        socket.sendSeq = math.floor(math.random()*0x10000000000)
        socket.sendSeqNext = socket.sendSeq + 2
        socket.sendSeqMax = socket.sendSeq + (message.windowSize or 0)
        socket.status = "syn-received"
        socket.nextUpdate = os.epoch "utc" + 5000
        socket.retryCount = 0
        openSockets[info.channel][info.replyChannel] = socket
        openSockets[info.channel].listen = nil
        protocols.send.internet({inPort = info.channel, outPort = info.replyChannel}, socket.ip, {
            PhoenixNetworking = true,
            type = "socket",
            sequence = socket.sendSeqNext - 1,
            acknowledgement = socket.recvSeq,
            windowSize = 256,
            synchronize = true
        })
    elseif socket.status == "syn-sent" then
        if message.reset then
            socket.status = "error"
            socket.error = "Connection refused"
            openSockets[info.channel][info.replyChannel] = nil
            if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} end
            return true
        end
        if not message.synchronize or not message.acknowledgement or message.acknowledgement < socket.sendSeq then
            protocols.send.socket.reset(info, info.sourceIP, info.replyChannel, message.acknowledgement, nil, info.channel)
            socket.status = "error"
            socket.error = "Connection refused"
            openSockets[info.channel][info.replyChannel] = nil
            if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} end
            return true
        end
        socket.localIP = numberToIP(info.localIP)
        socket.status = "connected"
        socket.sendSeq = message.acknowledgement
        socket.sendSeqMax = socket.sendSeq + 256
        socket.recvSeq = message.sequence + 1
        socket.recvSeqMax = socket.recvSeq + (message.windowSize or 0)
        socket.outQueue = {}
        socket.nextUpdate = os.epoch "utc" + 2000
        protocols.send.socket.ack({}, socket.recvSeq, socket)
        if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "connected"}} end
        return true
    else
        if message.sequence < socket.recvSeq or message.sequence > socket.recvSeqMax then
            syslog.debug("Sequence out of range")
            if message.reset then
                socket.status = "error"
                socket.error = "Connection reset by peer"
                openSockets[info.channel][info.replyChannel] = nil
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} end
                return true
            else
                protocols.send.socket.ack({}, socket.recvSeq, socket)
                return
            end
        end
        if message.reset then
            syslog.debug("Received reset")
            if socket.status == "syn-received" then
                socket.status = "listening"
                return
            elseif socket.status == "connected" or socket.status == "fin-wait" then
                socket.status = "error"
                socket.error = "Connection reset by peer"
                openSockets[info.channel][info.replyChannel] = nil
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} end
                return true
            else
                socket.status = "closed"
                openSockets[info.channel][info.replyChannel] = nil
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "closed"}} end
                return true
            end
        end
        if message.synchronize then
            protocols.send.socket.reset(info, info.sourceIP, info.replyChannel, message.acknowledgement, nil, info.channel)
            socket.status = "error"
            socket.error = "Connection reset by host"
            openSockets[info.channel][info.replyChannel] = nil
            if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} end
            return true
        end
        local retval
        if not message.acknowledgement then syslog.debug("No acknowledgement") return end
        if socket.status == "syn-received" then
            if message.acknowledgement >= socket.sendSeq and message.acknowledgement <= socket.sendSeqNext then
                socket.status = "connected"
                socket.outQueue = {}
                socket.nextUpdate = os.epoch "utc" + 2000
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"network_request", {uri = socket.uri, ip = numberToIP(info.sourceIP), handle = makePSPHandle(socket)}} end
                retval = true
            else
                protocols.send.socket.reset(info, info.sourceIP, info.replyChannel, message.acknowledgement, nil, info.channel)
                socket.status = "error"
                socket.error = "Connection reset by host"
                openSockets[info.channel][info.replyChannel] = nil
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} end
                return true
            end
        elseif socket.status == "close-wait" then
            if message.acknowledgement == socket.sendSeqMax then
                syslog.debug("Socket closed")
                socket.status = "closed"
                openSockets[info.channel][info.replyChannel] = nil
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "closed"}} end
                return true
            end
        elseif socket.status == "time-wait" then
            if message.final then
                protocols.send.socket.ack({}, message.sequence, socket)
                socket.nextUpdate = os.epoch "utc" + 10000
                return
            end
        else
            if message.acknowledgement > socket.sendSeq and message.acknowledgement <= socket.sendSeqNext then
                for i = socket.sendSeq, message.acknowledgement do socket.outQueue[i] = nil end
                socket.sendSeq = message.acknowledgement
                if message.windowSize then socket.sendSeqMax = socket.sendSeq + message.windowSize end
            end
            if socket.status == "fin-wait" then
                if message.acknowledgement == socket.sendSeqMax then
                    if not message.final then
                        protocols.send.socket.reset(info, info.sourceIP, info.replyChannel, message.acknowledgement, nil, info.channel)
                        socket.status = "error"
                        socket.error = "Connection reset by host"
                        openSockets[info.channel][info.replyChannel] = nil
                        if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} end
                        return true
                    end
                    socket.status = "time-wait"
                    socket.nextUpdate = os.epoch "utc" + 10000
                end
            elseif socket.status == "closing" then
                if message.acknowledgement == socket.sendSeqMax then
                    socket.status = "time-wait"
                    socket.nextUpdate = os.epoch "utc" + 10000
                end
            end
        end
        if socket.status == "connected" and message.sequence == socket.recvSeq then
            if message.payload then
                socket.buffer = socket.buffer .. message.payload
                socket.nextAck = true
                socket.nextUpdate = os.epoch "utc" + 100
                if socket.process then
                    syslog.debug("Sending data event to PID " .. socket.process.id)
                    socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_data_ready", {id = socket.id}}
                end
                retval = true
            end
            socket.recvSeq = socket.recvSeq + 1
        end
        if message.final then
            syslog.debug("Got final message")
            socket.recvSeq = message.sequence + 1
            if socket.status == "syn-received" or socket.status == "connected" then
                socket.sendSeqMax = socket.sendSeqNext
                protocols.send.socket.data({}, {
                    final = true,
                    acknowledgement = message.sequence
                }, socket)
                socket.status = "close-wait"
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "closed"}} end
                return true
            elseif socket.status == "fin-wait" then
                protocols.send.socket.ack({}, message.sequence, socket)
                if message.acknowledgement ~= socket.sendSeqMax then
                    socket.status = "closing"
                else
                    socket.status = "time-wait"
                    socket.nextUpdate = os.epoch "utc" + 10000
                end
            else
                protocols.send.socket.ack({}, message.sequence, socket)
            end
            syslog.debug(socket.status)
        end
        return retval
    end
end

-- This function is called every second, handling any timed updates that may be necessary for sockets.
local function socketUpdate()
    local time = os.epoch "utc"
    local event = false
    for port, list in pairs(openSockets) do for replyPort, socket in pairs(list) do if time >= socket.nextUpdate then
        if socket.status == "syn-sent" then
            socket.status = "error"
            socket.error = "Connection timed out (syn-sent)"
            openSockets[port][replyPort] = nil
            if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} event = true end
        elseif socket.status == "syn-received" then
            socket.retryCount = socket.retryCount + 1
            if socket.retryCount > 3 then
                socket.status = "error"
                socket.error = "Connection timed out (syn-received)"
                openSockets[port][replyPort] = nil
                if socket.process then socket.process.eventQueue[#socket.process.eventQueue+1] = {"handle_status_change", {id = socket.id, status = "error"}} event = true end
            else
                -- TODO: resend syn+ack packet
                socket.nextUpdate = os.epoch "utc" + 2000
            end
        elseif socket.status == "connected" then
            for i = socket.sendSeq + 1, socket.sendSeqNext - 1 do
                if socket.outQueue[i] then
                    protocols.send.socket.data({}, {
                        sequence = i,
                        payload = socket.outQueue[i]
                    }, socket)
                end
            end
            if socket.nextAck then
                protocols.send.socket.ack({}, socket.recvSeq - 1, socket)
                socket.nextAck = nil
            end
            socket.nextUpdate = os.epoch "utc" + 2000
        elseif socket.status == "fin-wait" then

        elseif socket.status == "close-wait" then

        elseif socket.status == "time-wait" then
            syslog.debug("Time wait finished on port " .. port)
            socket.status = "closed"
            openSockets[port][replyPort] = nil
        end
    end end end
    return event
end

eventHooks.modem_message = eventHooks.modem_message or {}
eventHooks.modem_message[#eventHooks.modem_message+1] = function(ev)
    if type(ev[5]) == "table" and ev[5].PhoenixNetworking and type(ev[5].type) == "string" and protocols.recv[ev[5].type] then
        local node = getNodeById(ev[2]) or hardware.get(ev[2])
        if not node then
            syslog.log({level = "notice", module = "Network"}, "Received network event for device ID " .. ev[2] .. ", but no device node was found; ignoring")
            return
        end
        if not ipconfig[node.uuid] or not ipconfig[node.uuid].up then return end
        syslog.debug(ev[2], serialize(ev[5]))
        local ok, err = pcall(protocols.recv[ev[5].type], {channel = ev[3], replyChannel = ev[4], device = node}, ev[5])
        if not ok then syslog.log({level = "debug", module = "Network"}, "Network event errored while processing:", err)
        else return err end
    end
end

local socketTimer = os.startTimer(1)
eventHooks.timer = eventHooks.timer or {}
eventHooks.timer[#eventHooks.timer+1] = function(ev)
    if ev[2] == socketTimer then
        socketTimer = os.startTimer(1)
        --syslog.debug("Triggering socket timer")
        return socketUpdate()
    end
end

local function pspHandler(process, options)
    -- TODO: implement device filtering
    local uri = parseURI(options.url)
    if not uri.port then error("No port specified") end
    local ip = ipToNumber(uri.host)
    local port = uri.port
    local socket = {process = process, buffer = ""}
    protocols.send.socket.connect({process = process}, ip, port, socket)
    return makePSPHandle(socket)
end

--#endregion

--#region HTTP/Rednet handlers

local httpRequests = {}
local rednetOpenCount = {}
local rednetHandles = {}
local rednetChannel = os.computerID() % 65500
local receivedRednetMessages = {}

eventHooks.http_success = eventHooks.http_success or {}
eventHooks.http_success[#eventHooks.http_success+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.handle, info.status = ev[3], "open"
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = "open"}}
        httpRequests[ev[2]] = nil
        return true
    else syslog.log({level = "notice"}, "Received HTTP response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.http_failure = eventHooks.http_failure or {}
eventHooks.http_failure[#eventHooks.http_failure+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        if ev[4] then info.handle, info.status = ev[4], "open"
        else info.status, info.error = "error", ev[3] end
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = info.status}}
        httpRequests[ev[2]] = nil
        return true
    else syslog.log({level = "notice"}, "Received HTTP response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_success = eventHooks.websocket_success or {}
eventHooks.websocket_success[#eventHooks.websocket_success+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.handle, info.status = ev[3], "open"
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = "open"}}
        return true
    else syslog.log({level = "notice"}, "Received WebSocket response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_failure = eventHooks.websocket_failure or {}
eventHooks.websocket_failure[#eventHooks.websocket_failure+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.status, info.error = "error", ev[3]
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = info.status}}
        return true
    else syslog.log({level = "notice"}, "Received WebSocket response for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_message = eventHooks.websocket_message or {}
eventHooks.websocket_message[#eventHooks.websocket_message+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        -- TODO: decide whether to transcode if the requested encoding doesn't match the message
        info.buffer = info.buffer .. ev[3]
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_data_ready", {id = info.id}}
        return true
    else syslog.log({level = "notice"}, "Received WebSocket message for " .. ev[2] .. " but nobody requested it; ignoring.") end
end

eventHooks.websocket_closed = eventHooks.websocket_closed or {}
eventHooks.websocket_closed[#eventHooks.websocket_closed+1] = function(ev)
    local info = httpRequests[ev[2]]
    if info then
        info.status = "closed"
        info.process.eventQueue[#info.process.eventQueue+1] = {"handle_status_change", {id = info.id, status = info.status}}
        httpRequests[ev[2]] = nil
        return true
    else syslog.log({level = "notice"}, "Received WebSocket message for " .. ev[2] .. " but it's not open; ignoring.") end
end

eventHooks.modem_message = eventHooks.modem_message or {}
eventHooks.modem_message[#eventHooks.modem_message+1] = function(ev)
    local retval = false
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
                    retval = true
                end
            end
        end
        if rednetHandles[0xFFFFFFFF] then
            for _, v in ipairs(rednetHandles[0xFFFFFFFF]) do
                if not v.protocol or v.protocol == ev[5].sProtocol then
                    v.buffer[#v.buffer+1] = deepcopy(ev[5].message)
                    receivedRednetMessages[ev[5].nMessageID] = os.clock() + 9.5
                    v.process.eventQueue[#v.process.eventQueue+1] = {"handle_data_ready", {id = v.id}}
                    retval = true
                end
            end
        end
        for k, v in pairs(receivedRednetMessages) do if v < os.clock() then receivedRednetMessages[k] = nil end end
    end
    return retval
end

-- TODO: Fix handle:read() not being equivalent to handle:read("*l")

local request = http.request
local function httpHandler(process, options)
    expect.field(options, "encoding", "string", "nil")
    expect.field(options, "headers", "table", "nil")
    expect.field(options, "method", "string", "nil")
    expect.field(options, "redirect", "boolean", "nil")
    local info = {status = "ready", process = process, id = nextHandleID}
    local obj = setmetatable({id = nextHandleID}, {__name = "socket"})
    nextHandleID = nextHandleID + 1
    function obj:status()
        return info.status, info.error
    end
    function obj:read(mode, ...)
        if info.status ~= "open" then error("attempt to read from a " .. info.status .. " handle", 2) end
        mode = mode or "*l"
        if type(mode) ~= "string" and type(mode) ~= "number" then error("bad argument (expected string or number, got " .. type(mode) .. ")", 2) end
        mode = mode:gsub("^%*", "")
        if mode == "a" then
            if select("#", ...) > 0 then return info.handle.readAll(), self:read(...)
            else return info.handle.readAll() end
        elseif mode == "l" then
            if select("#", ...) > 0 then return info.handle.readLine(false), self:read(...)
            else return info.handle.readLine(false) end
        elseif mode == "L" then
            if select("#", ...) > 0 then return info.handle.readLine(true), self:read(...)
            else return info.handle.readLine(true) end
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
            if select("#", ...) > 0 then return tonumber(str), self:read(...)
            else return tonumber(str) end
        elseif type(mode) == "number" then
            if select("#", ...) > 0 then return info.handle.read(mode), self:read(...)
            else return info.handle.read(mode) end
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
        local ok, err = request{url = url, body = data, headers = options.headers, binary = options.encoding == "binary" or options.encoding == nil, method = options.method, redirect = options.redirect}
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

-- TODO: decide whether messages should be split, binary, etc.
local function wsHandler(process, options)
    expect.field(options, "encoding", "string", "nil")
    expect.field(options, "headers", "table", "nil")
    local info = {process = process, id = nextHandleID, buffer = ""}
    local obj = setmetatable({id = nextHandleID}, {__name = "socket"})
    nextHandleID = nextHandleID + 1
    function obj:status()
        return info.status, info.error
    end
    function obj:read(mode, ...)
        if info.status ~= "open" then error("attempt to read from a " .. info.status .. " handle", 2) end
        mode = mode or "*l"
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
                if select("#", ...) > 0 then return str, self:read(...)
                else return str end
            else return nil end
        elseif mode == "L" then
            local str, pos = info.buffer:match "^([^\n]*\n?)()"
            if str then
                info.buffer = info.buffer:sub(pos)
                if select("#", ...) > 0 then return str, self:read(...)
                else return str end
            else return nil end
        elseif mode == "n" then
            local str, pos = info.buffer:match "(%d+)()"
            if str then
                info.buffer = info.buffer:sub(pos)
                if select("#", ...) > 0 then return tonumber(str), self:read(...)
                else return tonumber(str) end
            else return nil end
        elseif type(mode) == "number" then
            local str = info.buffer:sub(1, mode)
            info.buffer = info.buffer:sub(mode + 1)
            if select("#", ...) > 0 then return str, self:read(...)
            else return str end
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
        checkModem(v)
        if not rednetOpenCount[v] then
            hardware.call(process, v, "open", rednetChannel)
            hardware.call(process, v, "open", 65535)
            rednetOpenCount[v] = 1
        else rednetOpenCount[v] = rednetOpenCount[v] + 1 end
    end
    local uri = parseURI(options.url)
    if not uri.host then error("Missing host", 2) end
    local id = ipToNumber(uri.host)
    local info = {process = process, id = nextHandleID, buffer = {}, protocol = uri.scheme:match "rednet%+(.+)"}
    local obj = setmetatable({id = nextHandleID}, {__name = "socket"})
    nextHandleID = nextHandleID + 1
    function obj:status()
        return info.closed and "closed" or "open"
    end
    function obj:read(mode, ...)
        if info.closed then error("attempt to read from a " .. info.status .. " handle", 2) end
        mode = mode or "*l"
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
                if select("#", ...) > 0 then return str, self:read(...)
                else return str end
            else
                table.remove(info.buffer, 1)
                return self:read(mode, ...)
            end
        elseif mode == "L" then
            info.buffer[1] = tostring(info.buffer[1])
            local str, pos = info.buffer[1]:match "^([^\n]*\n?)()"
            if str then
                info.buffer[1] = info.buffer[1]:sub(pos)
                if select("#", ...) > 0 then return str, self:read(...)
                else return str end
            else
                table.remove(info.buffer, 1)
                return self:read(mode, ...)
            end
        elseif mode == "n" then
            info.buffer[1] = tostring(info.buffer[1])
            local str, pos = info.buffer[1]:match "(%d+)()"
            if str then
                info.buffer[1] = info.buffer[1]:sub(pos)
                if select("#", ...) > 0 then return tonumber(str), self:read(...)
                else return tonumber(str) end
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
            if select("#", ...) > 0 then return str, self:read(...)
            else return str end
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
                hardware.call(process, v, "transmit", id == 0xFFFFFFFF and 65535 or id % 65500, rednetChannel, msg)
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

--#endregion

-- TODO: add event handling for HTTP/WS servers

--- Stores all URI scheme handlers using Lua patterns as keys.
uriSchemes = {
    ["https?"] = httpHandler,
    ["wss?"] = wsHandler,
    ["rednet"] = rednetHandler,
    ["rednet%+%a+"] = rednetHandler,
    ["psp"] = pspHandler
}

function syscalls.connect(process, thread, options)
    if type(options) == "string" then options = {url = options} end
    expect(1, options, "table")
    expect.field(options, "url", "string")
    local uri = parseURI(options.url)
    local obj, err
    for k, v in pairs(uriSchemes) do
        if uri.scheme:match(k) then
            obj, err = v(process, options)
            break
        end
    end
    if not obj and not err then error("Invalid protocol " .. uri.scheme) end
    if obj then for _, v in pairs(obj) do if type(v) == "function" then setfenv(v, process.env) debug.protect(v) end end end
    return obj, err
end

function syscalls.listen(process, thread, uri)
    expect(1, uri, "string")
    local URI = parseURI(uri)
    if http.addListener then
        if URI.scheme == "http" then
            http.addListener(URI.port or 80)
            return
        elseif URI.scheme == "ws" then
            http.websocket(URI.port or 80)
            return
        end
    end
    if URI.scheme == "psp" then
        if not URI.port then error("Missing port") end
        local ip = ipToNumber(URI.host)
        for k, v in pairs(ipconfig) do
            if v.up and (ip == 0 or v.ip == ip) then
                hardware.call(process, hardware.get(k), "open", URI.port)
            end
        end
        local socket = {
            localPort = URI.port,
            id = nextHandleID,
            status = "listening",
            process = process,
            nextUpdate = math.huge,
            retryCount = 0,
            uri = uri,
            buffer = ""
        }
        nextHandleID = nextHandleID + 1
        openSockets[URI.port] = openSockets[URI.port] or {}
        openSockets[URI.port].listen = socket
        openSocketIDs[socket.id] = socket
        return
    end
    error("Invalid protocol " .. URI.scheme)
end

function syscalls.unlisten(process, thread, uri)
    -- TODO
end

function syscalls.ipconfig(process, thread, device, info)
    if info and process.user ~= "root" then error("Permission denied") end
    expect(1, device, "string")
    expect(2, info, "table", "nil")
    local node = checkModem(hardware.get(device))
    local t = ipconfig[node.uuid]
    if not t then
        if info then
            expect.field(info, "ip", "string", "number")
            expect.field(info, "netmask", "string", "number")
            t = {up = true}
            ipconfig[node.uuid] = t
            hardware.call(KERNEL, node, "open", 0)
        else return nil end
    end
    if info then
        expect.field(info, "ip", "string", "number", "nil")
        expect.field(info, "netmask", "string", "number", "nil")
        expect.field(info, "up", "boolean", "nil")
        local localRoute, broadcastRoute
        if t.ip then
            for _, v in ipairs(routes[0]) do
                if v.source == bit32.band(t.ip, t.netmask) and v.netmask == t.netmask then localRoute = v
                elseif v.source == bit32.bor(bit32.band(t.ip, t.netmask), bit32.bnot(t.netmask)) and v.netmask == 0xFFFFFFFF then broadcastRoute = v end
            end
        end
        if info.ip then
            if arptable[node.uuid] then arptable[node.uuid][t.ip] = nil end
            if type(info.ip) == "number" then t.ip = bit32.band(info.ip, 0xFFFFFFFF)
            else t.ip = ipToNumber(info.ip) end
            if localRoute then localRoute.source = bit32.band(t.ip, t.netmask) end
            if broadcastRoute then broadcastRoute.source = bit32.bor(bit32.band(t.ip, t.netmask), bit32.bnot(t.netmask)) end
            arptable[node.uuid] = arptable[node.uuid] or {}
            arptable[node.uuid][t.ip] = os.computerID()
        end
        if info.netmask then
            if type(info.netmask) == "number" then t.netmask = prefixToMask(info.netmask)
            else t.netmask = ipToNumber(info.netmask) end
            if localRoute then localRoute.source = bit32.band(t.ip, t.netmask) end
            if broadcastRoute then broadcastRoute.source = bit32.bor(bit32.band(t.ip, t.netmask), bit32.bnot(t.netmask)) end
        end
        if info.up ~= nil then
            t.up = info.up
            if t.up then hardware.call(KERNEL, node, "open", 0)
            else hardware.call(KERNEL, node, "close", 0) end
        end
        if not localRoute then routes[0][#routes[0]+1] = {
            source = bit32.band(t.ip, t.netmask),
            sourceNetmask = t.netmask,
            action = "local",
            device = node
        } end
        if not broadcastRoute then routes[0][#routes[0]+1] = {
            source = bit32.bor(bit32.band(t.ip, t.netmask), bit32.bnot(t.netmask)),
            sourceNetmask = 0xFFFFFFFF,
            action = "broadcast",
            device = node
        } end
    end
    return {
        ip = numberToIP(t.ip),
        netmask = maskToPrefix(t.netmask),
        up = t.up
    }
end

function syscalls.routelist(process, thread, num)
    num = expect(1, num, "number", "nil") or 1
    expect.range(num, 0)
    if not routes[num] then return nil end
    local retval = {}
    for i, t in ipairs(routes[num]) do
        retval[i] = {
            source = numberToIP(t.source),
            sourceNetmask = maskToPrefix(t.sourceNetmask),
            action = t.action,
            device = t.device and hardware.path(t.device),
            destination = t.destination and numberToIP(t.destination)
        }
    end
    return retval
end

local actionNames = {unicast = true, broadcast = true, ["local"] = true, unreachable = true, prohibit = true, blackhole = true}

function syscalls.routeadd(process, thread, options)
    if process.user ~= "root" then error("Permission denied") end
    expect(1, options, "table")
    expect.field(options, "source", "string", "number")
    expect.field(options, "sourceNetmask", "string", "number")
    expect.field(options, "action", "string")
    expect.field(options, "device", "string", (options.action ~= "unicast" and options.action ~= "broadcast" and options.action ~= "local") and "nil" or nil)
    expect.field(options, "destination", "string", options.action ~= "unicast" and "nil" or nil)
    expect.range(expect.field(options, "table", "number", "nil") or 1, 1)
    options.table = options.table or 1
    if not actionNames[options.action] then error("bad field 'action' (invalid option '" .. options.action .. "')") end
    local t = {}
    if type(options.source) == "number" then t.source = bit32.band(options.source, 0xFFFFFFFF)
    else t.source = ipToNumber(options.source) end
    if type(options.sourceNetmask) == "number" then t.sourceNetmask = prefixToMask(options.sourceNetmask)
    else t.sourceNetmask = ipToNumber(options.sourceNetmask) end
    t.source = bit32.band(t.source, t.sourceNetmask)
    t.action = options.action
    t.device = options.device and checkModem(hardware.get(options.device))
    t.destination = options.destination and ipToNumber(options.destination)
    routes[options.table] = routes[options.table] or {}
    for _, v in ipairs(routes[options.table]) do if v.source == t.source and v.sourceNetmask == t.sourceNetmask then error("Route already exists") end end
    routes[options.table][#routes[options.table]+1] = t
    routes.maxn = math.max(routes.maxn, options.table)
end

function syscalls.routedel(process, thread, source, mask, num)
    if process.user ~= "root" then error("Permission denied") end
    expect(1, source, "string", "number")
    expect(2, mask, "string", "number")
    num = expect(3, num, "number", "nil") or 1
    expect.range(num, 1)
    if type(mask) == "number" then mask = prefixToMask(mask)
    else mask = ipToNumber(mask) end
    if type(source) == "number" then source = bit32.band(source, mask)
    else source = bit32.band(ipToNumber(source), mask) end
    if not routes[num] then error("Route table does not exist") end
    for i, v in ipairs(routes[num]) do if v.source == source and v.sourceNetmask == mask then table.remove(routes[num], i) return end end
end

function syscalls.arplist(process, thread, device)
    expect(1, device, "string")
    local node = checkModem(hardware.get(device))
    local retval = {}
    for k, v in pairs(arptable[node.uuid] or {}) do retval[numberToIP(k)] = v end
    return retval
end

function syscalls.arpset(process, thread, device, ip, id)
    if process.user ~= "root" then error("Permission denied") end
    expect(1, device, "string")
    expect(2, ip, "string", "number")
    expect(3, id, "number")
    local node = checkModem(hardware.get(device))
    if type(ip) == "string" then ip = ipToNumber(ip)
    else ip = bit32.band(ip, 0xFFFFFFFF) end
    arptable[node.uuid] = arptable[node.uuid] or {}
    arptable[node.uuid][ip] = id
end

local controlNames = {ping = true, pong = true, unreachable = true, timeout = true}

function syscalls.netcontrol(process, thread, ip, typ, err)
    if process.user ~= "root" then error("Permission denied") end
    expect(1, ip, "string", "number")
    expect(2, typ, "string")
    expect(3, err, "string", "nil")
    if not controlNames[typ] then error("bad argument #2 (invalid option '" .. typ .. "')") end
    if type(ip) == "string" then ip = ipToNumber(ip)
    else ip = bit32.band(ip, 0xFFFFFFFF) end
    protocols.send.control({process = process}, ip, typ, err)
end

function syscalls.netevent(process, thread, state)
    if process.user ~= "root" then error("Permission denied") end
    expect(1, state, "boolean", "nil")
    if state == true then networkListeners[process] = function(message)
        process.eventQueue[#process.eventQueue+1] = {"network_event", deepcopy(message)}
        return true
    end elseif state == false then networkListeners[process] = nil end
    return networkListeners[process] ~= nil
end

function syscalls.checkuri(process, thread, uri)

end

function registerLoopback()
    local node = hardware.get("/lo")
    if node then
        ipconfig[node.uuid] = {ip = 0x7F000001, netmask = 0xFF000000, up = true}
        routes[0][#routes[0]+1] = {
            source = 0x7F000000,
            sourceNetmask = 0xFF000000,
            action = "local",
            device = node
        }
        routes[0][#routes[0]+1] = {
            source = 0x7FFFFFFF,
            sourceNetmask = 0xFFFFFFFF,
            action = "broadcast",
            device = node
        }
        arptable[node.uuid] = setmetatable({}, {__index = function() return os.computerID() end})
        syslog.log("Configured IP for loopback device")
    end
end
