local do_syscall = do_syscall
G = {}
for _,v in ipairs{"assert", "error", "getfenv", "getmetatable", "ipairs", "next",
    "pairs", "pcall", "rawequal", "rawget", "rawset", "select", "setfenv",
    "setmetatable", "tonumber", "tostring", "type", "_VERSION", "xpcall"} do G[v] = _G[v] end

-- We can't use any kernel-level globals like `expect` here, so argument checks will be manual.
-- Normally using upvalues wouldn't be allowed either, but dbprotect blocks access so it should be alright.

function G.dofile(path)
    if type(path) ~= "string" then error("bad argument #1 (expected string, got " .. type(path) .. ")", 2) end
    local fn, err = loadfile(path, nil, _G)
    if not fn then error(err, 2) end
    return fn()
end

if loadstring and _VERSION == "Lua 5.1" then
    local _load, _loadstring = load, loadstring
    function G.load(chunk, name, mode, env)
        if name ~= nil and type(name) ~= "string" then error("bad argument #2 (expected string, got " .. type(name) .. ")", 2) end
        if mode ~= nil and type(mode) ~= "string" then error("bad argument #3 (expected string, got " .. type(mode) .. ")", 2) end
        if env ~= nil and type(env) ~= "table" then error("bad argument #4 (expected table, got " .. type(env) .. ")", 2) end
        local fn, err
        if type(chunk) == "string" then
            if mode then
                if chunk:sub(1, 4) == "\033Lua" then if not mode:find("b") then error("attempt to load a binary chunk (mode is '" .. mode .. "')", 2) end
                elseif not mode:find("t") then error("attempt to load a text chunk (mode is '" .. mode .. "')", 2) end
            end
            fn, err = _loadstring(chunk, name)
        elseif type(chunk) == "function" then
            if mode then
                local cf, init = chunk, ""
                while #init < 4 do
                    local s = cf()
                    if not s then break end
                    init = init .. s
                end
                if init:sub(1, 4) == "\033Lua" then if not mode:find("b") then error("attempt to load a binary chunk (mode is '" .. mode .. "')", 2) end
                elseif not mode:find("t") then error("attempt to load a text chunk (mode is '" .. mode .. "')", 2) end
                function chunk()
                    if init then
                        local a = init
                        init = nil
                        return a
                    else return cf() end
                end
            end
            fn, err = _load(chunk, name)
        else error("bad argument #1 (expected string or function, got " .. type(chunk) .. ")", 2) end
        if not fn then return nil, err end
        local mt = getmetatable(env)
        if not mt then mt = {} setmetatable(env, mt) end
        local __index, __newindex = mt.__index, mt.__newindex
        function mt:__index(idx)
            if idx == "_ENV" then return getfenv(2)
            elseif type(__index) == "table" then return __index[idx]
            elseif type(__index) == "function" then return __index(self, idx) end
        end
        function mt:__newindex(idx, val)
            if idx == "_ENV" then setfenv(2, val)
            elseif type(__newindex) == "function" then return __newindex(self, idx, val) end
        end
        setfenv(fn, env)
        return fn
    end
else G.load = load end

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

G.coroutine = {}
for k,v in pairs(coroutine) do G.coroutine[k] = v end
G.string = string
G.table = table
G.math = math
G.bit32 = bit32

local oldcreate = coroutine.create
function G.coroutine.create(func)
    -- since the hook is inherited (not good in child coroutines!) we need to erase it
    local coro = oldcreate(func)
    if coro and debug then debug.sethook(coro, nil, "", 0) end
    return coro
end

if not G.table.pack then G.table.pack = function(...)
    local t = {...}
    t.n = select("#", ...)
    return t
end end
if not G.table.unpack then G.table.unpack = unpack end

local stdin_buffer = ""
local io_stdin = {
    close = function() end,
    lines = function(self, ...)
        local args = table.pack(...)
        return function() return self:read(table.unpack(args, 1, args.n)) end
    end,
    read = function(self, fmt, ...)
        local s, e
        if type(fmt) == "number" then while #stdin_buffer < fmt do stdin_buffer = stdin_buffer .. do_syscall("read") end
        elseif type(fmt) == "string" then
            fmt = fmt:gsub("^%*", "")
            if fmt == "n" then
                while not stdin_buffer:find("%d") do
                    local r = do_syscall("read")
                    if r == nil then break end
                    stdin_buffer = stdin_buffer .. do_syscall("read")
                end
            elseif fmt == "a" then
                while true do
                    local r = do_syscall("read")
                    if r == nil then break end
                    stdin_buffer = stdin_buffer .. do_syscall("read")
                end
            elseif fmt == "l" or fmt == "L" then
                while not stdin_buffer:find("\n") do
                    local r = do_syscall("read")
                    if r == nil then break end
                    stdin_buffer = stdin_buffer .. do_syscall("read")
                end
            else error("bad argument (invalid format '" .. fmt .. "')", 2) end
        else error("bad argument (expected string or number, got " .. type(fmt), 2) end
        if type(fmt) == "number" then s, e = stdin_buffer:sub(1, fmt), fmt + 1
        elseif fmt == "n" then s, e = stdin_buffer:match("(%d)()")
        elseif fmt == "a" then s, e = stdin_buffer, #stdin_buffer + 1
        elseif fmt == "l" then s, e = stdin_buffer:match("(.*)\n()")
        else s, e = stdin_buffer:match("(.*\n)()") end
        stdin_buffer = stdin_buffer:sub(e)
        if select("#", ...) > 0 then return s, self:read(...)
        else return s end
    end,
    seek = function() return nil, "Cannot seek default file" end,
    setvbuf = function() end
}
local io_stdout = {
    close = function() end,
    flush = function() end,
    seek = function() return nil, "Cannot seek default file" end,
    setvbuf = function() end,
    write = function(self, ...)
        do_syscall("write", ...)
        return self
    end
}
local io_stderr = {
    close = function() end,
    flush = function() end,
    seek = function() return nil, "Cannot seek default file" end,
    setvbuf = function() end,
    write = function(self, ...)
        do_syscall("writeerr", ...)
        return self
    end
}
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
    popen = function(path, mode)
        -- TODO
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
        -- TODO: make `wait` work
        local pid = do_syscall("exec", "/bin/sh", "-c", path)
        return do_syscall("wait", pid)
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
        else return oldos.epoch "utc" end
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

G.debug = debug -- since debug is protected, we can pretty much just stick it in here and be alright

-- This adds the coroutine library to coroutine types, and allows calling coroutines to resume
-- ex: while coro:status() == "suspended" do coro("hello") end
-- This should be a thing in base Lua, but since not we'll make it available system-wide!
-- Programs can rely on this behavior existing (even though it may be unavailable if debug is disabled, but CC:T 1.96 removes the ability to disable it anyway)
if debug then debug.setmetatable(coroutine.running(), {__index = G.coroutine, __call = coroutine.resume}) end

-- Protect all global functions from debug
for _,v in pairs(G) do
    if type(v) == "function" then debug.protect(v)
    elseif type(v) == "table" then
        for _,w in pairs(v) do if type(w) == "function" then debug.protect(w) end end
        setmetatable(v, {__newindex = function() end, __metatable = {}})
    end
end