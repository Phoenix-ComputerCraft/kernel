local do_syscall = do_syscall
local expect = expect

local function mult64on32(ah, al, bh, bl)
    local a = {bit32.extract(al, 0, 16), bit32.extract(al, 16, 16), bit32.extract(ah, 0, 16), bit32.extract(ah, 16, 16)}
    local b = {bit32.extract(bl, 0, 16), bit32.extract(bl, 16, 16), bit32.extract(bh, 0, 16), bit32.extract(bh, 16, 16)}
    local partial = {{0, 0, 0, 0, 0}, {0, 0, 0, 0, 0}, {0, 0, 0, 0, 0}, {0, 0, 0, 0, 0}}
    for bi = 1, 4 do
        for ai = 1, 4 do
            local n = a[ai] * b[bi] + partial[bi][ai]
            partial[bi][ai+1], partial[bi][ai] = bit32.rshift(n, 16), bit32.band(n, 0xFFFF)
        end
    end
    local q = {0, 0, 0, 0, 0, 0, 0, 0}
    for col = 1, 8 do
        for row = 1, 4 do q[col] = q[col] + (partial[row][col-row+1] or 0) end
        q[col+1], q[col] = bit32.rshift(q[col], 16), bit32.band(q[col], 0xFFFF)
    end
    return q[3] + q[4] * 0x10000, q[1] + q[2] * 0x10000
end
local function add64with32(b, ah, al)
    return ah + math.floor((al + b) / 0x100000000), bit32.band(al + b, 0xFFFFFFFF)
end

function makeRandom()
    local random_state_h, random_state_l = 0, 0
    local function next(bits)
        random_state_h, random_state_l = add64with32(0xB, mult64on32(random_state_h, random_state_l, 0x5, 0xDEECE66D))
        random_state_h = bit32.band(random_state_h, 0xFFFF)
        return math.floor(random_state_h / 2^(16-bits)) + math.floor(random_state_l / 2^(48-bits))
    end
    local function random(min, max)
        expect(1, min, "number", "nil")
        expect(2, max, "number", "nil")
        if min then
            expect.range(min, 0, 0x7FFFFFFF)
            if not max then min, max = 0, min
            else expect.range(max, 0, 0x7FFFFFFF) end
            local bound = max - min
            local rand
            if math.log(bound, 2) % 1 == 0 then rand = bit32.rshift((bound * next(31)), 31)
            else
                local bits
                repeat
                    bits = next(31)
                    rand = bits % bound
                until bits - rand + (bound-1) >= 0
            end
            return rand + min
        else return (next(26) * 0x8000000 + next(27)) / 0x20000000000000 end
    end
    local function randomseed(seed)
        expect(1, seed, "number")
        random_state_h, random_state_l = bit32.band(bit32.bxor(0x5, math.floor(seed / 0x100000000)), 0xFFFF), bit32.bxor(0xDEECE66D, math.floor(seed))
    end
    randomseed(os.epoch "utc" * tonumber(tostring(next):match("%x+") or "1", 16))
    return random, randomseed
end

do
    -- PUC Lua's default randomizer is crap, so we're installing a custom one in the kernel as well.
    -- This gives us better precision for randomization on those systems.
    -- (This has no visible effect on Cobalt-based CC, as it uses the same algorithm.)
    math.random, math.randomseed = makeRandom()
end

