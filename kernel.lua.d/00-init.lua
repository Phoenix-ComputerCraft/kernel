-- Expect is a very useful module, so it's loaded for the kernel to use even though it's a CraftOS module.
do
    local file = fs.open("/rom/modules/main/cc/expect.lua", "r")
    expect = (loadstring or load)(file.readAll(), "@/rom/modules/main/cc/expect.lua")()
    file.close()
    setmetatable(expect, {__call = function(self, ...) return self.expect(...) end})
end

-- textutils.[un]serialize is also very useful, so we load that in (but not anything else)
do
    local file = fs.open("/rom/apis/textutils.lua", "r")
    local env = setmetatable({dofile = function() return expect end}, {__index = _G}) -- We stub `dofile` here since textutils loads in expect via `dofile`
    local fn
    if loadstring and setfenv then
        fn = loadstring(file.readAll(), "@/rom/apis/textutils.lua")
        setfenv(fn, env)
    else
        fn = load(file.readAll(), "@/rom/apis/textutils.lua", "t", env)
    end
    file.close()
    fn()
    serialize, unserialize = env.serialize, env.unserialize
end

-- load is the de facto loader - loadstring will no longer be available. Since load isn't available on 5.1 (at least for strings), we shim it first.
if loadstring and setfenv then
    local old_load, old_loadstring = load, loadstring
    function load(chunk, name, mode, env)
        expect(1, chunk, "string", "function")
        expect(2, name, "string", "nil")
        expect(3, mode, "string", "nil")
        expect(4, env, "table", "nil")
        if type(chunk) == "string" then
            if chunk:sub(1, 4) == "\033Lua" then
                if mode == nil or mode:find "b" then
                    local fn, err = old_loadstring(chunk, name)
                    if fn and env then setfenv(fn, env) end
                    return fn, err
                else return nil, "attempt to load a binary chunk (mode is '" .. mode .. "')" end
            else
                if mode == nil or mode:find "t" then
                    local fn, err = old_loadstring(chunk, name)
                    if fn and env then setfenv(fn, env) end
                    return fn, err
                else return nil, "attempt to load a text chunk (mode is '" .. mode .. "')" end
            end
        else
            local fn, err = old_load(chunk, name)
            if fn then setfenv(fn, env) end
            return fn, err
        end
    end
    loadstring = nil
end

-- Remove bit and apply bit32, as this is a Lua 5.2 environment.
if bit then
    if not bit32 then
        local bit = bit
        bit32 = {
           bnot = bit.bnot,
           lshift = bit.blshift,
           rshift = bit.blogic_rshift,
           arshift = bit.brshift
        }
        function bit32.band(x, y, ...)
            expect(1, x, "number")
            expect(2, y, "number", "nil")
            if not y then return x end
            return bit32.band(bit.band(x, y), ...)
        end
        function bit32.bor(x, y, ...)
            expect(1, x, "number")
            expect(2, y, "number", "nil")
            if not y then return x end
            return bit32.bor(bit.bor(x, y), ...)
        end
        function bit32.bxor(x, y, ...)
            expect(1, x, "number")
            expect(2, y, "number", "nil")
            if not y then return x end
            return bit32.bxor(bit.bxor(x, y), ...)
        end
        function bit32.btest(...)
            return bit32.band(...) ~= 0
        end
        function bit32.extract(n, field, width)
            expect(1, n, "number")
            expect(2, field, "number")
            expect(3, width, "number", "nil");
            (expect.range or function() end)(field, 0, 31);
            (expect.range or function() end)(field + width - 1, 0, 31)
            width = width or 1
            local res = 0
            for i = field + width - 1, field, -1 do
                res = res * 2 + (bit.band(n, 2^i) / 2^i)
            end
            return res
        end
        function bit32.replace(n, v, field, width)
            expect(1, n, "number")
            expect(2, v, "number")
            expect(3, field, "number")
            expect(4, width, "number", "nil");
            (expect.range or function() end)(field, 0, 31);
            (expect.range or function() end)(field + width - 1, 0, 31)
            width = width or 1
            local mask = 2^width - 1
            return bit.bor(bit.band(n, bit.bnot(bit.blshift(mask, field))), bit.blshift(bit.band(v, mask), field))
        end
        function bit32.lrotate(x, disp)
            return bit.bor(bit.blshift(x, disp), bit.blogic_rshift(x, 32-disp))
        end
        function bit32.rrotate(x, disp)
            return bit.bor(bit.blogic_rshift(x, disp), bit.blshift(x, 32-disp))
        end
    end
    bit = nil