--- Creates a new global table with a Lua 5.2 standard library installed.
-- @tparam Process process The process to generate for
-- @treturn _G A new global table for the process
function createLuaLib(process)
    local G = {}
    for _,v in ipairs{"assert", "error", "getfenv", "getmetatable", "ipairs", "next",
        "pairs", "pcall", "rawequal", "rawget", "rawset", "select", "setfenv",
        "setmetatable", "tonumber", "tostring", "type", "_VERSION", "xpcall"} do G[v] = _G[v] end

    -- TODO: update the below notice since we can just localize globals we need (!)

    -- We can't use any kernel-level globals like `expect` here, so argument checks will be manual.
    -- Normally using upvalues wouldn't be allowed either, but dbprotect blocks access so it should be alright.

    function G.dofile(path)
        if type(path) ~= "string" then error("bad argument #1 (expected string, got " .. type(path) .. ")", 2) end
        local fn, err = loadfile(path, nil, _G)
        if not fn then error(err, 2) end
        return fn()
    end

    local load = load
    if _VERSION == "Lua 5.1" then
        function G.load(chunk, name, mode, env)
            -- Shadow environment table to add proper _ENV support
            -- TODO: Figure out if this could break anything
            env = env or process.env
            return load(chunk, name, mode, setmetatable({}, {
                __index = function(_, idx)
                    if idx == "_ENV" then return env
                    else return env[idx] end
                end,
                __newindex = function(_, idx, val)
                    if idx == "_ENV" then env = val
                    else env[idx] = val end
                end,
                __pairs = function()
                    return next, env
                end,
                __len = function()
                    return #env
                end
            }))
        end
    else G.load = function(chunk, name, mode, env) return load(chunk, name, mode, env or process.env) end end

    function G.loadfile(path, mode, env)
        if env == nil and type(mode) == "table" then env, mode = mode, nil end
        if type(path) ~= "string" then error("bad argument #1 (expected string, got " .. type(path) .. ")", 2) end
        if mode ~= nil and type(mode) ~= "string" then error("bad argument #2 (expected string, got " .. type(mode) .. ")", 2) end
        if env ~= nil and type(env) ~= "table" then error("bad argument #3 (expected table, got " .. type(env) .. ")", 2) end
        local file, err = do_syscall("open", path, "rb")
        if not file then error(err, 2) end
        local data = file.readAll()
        file.close()
        return load(data, "@" .. path, mode, env)
    end

    function G.print(...)
        local args = table.pack(...)
        args[args.n+1] = "\n"
        return do_syscall("write", table.unpack(args, 1, args.n + 1))
    end

    G.coroutine = deepcopy(coroutine)
    G.string = deepcopy(string)
    G.table = deepcopy(table)
    G.math = deepcopy(math)
    G.bit32 = deepcopy(bit32)

    -- The default math.random uses a global seed which cannot be shared between processes,
    -- so we need to implement our own randomizer.

    G.math.random, G.math.randomseed = makeRandom()

    local oldcreate = coroutine.create
    local sethook = debug.sethook
    function G.coroutine.create(func)
        -- since the hook is inherited (not good in child coroutines!) we need to erase it
        local coro = oldcreate(func)
        if coro and debug then sethook(coro, nil, "", 0) end
        return coro
    end

    local stdin_buffer = ""
    local io_stdin = setmetatable({
        close = function() end,
        lines = function(self, ...)
            local args = table.pack(...)
            return function() return self:read(table.unpack(args, 1, args.n)) end
        end,
        read = function(self, fmt, ...)
            local s, e
            fmt = fmt or "*l"
            if type(fmt) == "number" then while #stdin_buffer < fmt do stdin_buffer = stdin_buffer .. do_syscall("read", fmt) end
            elseif type(fmt) == "string" then
                fmt = fmt:gsub("^%*", "")
                if fmt == "n" then
                    while not stdin_buffer:find("%d") do
                        local r = do_syscall("readline")
                        if r == nil then break end
                        stdin_buffer = stdin_buffer .. r
                    end
                elseif fmt == "a" then
                    while true do
                        local r = do_syscall("readline")
                        if r == nil then break end
                        stdin_buffer = stdin_buffer .. r
                    end
                elseif fmt == "l" or fmt == "L" then
                    local r = do_syscall("readline")
                    if r == nil then return nil end
                    stdin_buffer = stdin_buffer .. r .. "\n"
                else error("bad argument (invalid format '" .. fmt .. "')", 2) end
            else error("bad argument (expected string or number, got " .. type(fmt), 2) end
            if type(fmt) == "number" then s, e = stdin_buffer:sub(1, fmt), fmt + 1
            elseif fmt == "n" then s, e = stdin_buffer:match("(%d)()")
            elseif fmt == "a" then s, e = stdin_buffer, #stdin_buffer + 1
            elseif fmt == "l" then s, e = stdin_buffer:match("(.*)\n()")
            else s, e = stdin_buffer:match("(.*\n)()") end
            if not s then return nil end
            stdin_buffer = stdin_buffer:sub(e)
            if select("#", ...) > 0 then return s, self:read(...)
            else return s end
        end,
        seek = function() return nil, "Cannot seek default file" end,
        setvbuf = function() end
    }, {__name = "FILE*"})
    local io_stdout = setmetatable({
        close = function() end,
        flush = function() end,
        seek = function() return nil, "Cannot seek default file" end,
        setvbuf = function() end,
        write = function(self, ...)
            do_syscall("write", ...)
            return self
        end
    }, {__name = "FILE*"})
    local io_stderr = setmetatable({
        close = function() end,
        flush = function() end,
        seek = function() return nil, "Cannot seek default file" end,
        setvbuf = function() end,
        write = function(self, ...)
            do_syscall("writeerr", ...)
            return self
        end
    }, {__name = "FILE*"})
    local io_input, io_output = io_stdin, io_stdout

    local io_infile = {
        close = function(self)
            self._file.close()
            self._closed = true
        end,
        lines = function(self, ...)
            local args = table.pack(...)
            return function() return self:read(table.unpack(args, 1, args.n)) end
        end,
        read = function(self, fmt, ...)
            local v
            if fmt == nil then fmt = "l" end
            if type(fmt) == "number" then v = self._file.read(fmt)
            elseif type(fmt) == "string" then
                fmt = fmt:gsub("^%*", "")
                if fmt == "a" then v = self._file.readAll()
                elseif fmt == "l" then v = self._file.readLine(false)
                elseif fmt == "L" then v = self._file.readLine(true)
                elseif fmt == "n" then
                    local s, c = ""
                    repeat c = self._file.read(1) until c:match("%d")
                    while c:match("%d") do s, c = s .. c, self._file.read(1) end
                    v = tonumber(s)
                else error("bad argument (invalid format '" .. fmt .. "')", 2) end
            else error("bad argument (expected string or number, got " .. type(fmt) .. ")", 2) end
            if select("#", ...) > 0 then return v, self:read(...)
            else return v end
        end,
        seek = function(self, whence, offset)
            if self._file.seek then return self._file.seek(whence, offset)
            else return nil, "Cannot seek text file" end
        end,
        setvbuf = function() end
    }
    local io_outfile = {
        close = function(self)
            self._file.close()
            self._closed = true
        end,
        flush = function(self)
            self._file:flush()
        end,
        seek = function(self, whence, offset)
            if self._file.seek then return self._file.seek(whence, offset)
            else return nil, "Cannot seek text file" end
        end,
        setvbuf = function() end,
        write = function(self, ...)
            self._file.write(...)
            return self
        end
    }

    G.io = {
        close = function(file)
            if file == nil then io_output:close()
            elseif type(file) == "table" and getmetatable(file) and getmetatable(file).__name == "FILE*" then file:close()
            else error("bad argument #1 (expected FILE*, got " .. type(file) .. ")", 2) end
        end,
        flush = function()
            return io_output:flush()
        end,
        input = function(file)
            if file == nil then return io_input
            elseif type(file) == "string" then
                local h, err = io.open(file, "r")
                if not h then error(err, 2) end
                io_input = h
            elseif type(file) == "table" and getmetatable(file) and getmetatable(file).__name == "FILE*" then io_input = file
            else error("bad argument #1 (expected string or FILE*, got " .. type(file) .. ")", 2) end
        end,
        lines = function(filename, ...)
            if filename == nil then return io_input:lines(...) end
            if type(filename) ~= "string" then error("bad argument #1 (expected string, got " .. type(filename) .. ")", 2) end
            local h, err = io.open(filename, "r")
            if not h then error(err, 2) end
            local fn = h:lines(...)
            return function(...)
                local retval = table.pack(fn(...))
                if retval.n == 0 or retval[1] == nil then h:close() end
                return table.unpack(retval, 1, retval.n)
            end
        end,
        open = function(filename, mode)
            if type(filename) ~= "string" then error("bad argument #1 (expected string, got " .. type(filename) .. ")", 2) end
            if type(mode) ~= "string" then error("bad argument #2 (expected string, got " .. type(mode) .. ")", 2) end
            local file, err = do_syscall("open", filename, mode)
            if not file then return nil, err
            elseif mode:find("r") then return setmetatable({_file = file}, {__index = io_infile, __name = "FILE*"})
            else return setmetatable({_file = file}, {__index = io_outfile, __name = "FILE*"}) end
        end,
        output = function(file)
            if file == nil then return io_output
            elseif type(file) == "string" then
                local h, err = io.open(file, "w")
                if not h then error(err, 2) end
                io_output = h
            elseif type(file) == "table" and getmetatable(file) and getmetatable(file).__name == "FILE*" then io_output = file
            else error("bad argument #1 (expected string or FILE*, got " .. type(file) .. ")", 2) end
        end,
        -- Extra ability: if mode == "rw", then returns two file handles: first is "r" (stdin), second is "w" (stdout)
        popen = function(path, mode)
            expect(1, path, "string")
            mode = expect(2, mode, "string", "nil") or "r"
            if mode ~= "r" and mode ~= "w" and mode ~= "rw" then error("bad argument #2 (invalid mode)", 2) end
            if mode == "rw" then
                local ibuffer, obuffer = "", ""
                local pid
                local irhandle = {read = function(n)
                    if ibuffer == "" then return nil
                    elseif n then
                        local s = ibuffer:sub(1, n)
                        ibuffer = ibuffer:sub(n + 1)
                        return s
                    else
                        local s, e = ibuffer:match "([^\n]*)\n*()"
                        ibuffer = ibuffer:sub(e)
                        return s
                    end
                end}
                local iwhandle = {
                    write = function(s) ibuffer = ibuffer .. s end,
                    flush = function() end,
                    close = function()
                        local info = do_syscall("getpinfo", pid)
                        if not info then return end
                        repeat local ev, param = coroutine.yield() until ev == "process_complete" and param.pid == pid
                    end
                }
                local orhandle = {
                    read = function(n)
                        if obuffer == "" then return nil
                        elseif n then
                            local s = obuffer:sub(1, n)
                            obuffer = obuffer:sub(n + 1)
                            return s
                        else
                            local s, e = obuffer:match "([^\n]*)\n*()"
                            obuffer = obuffer:sub(e)
                            return s
                        end
                    end,
                    readLine = function()
                        local s, e = obuffer:match "([^\n]*)\n*()"
                        obuffer = obuffer:sub(e)
                        return s
                    end,
                    readAll = function()
                        local s = obuffer
                        obuffer = ""
                        return s
                    end,
                    close = function()
                        local info = do_syscall("getpinfo", pid)
                        if not info then return end
                        repeat local ev, param = coroutine.yield() until ev == "process_complete" and param.pid == pid
                    end
                }
                local owhandle = {write = function(s) obuffer = obuffer .. s end}
                pid = do_syscall("fork", function()
                    do_syscall("stdin", irhandle)
                    do_syscall("stdout", owhandle)
                    do_syscall("exec", "/bin/sh", "-c", path)
                end)
                return setmetatable({_file = orhandle}, {__index = io_infile, __name = "FILE*"}), setmetatable({_file = iwhandle}, {__index = io_outfile, __name = "FILE*"})
            else
                local buffer = ""
                local pid
                local rhandle = {
                    read = function(n)
                        if buffer == "" then return nil
                        elseif n then
                            local s = buffer:sub(1, n)
                            buffer = buffer:sub(n + 1)
                            return s
                        else
                            local s, e = buffer:match "([^\n]*)\n*()"
                            buffer = buffer:sub(e)
                            return s
                        end
                    end,
                    readLine = function()
                        local s, e = buffer:match "([^\n]*)\n*()"
                        buffer = buffer:sub(e)
                        return s
                    end,
                    readAll = function()
                        local s = buffer
                        buffer = ""
                        return s
                    end,
                    close = function()
                        local info = do_syscall("getpinfo", pid)
                        if not info then return end
                        repeat local ev, param = coroutine.yield() until ev == "process_complete" and param.pid == pid
                    end
                }
                local whandle = {
                    write = function(s) buffer = buffer .. s end,
                    flush = function() end,
                    close = function()
                        local info = do_syscall("getpinfo", pid)
                        if not info then return end
                        repeat local ev, param = coroutine.yield() until ev == "process_complete" and param.pid == pid
                    end
                }
                pid = do_syscall("fork", function()
                    do_syscall(mode == "r" and "stdout" or "stdin", mode == "r" and whandle or rhandle)
                    do_syscall("exec", "/bin/sh", "-c", path)
                end)
                return mode == "r" and setmetatable({_file = rhandle}, {__index = io_infile, __name = "FILE*"}) or setmetatable({_file = whandle}, {__index = io_outfile, __name = "FILE*"})
            end
        end,
        read = function(...)
            return io_input:read(...)
        end,
        tmpfile = function()
            -- TODO: make files delete on exit
            return io.open(os.tmpname(), "a")
        end,
        type = function(obj)
            if type(obj) == "table" and getmetatable(obj) and getmetatable(obj).__name == "FILE*" then
                if obj._closed then return "closed file" else return "file" end
            else return nil end
        end,
        write = function(...)
            return io_output:write(...)
        end,
        stdin = io_stdin,
        stdout = io_stdout,
        stderr = io_stderr
    }

    -- Nicely, we're providing a real `os` implementation instead of the jumbled mess CC gives us
    local oldos = os
    G.os = {
        clock = function() return do_syscall("clock") end,
        date = os.date,
        difftime = function(a, b) return a - b end,
        execute = function(path)
            do_syscall("exec", "/bin/sh", "-c", path)
        end,
        exit = function(code)
            do_syscall("exit", code)
        end,
        getenv = function(name)
            expect(1, name, "string")
            local env = do_syscall("getenv")
            if not env then return nil end
            return env[name]
        end,
        remove = function(path)
            expect(1, path, "string")
            local ok, err = do_syscall("remove", path)
            if not ok then ok = nil end
            return ok, err
        end,
        rename = function(from, to)
            expect(1, from, "string")
            expect(2, to, "string")
            local ok, err = do_syscall("rename", from, to)
            if not ok then ok = nil end
            return ok, err
        end,
        setlocale = function(locale)
            if locale then error("setlocale is not supported", 2)
            else return "C" end
        end,
        time = function(t)
            expect(1, t, "table", "nil")
            if t then return oldos.time(t)
            else return oldos.epoch "utc" / 1000 end
        end,
        tmpname = function()
            local name = "/tmp/lua_"
            for i = 1, 6 do
                local n = math.random(1, 64)
                name = name .. ("qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM1234567890._"):sub(n, n)
            end
            return name
        end
    }

    G.debug = deepcopy(debug) -- since debug is protected, we can pretty much just stick it in here and be alright
    -- TODO: Restrict hook modification so programs can't arbitrarily disable preemption

    createRequire(process, G)

    G.periphemu = periphemu -- TODO: TEMPORARY

    -- Protect all global functions from debug
    for k,v in pairs(G) do
        if type(v) == "function" then
            pcall(setfenv, v, G)
            pcall(debug.protect, v)
        elseif type(v) == "table" and k ~= "debug" then
            for _,w in pairs(v) do if type(w) == "function" then pcall(setfenv, w, G) pcall(debug.protect, w) end end
        end
    end
    return G
end