end

-- Early version of panic function, before log initialization finishes (this is redefined later to use syslog)
function panic(message)
    term.setBackgroundColor(32768)
    term.setTextColor(16384)
    term.setCursorBlink(false)
    local x, y = term.getCursorPos()
    x = 1
    local w, h = term.getSize()
    message = "panic: " .. (message or "unknown")
    for word in message:gmatch "%S+" do
        if x + #word >= w then
            x, y = 1, y + 1
            if y > h then
                term.scroll(1)
                y = y - 1
            end
        end
        term.setCursorPos(x, y)
        if x == 1 then term.clearLine() end
        term.write(word .. " ")
        x = x + #word + 1
    end
    x, y = 1, y + 1
    if y > h then
        term.scroll(1)
        y = y - 1
    end
    if debug then
        local traceback = debug.traceback(nil, 2)
        for line in traceback:gmatch "[^\n]+" do
            term.setCursorPos(1, y)
            term.write(line)
            y = y + 1
            if y > h then
                term.scroll(1)
                y = y - 1
            end
        end
    end
    term.setCursorPos(1, y)
    term.setTextColor(2)
    term.write("panic: We are hanging here...")
    while true do coroutine.yield() end
end

function do_syscall(call, ...)
    local res = table.pack(coroutine.yield("syscall", call, ...))
    if res[1] then return table.unpack(res, 2, res.n)
    else error(res[2], 3) end
end

function deepcopy(tab)
    if type(tab) == "table" then
        local retval = setmetatable({}, getmetatable(tab))
        for k,v in pairs(tab) do retval[deepcopy(k)] = deepcopy(v) end
        return retval
    else return tab end
end

function split(str, sep)
    local t = {}
    for match in str:gmatch("[^" .. (sep or "%s") .. "]+") do t[#t+1] = match end
    return t
end

for _,v in ipairs({...}) do
    local key, value = v:match("^([^=]+)=(.+)$")
    if key and value then
        if type(args[key]) == "boolean" then args[key] = value:lower() == "true" or value == "1"
        elseif type(args[key]) == "number" then args[key] = tonumber(value)
        else args[key] = value end
    end
end

if jit and args.preemptive then panic("Phoenix does not support preemption when running under LuaJIT. Please set preemptive to false in the kernel arguments.") end
if not debug and args.preemptive then panic("Phoenix does not support preemption without the debug API. Please set preemptive to false in the kernel arguments.") end
if not getfenv then
    if not debug then panic("Phoenix requires the debug API when running under Lua 5.2 and later.") end
    -- getfenv/setfenv replacements from https://leafo.net/guides/setfenv-in-lua52-and-above.html
    function getfenv(fn)
        local i = 1
        while true do
            local name, val = debug.getupvalue(fn, i)
            if name == "_ENV" then return val
            elseif not name then break end
            i = i + 1
        end
    end
    function setfenv(fn, env)
        local i = 1
        while true do
            local name = debug.getupvalue(fn, i)
            if name == "_ENV" then
                debug.upvaluejoin(fn, i, function() return env end, 1)
                break
            elseif not name then break end
            i = i + 1
        end
        return fn
    end
end

do
    -- dbprotect.lua - Protect your functions from the debug library
    -- By JackMacWindows
    -- Licensed under CC0, though I'd appreciate it if this notice was left in place.

    -- Simply run this file in some fashion, then call `debug.protect` to protect a function.
    -- It takes the function as the first argument, as well as a list of functions
    -- that are still allowed to access the function's properties.
    -- Once protected, access to the function's environment, locals, and upvalues is
    -- blocked from all Lua functions. A function *can not* be unprotected without
    -- restarting the Lua state.
    -- The debug library itself is protected too, so it's not possible to remove the
    -- protection layer after being installed.
    -- It's also not possible to add functions to the whitelist after protecting, so
    -- make sure everything that needs to access the function's properties are added.

    local protectedObjects
    local n_getfenv, n_setfenv, d_getfenv, getlocal, getupvalue, d_setfenv, setlocal, setupvalue, upvaluejoin =
        getfenv, setfenv, debug.getfenv, debug.getlocal, debug.getupvalue, debug.setfenv, debug.setlocal, debug.setupvalue, debug.upvaluejoin

    local error, getinfo, running, select, setmetatable, type = error, debug.getinfo, coroutine.running, select, setmetatable, type

    local function keys(t, v, ...)
        if v then t[v] = true end
        if select("#", ...) > 0 then return keys(t, ...)
        else return t end
    end

    function debug.getlocal(thread, level, loc)
        if loc == nil then loc, level, thread = level, thread, running() end
        if type(level) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[level] and not (caller and protectedObjects[level][caller.func]) then return nil end
            return getlocal(level, loc)
        elseif type(level) == "number" then
            local info = getinfo(thread, level + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then return nil end
            return getlocal(thread, level + 1, loc)
        else return getlocal(thread, level, loc) end
    end

    function debug.getupvalue(func, up)
        if type(func) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[func] and not (caller and protectedObjects[func][caller.func]) then return nil end
        end
        return getupvalue(func, up)
    end

    function debug.setlocal(thread, level, loc, value)
        if loc == nil then loc, level, thread = level, thread, running() end
        if type(level) == "number" then
            local info = getinfo(thread, level + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then error("attempt to set local of protected function", 2) end
            return setlocal(thread, level + 1, loc, value)
        else return setlocal(thread, level, loc, value) end
    end

    function debug.setupvalue(func, up, value)
        if type(func) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[func] and not (caller and protectedObjects[func][caller.func]) then error("attempt to set upvalue of protected function", 2) end
        end
        return setupvalue(func, up, value)
    end

    function _G.getfenv(f)
        if f == nil then return n_getfenv(2)
        elseif type(f) == "number" and f > 0 then
            local info = getinfo(f + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then return nil end
            return n_getfenv(f+1)
        elseif type(f) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[f] and not (caller and protectedObjects[f][caller.func]) then return nil end
        end
        return n_getfenv(f)
    end

    function _G.setfenv(f, tab)
        if type(f) == "number" then
            local info = getinfo(f + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then error("attempt to set environment of protected function", 2) end
            return n_setfenv(f+1, tab)
        elseif type(f) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[f] and not (caller and protectedObjects[f][caller.func]) then error("attempt to set environment of protected function", 2) end
        end
        return n_setfenv(f, tab)
    end

    if d_getfenv then
        function debug.getfenv(o)
            if type(o) == "function" then
                local caller = getinfo(2, "f")
                if protectedObjects[o] and not (caller and protectedObjects[o][caller.func]) then return nil end
            end
            return d_getfenv(o)
        end

        function debug.setfenv(o, tab)
            if type(o) == "function" then
                local caller = getinfo(2, "f")
                if protectedObjects[o] and not (caller and protectedObjects[o][caller.func]) then error("attempt to set environment of protected function", 2) end
            end
            return d_setfenv(o, tab)
        end
    end

    if upvaluejoin then
        function debug.upvaluejoin(f1, n1, f2, n2)
            if type(f1) == "function" and type(f2) == "function" then
                local caller = getinfo(2, "f")
                if protectedObjects[f1] and not (caller and protectedObjects[f1][caller.func]) then error("attempt to get upvalue of protected function", 2) end
                if protectedObjects[f2] and not (caller and protectedObjects[f2][caller.func]) then error("attempt to set upvalue of protected function", 2) end
            end
            return upvaluejoin(f1, n1, f2, n2)
        end
    end

    function debug.protect(func, ...)
        if type(func) ~= "function" then error("bad argument #1 (expected function, got " .. type(func) .. ")", 2) end
        protectedObjects[func] = keys(setmetatable({}, {__mode = "k"}), func, ...)
    end

    protectedObjects = keys(setmetatable({}, {__mode = "k"}),
        getfenv,
        setfenv,
        debug.getfenv,
        debug.getlocal,
        debug.getupvalue,
        debug.setfenv,
        debug.setlocal,
        debug.setupvalue,
        debug.upvaluejoin,
        debug.protect
    )
    for k,v in pairs(protectedObjects) do protectedObjects[k] = {[k] = v} end
end