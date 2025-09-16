--- The expect module provides error checking functions for other parts of the kernel.

expect = {}

local native_types = {["nil"] = true, boolean = true, number = true, string = true, table = true, ["function"] = true, userdata = true, thread = true}

local function funclike(v) return (type(v) == "table" and ((getmetatable(v) or {}).__call)) or type(v) == "function" end

local function check_type(msg, value, ...)
    local vt = type(value)
    local vmt
    if vt == "table" then
        local mt = getmetatable(value)
        if mt then vmt = mt.__name end
    end
    local args = table.pack(...)
    for _, typ in ipairs(args) do
        if native_types[typ] then if vt == typ then return value end
        elseif vmt == typ then return value
        elseif funclike(typ) and typ(value) then return value end
    end
    local info = debug.getinfo(2, "n")
    if info and info.name and info.name ~= "" then msg = msg .. " to '" .. info.name .. "'" end
    local types
    if #args == 1 and funclike(args[1]) then
        local _, err = args[1](value)
        error(msg .. " (" .. err .. ")", 3)
    else
        for i, v in ipairs(args) do args[i] = tostring(v) end
        if args.n == 1 then types = args[1]
        elseif args.n == 2 then types = args[1] .. " or " .. args[2]
        else types = table.concat(args, ", ", 1, args.n - 1) .. ", or " .. args[args.n] end
        error(msg .. " (expected " .. types .. ", got " .. vt .. ")", 3)
    end
end

--- Check that a numbered argument matches the expected type(s). If the type
-- doesn't match, throw an error.
-- This function supports custom types by checking the __name metaproperty.
-- Passing the result of @{expect.struct}, @{expect.array}, or @{expect.match}
-- as a type parameter will use that function as a validator.
-- @tparam number index The index of the argument to check
-- @tparam any value The value to check
-- @tparam string|function(v):boolean ... The types to check for
-- @treturn any `value`
function expect.expect(index, value, ...)
    return check_type("bad argument #" .. index, value, ...)
end

--- Check that a key in a table matches the expected type(s). If the type
-- doesn't match, throw an error.
-- This function supports custom types by checking the __name metaproperty.
-- Passing the result of @{expect.struct}, @{expect.array}, or @{expect.match}
-- as a type parameter will use that function as a validator.
-- @tparam any tbl The table (or other indexable value) to search through
-- @tparam any key The key of the table to check
-- @tparam string|function(v):boolean ... The types to check for
-- @treturn any The indexed value in the table
function expect.field(tbl, key, ...)
    local ok, str = pcall(string.format, "%q", key)
    if not ok then str = tostring(key) end
    return check_type("bad field " .. str, tbl[key], ...)
end

--- Check that a number is between the specified minimum and maximum values. If
-- the number is out of bounds, throw an error.
-- @tparam number num The number to check
-- @tparam[opt=-math.huge] number min The minimum value of the number (inclusive)
-- @tparam[opt=math.huge] number max The maximum value of the number (inclusive)
-- @treturn number `num`
function expect.range(num, min, max)
    expect.expect(1, num, "number")
    expect.expect(2, min, "number", "nil")
    expect.expect(3, max, "number", "nil")
    if max and min and max < min then error("bad argument #3 (min must be less than or equal to max)", 2) end
    if num ~= num or num < (min or -math.huge) or num > (max or math.huge) then error(("number outside of range (expected %s to be within %s and %s)"):format(num, min or -math.huge, max or math.huge), 3) end
    return num
end

setmetatable(expect, {__call = function(self, ...) return expect.expect(...) end})

--- serialization.lua

local keywords = {
    ["and"] = true,
    ["break"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["goto"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}

local function lua_serialize(val, stack, opts, level)
    if stack[val] then error("Cannot serialize recursive value", 0) end
    local tt = type(val)
    if tt == "table" then
        if not next(val) then return "{}" end
        stack[val] = true
        local res = opts.minified and "{" or "{\n"
        local num = {}
        for i, v in ipairs(val) do
            if not opts.minified then res = res .. ("    "):rep(level) end
            num[i] = true
            res = res .. lua_serialize(v, stack, opts, level + 1) .. (opts.minified and "," or ",\n")
        end
        for k, v in pairs(val) do if not num[k] then
            if not opts.minified then res = res .. ("    "):rep(level) end
            if type(k) == "string" and k:match "^[A-Za-z_][A-Za-z0-9_]*$" and not keywords[k] then res = res .. k
            else res = res .. "[" .. lua_serialize(k, stack, opts, level + 1) .. "]" end
            res = res .. (opts.minified and "=" or " = ") .. lua_serialize(v, stack, opts, level + 1) .. (opts.minified and "," or ",\n")
        end end
        if opts.minified then res = res:gsub(",$", "")
        else res = res .. ("    "):rep(level - 1) end
        stack[val] = nil
        return res .. "}"
    elseif tt == "nil" or tt == "number" or tt == "boolean" or tt == "string" then
        return ("%q"):format(val):gsub("\\\n", "\\n"):gsub("\\?[%z\1-\31\127-\255]", function(c) return ("\\%03d"):format(string.byte(c)) end)
    else
        error("Cannot serialize type " .. tt, 0)
    end
end

--- Serializes an arbitrary Lua object into a serialized Lua string.
-- @tparam any val The value to encode
-- @tparam[opt] {minified=boolean} opts Any options to specify while encoding
-- @treturn string The serialized Lua representation of the object
function serialize(val, opts)
    expect(2, opts, "table", "nil")
    return lua_serialize(val, {}, opts or {}, 1)
end

--- Parses a serialized Lua string and returns a Lua value represented by the string.
-- @tparam string str The serialized Lua string to decode
-- @treturn any The Lua value from the serialized Lua
function unserialize(str)
    expect(1, str, "string")
    return assert(load("return " .. str, "=unserialize", "t", {}))()
end

-- We need the keys API from CraftOS to be able to meaningfully decipher key constants.
do
    local file = fs.open("/rom/apis/keys.lua", "r")
    local env = setmetatable({dofile = function() return expect end}, {__index = _G})
    if _VERSION < "Lua 5.2" then env._ENV = env end
    local fn
    if loadstring and setfenv then
        fn = loadstring(file.readAll(), "@/rom/apis/keys.lua")
        setfenv(fn, env)
    else
        fn = load(file.readAll(), "@/rom/apis/keys.lua", "t", env)
    end
    file.close()
    fn()
    keys = {}
    for k,v in pairs(env) do keys[k] = v end
end

-- load is the de facto loader - loadstring will no longer be available. Since load for strings isn't available on old versions of Lua/Cobalt, we shim it if necessary.
local Cload = load
if not pcall(load, "return", "=test", "t", {}) then
    local old_load, old_loadstring, expect, setfenv = load, loadstring, expect, setfenv
    function load(chunk, name, mode, env)
        expect(1, chunk, "string", "function")
        expect(2, name, "string", "nil")
        expect(3, mode, "string", "nil")
        expect(4, env, "table", "nil")
        if type(chunk) == "string" then
            if chunk:sub(1, 4) == "\27Lua" then
                if mode == nil or mode:find "b" then
                    local fn, err = old_loadstring(chunk, name)
                    if fn and env then setfenv(fn, env) end
                    return fn, err
                else return nil, "attempt to load a binary chunk (mode is '" .. (mode or "bt") .. "')" end
            else
                if mode == nil or mode:find "t" then
                    local fn, err = old_loadstring(chunk, name)
                    if fn and env then setfenv(fn, env) end
                    return fn, err
                else return nil, "attempt to load a text chunk (mode is '" .. (mode or "bt") .. "')" end
            end
        else
            local fn, err = old_load(chunk, name)
            if fn then setfenv(fn, env) end
            return fn, err
        end
    end
end
loadstring = nil -- Make sure loadstring is always gone

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

-- Check whether the _VERSION number is correct, and fix it if it's not
if _VERSION == "Lua 5.1" and load("::a:: goto a") then
    _VERSION = "Lua 5.2"
    if load("return 1 >> 2 & 3") then
        _VERSION = "Lua 5.3"
        if load("local <const> a = 2") then _VERSION = "Lua 5.4" end
    end
end

-- Implement miscellaneous Lua 5.2 functionality if on 5.1
if _VERSION == "Lua 5.1" then
    if not table.pack then table.pack = function(...)
        local t = {...}
        t.n = select("#", ...)
        return t
    end end
    if not table.unpack then table.unpack, unpack = unpack, nil end

    local _, v = xpcall(function(m) return m end, function() end, true)
    if not v then
        local old_xpcall = xpcall
        xpcall = function(f, errh, ...)
            if select("#", ...) > 0 then
                local args = table.pack(...)
                return old_xpcall(function() return f(table.unpack(args, 1, args.n)) end, errh)
            else return old_xpcall(f, errh) end
        end
    end
end


-- Fix fs.combine on older versions to allow variable arguments
if tonumber(_HOST:match "ComputerCraft 1.(%d+)") < 95 then
    -- The verbosity here fixes some issues with the sumneko Lua LSP.
    ---@param base string
    ---@param extra string
    ---@return string
    local oldc = fs.combine
    ---@param p string
    ---@param ... string
    ---@return string
    function fs.combine(p, ...)
        if (...) ~= nil then
            return oldc(p, fs.combine(...))
        else
            return p
        end
    end
end

-- Add string.pack if it's not present
if not string.pack then
    local expect = expect.expect
    local ByteOrder = {BIG_ENDIAN = 1, LITTLE_ENDIAN = 2}
    local isint = {b = 1, B = 1, h = 1, H = 1, l = 1, L = 1, j = 1, J = 1, T = 1}
    local packoptsize_tbl = {b = 1, B = 1, x = 1, h = 2, H = 2, f = 4, j = 4, J = 4, l = 8, L = 8, T = 8, d = 8, n = 8}

    local function round(n) if n % 1 >= 0.5 then return math.ceil(n) else return math.floor(n) end end

    local function floatToRawIntBits(f)
        if f == 0 then return 0
        elseif f == -0 then return 0x80000000
        elseif f == math.huge then return 0x7F800000
        elseif f == -math.huge then return 0xFF800000 end
        local m, e = math.frexp(f)
        if e > 127 or e < -126 then error("number out of range", 3) end
        e, m = e + 126, round((math.abs(m) - 0.5) * 0x1000000)
        if m > 0x7FFFFF then e = e + 1 end
        return bit32.bor(f < 0 and 0x80000000 or 0, bit32.lshift(bit32.band(e, 0xFF), 23), bit32.band(m, 0x7FFFFF))
    end

    local function doubleToRawLongBits(f)
        if f == 0 then return 0, 0
        elseif f == -0 then return 0x80000000, 0
        elseif f == math.huge then return 0x7FF00000, 0
        elseif f == -math.huge then return 0xFFF00000, 0 end
        local m, e = math.frexp(f)
        if e > 1023 or e < -1022 then error("number out of range", 3) end
        e, m = e + 1022, round((math.abs(m) - 0.5) * 0x20000000000000)
        if m > 0xFFFFFFFFFFFFF then e = e + 1 end
        return bit32.bor(f < 0 and 0x80000000 or 0, bit32.lshift(bit32.band(e, 0x7FF), 20), bit32.band(m / 0x100000000, 0xFFFFF)), bit32.band(m, 0xFFFFFFFF)
    end

    local function intBitsToFloat(l)
        if l == 0 then return 0
        elseif l == 0x80000000 then return -0
        elseif l == 0x7F800000 then return math.huge
        elseif l == 0xFF800000 then return -math.huge end
        local m, e = bit32.band(l, 0x7FFFFF), bit32.band(bit32.rshift(l, 23), 0xFF)
        e, m = e - 126, m / 0x1000000 + 0.5
        local n = math.ldexp(m, e)
        return bit32.btest(l, 0x80000000) and -n or n
    end

    local function longBitsToDouble(lh, ll)
        if lh == 0 and ll == 0 then return 0
        elseif lh == 0x80000000 and ll == 0 then return -0
        elseif lh == 0x7FF00000 and ll == 0 then return math.huge
        elseif lh == 0xFFF00000 and ll == 0 then return -math.huge end
        local m, e = bit32.band(lh, 0xFFFFF) * 0x100000000 + bit32.band(ll, 0xFFFFFFFF), bit32.band(bit32.rshift(lh, 20), 0x7FF)
        e, m = e - 1022, m / 0x20000000000000 + 0.5
        local n = math.ldexp(m, e)
        return bit32.btest(lh, 0x80000000) and -n or n
    end

    local function packint(num, size, output, offset, alignment, endianness, signed)
        local total_size = 0
        if offset % math.min(size, alignment) ~= 0 and alignment > 1 then
            local i = 0
            while offset % math.min(size, alignment) ~= 0 and i < alignment do
                output[offset] = 0
                offset = offset + 1
                total_size = total_size + 1
                i = i + 1
            end
        end
        if endianness == ByteOrder.BIG_ENDIAN then
            local added_padding = 0
            if size > 8 then for i = 0, size - 9 do
                output[offset + i] = (signed and num >= 2^(size * 8 - 1) ~= 0) and 0xFF or 0
                added_padding = added_padding + 1
                total_size = total_size + 1
            end end
            for i = added_padding, size - 1 do
                output[offset + i] = bit32.band(bit32.rshift(num, ((size - i - 1) * 8)), 0xFF)
                total_size = total_size + 1
            end
        else
            for i = 0, math.min(size, 8) - 1 do
                output[offset + i] = num / 2^(i * 8) % 256
                total_size = total_size + 1
            end
            for i = 8, size - 1 do
                output[offset + i] = (signed and num >= 2^(size * 8 - 1) ~= 0) and 0xFF or 0
                total_size = total_size + 1
            end
        end
        return total_size
    end

    local function unpackint(str, offset, size, endianness, alignment, signed)
        local result, rsize = 0, 0
        if offset % math.min(size, alignment) ~= 0 and alignment > 1 then
            for i = 0, alignment - 1 do
                if offset % math.min(size, alignment) == 0 then break end
                offset = offset + 1
                rsize = rsize + 1
            end
        end
        for i = 0, size - 1 do
            result = result + str:byte(offset + i) * 2^((endianness == ByteOrder.BIG_ENDIAN and size - i - 1 or i) * 8)
            rsize = rsize + 1
        end
        if (signed and result >= 2^(size * 8 - 1)) then result = result - 2^(size * 8) end
        return result, rsize
    end

    local function packoptsize(opt, alignment)
        local retval = packoptsize_tbl[opt] or 0
        if (alignment > 1 and retval % alignment ~= 0) then retval = retval + (alignment - (retval % alignment)) end
        return retval
    end

    --[[
    * string.pack (fmt, v1, v2, ...)
    *
    * Returns a binary string containing the values v1, v2, etc.
    * serialized in binary form (packed) according to the format string fmt.
    ]]
    function string.pack(...)
        local fmt = expect(1, ..., "string")
        local endianness = ByteOrder.LITTLE_ENDIAN
        local alignment = 1
        local pos = 1
        local argnum = 2
        local output = {}
        local i = 1
        while i <= #fmt do
            local c = fmt:sub(i, i)
            i = i + 1
            if c == '=' or c == '<' then
                endianness = ByteOrder.LITTLE_ENDIAN
            elseif c == '>' then
                endianness = ByteOrder.BIG_ENDIAN
            elseif c == '!' then
                local size = -1
                while (i <= #fmt and fmt:sub(i, i):match("%d")) do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (math.max(size, 0) * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16 or size == 0) then error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                elseif (size == -1) then alignment = 4
                else alignment = size end
            elseif isint[c] then
                local num = expect(argnum, select(argnum, ...), "number")
                argnum = argnum + 1
                if (num >= math.pow(2, (packoptsize(c, 0) * 8 - (c:match("%l") and 1 or 0))) or
                    num < (c:match("%l") and -math.pow(2, (packoptsize(c, 0) * 8 - 1)) or 0)) then
                    error(string.format("bad argument #%d to 'pack' (integer overflow)", argnum - 1), 2)
                end
                pos = pos + packint(num, packoptsize(c, 0), output, pos, alignment, endianness, false)
            elseif c:lower() == 'i' then
                local signed = c == 'i'
                local size = -1
                while i <= #fmt and fmt:sub(i, i):match("%d") do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (math.max(size, 0) * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16 or size == 0) then
                    error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                elseif (alignment > 1 and (size ~= 1 and size ~= 2 and size ~= 4 and size ~= 8 and size ~= 16)) then
                    error("bad argument #1 to 'pack' (format asks for alignment not power of 2)", 2)
                elseif (size == -1) then size = 4 end
                local num = expect(argnum, select(argnum, ...), "number")
                argnum = argnum + 1
                if (num >= math.pow(2, (size * 8 - (c:match("%l") and 1 or 0))) or
                    num < (c:match("%l") and -math.pow(2, (size * 8 - 1)) or 0)) then
                    error(string.format("bad argument #%d to 'pack' (integer overflow)", argnum - 1), 2)
                end
                pos = pos + packint(num, size, output, pos, alignment, endianness, signed)
            elseif c == 'f' then
                local f = expect(argnum, select(argnum, ...), "number")
                argnum = argnum + 1
                local l = floatToRawIntBits(f)
                if (pos % math.min(4, alignment) ~= 0 and alignment > 1) then 
                    for j = 0, alignment - 1 do
                        if pos % math.min(4, alignment) == 0 then break end
                        output[pos] = 0
                        pos = pos + 1
                    end
                end
                for j = 0, 3 do output[pos + (endianness == ByteOrder.BIG_ENDIAN and 3 - j or j)] = bit32.band(bit32.rshift(l, (j * 8)), 0xFF) end
                pos = pos + 4
            elseif c == 'd' or c == 'n' then
                local f = expect(argnum, select(argnum, ...), "number")
                argnum = argnum + 1
                local lh, ll = doubleToRawLongBits(f)
                if (pos % math.min(8, alignment) ~= 0 and alignment > 1) then 
                    for j = 0, alignment - 1 do
                        if pos % math.min(8, alignment) == 0 then break end
                        output[pos] = 0
                        pos = pos + 1
                    end
                end
                for j = 0, 3 do output[pos + (endianness == ByteOrder.BIG_ENDIAN and 7 - j or j)] = bit32.band(bit32.rshift(ll, (j * 8)), 0xFF) end
                for j = 4, 7 do output[pos + (endianness == ByteOrder.BIG_ENDIAN and 7 - j or j)] = bit32.band(bit32.rshift(lh, ((j - 4) * 8)), 0xFF) end
                pos = pos + 8
            elseif c == 'c' then
                local size = 0
                if (i > #fmt or not fmt:sub(i, i):match("%d")) then
                    error("missing size for format option 'c'", 2)
                end
                while (i <= #fmt and fmt:sub(i, i):match("%d")) do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (pos + size < pos or pos + size > 0xFFFFFFFF) then error("bad argument #1 to 'pack' (format result too large)", 2) end
                local str = expect(argnum, select(argnum, ...), "string")
                argnum = argnum + 1
                if (#str > size) then error(string.format("bad argument #%d to 'pack' (string longer than given size)", argnum - 1), 2) end
                if size > 0 then
                    for j = 0, size - 1 do output[pos+j] = str:byte(j + 1) or 0 end
                    pos = pos + size
                end
            elseif c == 'z' then
                local str = expect(argnum, select(argnum, ...), "string")
                argnum = argnum + 1
                for b in str:gmatch "." do if (b == '\0') then error(string.format("bad argument #%d to 'pack' (string contains zeros)", argnum - 1), 2) end end
                for j = 0, #str - 1 do output[pos+j] = str:byte(j + 1) end
                output[pos + #str] = 0
                pos = pos + #str + 1
            elseif c == 's' then
                local size = 0
                while (i <= #fmt and fmt:sub(i, i):match("%d")) do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16) then
                    error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                elseif (size == 0) then size = 4 end
                local str = expect(argnum, select(argnum, ...), "string")
                argnum = argnum + 1
                if (#str >= math.pow(2, (size * 8))) then
                    error(string.format("bad argument #%d to 'pack' (string length does not fit in given size)", argnum - 1), 2)
                end
                packint(#str, size, output, pos, 1, endianness, false)
                for j = size, #str + size - 1 do output[pos+j] = str:byte(j - size + 1) or 0 end
                pos = pos + #str + size
            elseif c == 'x' then
                output[pos] = 0
                pos = pos + 1
            elseif c == 'X' then
                if (i >= #fmt) then error("invalid next option for option 'X'", 2) end
                local size = 0
                local c = fmt:sub(i, i)
                i = i + 1
                if c:lower() == 'i' then
                    while i <= #fmt and fmt:sub(i, i):match("%d") do
                        if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                        size = (size * 10) + tonumber(fmt:sub(i, i))
                        i = i + 1
                    end
                    if (size > 16 or size == 0) then
                        error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                    end
                else size = packoptsize(c, 0) end
                if (size < 1) then error("invalid next option for option 'X'", 2) end
                if (pos % math.min(size, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(size, alignment) == 0 then break end
                        output[pos] = 0
                        pos = pos + 1
                    end
                end
            elseif c ~= ' ' then error(string.format("invalid format option '%s'", c), 2) end
        end
        return string.char(table.unpack(output))
    end

    --[[
    * string.packsize (fmt)
    *
    * Returns the size of a string resulting from string.pack with the given format.
    * The format string cannot have the variable-length options 's' or 'z'.
    ]]
    function string.packsize(fmt)
        local pos = 0
        local alignment = 1
        local i = 1
        while i <= #fmt do
            local c = fmt:sub(i, i)
            i = i + 1
            if c == '!' then
                local size = 0
                while i <= #fmt and fmt:sub(i, i):match("%d") do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16) then error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                elseif (size == 0) then alignment = 4
                else alignment = size end
            elseif isint[c] then
                local size = packoptsize(c, 0)
                if (pos % math.min(size, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(size, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
                pos = pos + size
            elseif c:lower() == 'i' then
                local size = 0
                while i <= #fmt and fmt:sub(i, i):match("%d") do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16) then
                    error(string.format("integral size (%d) out of limits [1,16]", size))
                elseif (alignment > 1 and (size ~= 1 and size ~= 2 and size ~= 4 and size ~= 8 and size ~= 16)) then
                    error("bad argument #1 to 'pack' (format asks for alignment not power of 2)", 2)
                elseif (size == 0) then size = 4 end
                if (pos % math.min(size, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(size, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
                pos = pos + size
            elseif c == 'f' then
                if (pos % math.min(4, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(4, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
                pos = pos + 4
            elseif c == 'd' or c == 'n' then
                if (pos % math.min(8, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(8, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
                pos = pos + 8
            elseif c == 'c' then
                local size = 0
                if (i > #fmt or not fmt:sub(i, i):match("%d")) then
                    error("missing size for format option 'c'", 2)
                end
                while i <= #fmt and fmt:sub(i, i):match("%d") do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (pos + size < pos or pos + size > 0x7FFFFFFF) then error("bad argument #1 to 'packsize' (format result too large)", 2) end
                pos = pos + size
            elseif c == 'x' then
                pos = pos + 1
            elseif c == 'X' then
                if (i >= #fmt) then error("invalid next option for option 'X'", 2) end
                local size = 0
                local c = fmt:sub(i, i)
                i = i + 1
                if c:lower() == 'i' then
                    while i <= #fmt and fmt:sub(i, i):match("%d") do
                        if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                        size = (size * 10) + tonumber(fmt:sub(i, i))
                        i = i + 1
                    end
                    if (size > 16 or size == 0) then
                        error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                    end
                else size = packoptsize(c, 0) end
                if (size < 1) then error("invalid next option for option 'X'", 2) end
                if (pos % math.min(size, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(size, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
            elseif c == 's' or c == 'z' then error("bad argument #1 to 'packsize' (variable-length format)", 2)
            elseif c ~= ' ' and c ~= '<' and c ~= '>' and c ~= '=' then error(string.format("invalid format option '%s'", c), 2) end
        end
        return pos
    end

    --[[
    * string.unpack (fmt, s [, pos])
    *
    * Returns the values packed in string s (see string.pack) according to the format string fmt.
    * An optional pos marks where to start reading in s (default is 1).
    * After the read values, this function also returns the index of the first unread byte in s.
    ]]
    function string.unpack(fmt, str, pos)
        expect(1, fmt, "string")
        expect(2, str, "string")
        expect(3, pos, "number", "nil")
        if pos then
            if (pos < 0) then pos = #str + pos
            elseif (pos == 0) then error("bad argument #3 to 'unpack' (initial position out of string)", 2) end
            if (pos > #str or pos < 0) then error("bad argument #3 to 'unpack' (initial position out of string)", 2) end
        else pos = 1 end
        local endianness = ByteOrder.LITTLE_ENDIAN
        local alignment = 1
        local retval = {}
        local i = 1
        while i <= #fmt do
            local c = fmt:sub(i, i)
            i = i + 1
            if c == '<' or c == '=' then
                endianness = ByteOrder.LITTLE_ENDIAN
            elseif c == '>' then
                endianness = ByteOrder.BIG_ENDIAN
            elseif c == '!' then
                local size = 0
                while i <= #fmt and fmt:sub(i, i):match("%d") do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16) then
                    error(string.format("integral size (%d) out of limits [1,16]", size))
                elseif (size == 0) then alignment = 4
                else alignment = size end
            elseif isint[c] then
                if (pos + packoptsize(c, 0) > #str + 1) then error("data string too short", 2) end
                local res, ressz = unpackint(str, pos, packoptsize(c, 0), endianness, alignment, c:match("%l") ~= nil)
                retval[#retval+1] = res
                pos = pos + ressz
            elseif c:lower() == 'i' then
                local signed = c == 'i'
                local size = 0
                while (i <= #fmt and fmt:sub(i, i):match("%d")) do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16) then
                    error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                elseif (size > 8) then
                    error(string.format("%d-byte integer does not fit into Lua Integer", size), 2)
                elseif (size == 0) then size = 4 end
                if (pos + size > #str + 1) then error("data string too short", 2) end
                local res, ressz = unpackint(str, pos, size, endianness, alignment, signed)
                retval[#retval+1] = res
                pos = pos + ressz
            elseif c == 'f' then
                if (pos % math.min(4, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(4, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
                if (pos + 4 > #str + 1) then error("data string too short", 2) end
                local res = unpackint(str, pos, 4, endianness, alignment, false)
                retval[#retval+1] = intBitsToFloat(res)
                pos = pos + 4
            elseif c == 'd' or c == 'n' then
                if (pos % math.min(8, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(8, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
                if (pos + 8 > #str + 1) then error("data string too short", 2) end
                local lh, ll = 0, 0
                for j = 0, 3 do lh = bit32.bor(lh, bit32.lshift((str:byte(pos + j)), ((endianness == ByteOrder.BIG_ENDIAN and 3 - j or j) * 8))) end
                for j = 0, 3 do ll = bit32.bor(ll, bit32.lshift((str:byte(pos + j + 4)), ((endianness == ByteOrder.BIG_ENDIAN and 3 - j or j) * 8))) end
                if endianness == ByteOrder.LITTLE_ENDIAN then lh, ll = ll, lh end
                retval[#retval+1] = longBitsToDouble(lh, ll)
                pos = pos + 8
            elseif c == 'c' then
                local size = 0
                if (i > #fmt or not fmt:sub(i, i):match("%d")) then
                    error("missing size for format option 'c'", 2)
                end
                while i <= #fmt and fmt:sub(i, i):match("%d") do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)") end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (pos + size > #str + 1) then error("data string too short", 2) end
                retval[#retval+1] = str:sub(pos, pos + size - 1)
                pos = pos + size
            elseif c == 'z' then
                local size = 0
                while (str:byte(pos + size) ~= 0) do
                    size = size + 1
                    if (pos + size > #str) then error("unfinished string for format 'z'", 2) end
                end
                retval[#retval+1] = str:sub(pos, pos + size - 1)
                pos = pos + size + 1
            elseif c == 's' then
                local size = 0
                while i <= #fmt and fmt:sub(i, i):match("%d") do
                    if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                    size = (size * 10) + tonumber(fmt:sub(i, i))
                    i = i + 1
                end
                if (size > 16) then
                    error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                elseif (size == 0) then size = 4 end
                if (pos + size > #str + 1) then error("data string too short", 2) end
                local num, numsz = unpackint(str, pos, size, endianness, alignment, false)
                pos = pos + numsz
                if (pos + num > #str + 1) then error("data string too short", 2) end
                retval[#retval+1] = str:sub(pos, pos + num - 1)
                pos = pos + num
            elseif c == 'x' then
                pos = pos + 1
            elseif c == 'X' then
                if (i >= #fmt) then error("invalid next option for option 'X'", 2) end
                local size = 0
                local c = fmt:sub(i, i)
                i = i + 1
                if c:lower() == 'i' then
                    while i <= #fmt and fmt:sub(i, i):match("%d") do
                        if (size >= 0xFFFFFFFF / 10) then error("bad argument #1 to 'pack' (invalid format)", 2) end
                        size = (size * 10) + tonumber(fmt:sub(i, i))
                        i = i + 1
                    end
                    if (size > 16 or size == 0) then
                        error(string.format("integral size (%d) out of limits [1,16]", size), 2)
                    elseif (size == -1) then size = 4 end
                else size = packoptsize(c, 0) end
                if (size < 1) then error("invalid next option for option 'X'", 2) end
                if (pos % math.min(size, alignment) ~= 0 and alignment > 1) then
                    for j = 1, alignment do
                        if pos % math.min(size, alignment) == 0 then break end
                        pos = pos + 1
                    end
                end
            elseif c ~= ' ' then error(string.format("invalid format option '%s'", c), 2) end
        end
        retval[#retval+1] = pos
        return table.unpack(retval)
    end
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
    mainThread = nil
    if _HEADLESS then os.shutdown(1) end
    while true do coroutine.yield() end
end

--- Small function to execute a syscall and error if it fails.
-- @tparam string call The syscall to execute
-- @tparam any ... The arguments to pass to the syscall
-- @treturn any... The values returned from the syscall
function do_syscall(call, ...)
    local res = table.pack(coroutine.yield("syscall", call, ...))
    if res[1] then return table.unpack(res, 2, res.n)
    else error(res[2], 3) end
end

--- Copies a value. If the value is a table, copies all of its contents too.
-- @tparam any tab The value to copy
-- @treturn any The new copied value
function deepcopy(tab)
    if type(tab) == "table" then
        local retval = setmetatable({}, deepcopy(getmetatable(tab)))
        for k,v in pairs(tab) do retval[deepcopy(k)] = deepcopy(v) end
        return retval
    else return tab end
end

--- Splits a string by a separator.
-- @tparam string str The string to split
-- @tparam[opt="%s"] string sep The separator pattern to split by
-- @treturn {string} A list of items in the string
function split(str, sep)
    local t = {}
    for match in str:gmatch("[^" .. (sep or "%s") .. "]+") do t[#t+1] = match end
    return t
end

local procTime = pcall(os.epoch, "nano") and function() return os.epoch "nano" / 1000000 end or (ccemux and function() return ccemux.nanoTime() / 1000000 end or function() return os.epoch "utc" end)

local currentThread
function getCurrentThread() return currentThread end

local empty_packed_table = {n = 0}
--- Resumes a thread's coroutine, handling different yield types.
-- @tparam Process process The process that owns the thread
-- @tparam Thread thread The thread to resume
-- @tparam table ev An event to pass to the thread, if present
-- @tparam boolean dead Whether a thread in the current run cycle has died
-- @tparam boolean allWaiting Whether all previous threads were waiting for an event
-- @treturn boolean Whether this thread or a previous thread has died
-- @treturn boolean Whether all threads (including this one) are waiting for an event
function executeThread(process, thread, ev, dead, allWaiting)
    local args
    if thread.paused then return false, allWaiting end
    if thread.status == "starting" then args = thread.args
    elseif thread.status == "syscall" then args = table.pack(table.unpack(thread.syscall_return, 3, thread.syscall_return.n))
    elseif thread.status == "preempt" then args = empty_packed_table
    elseif thread.status == "suspended" then args = {ev[1], {}} for k, v in pairs(ev[2]) do args[2][k] = v end
    elseif thread.status == "paused" then return false, allWaiting end
    if thread.status ~= "dead" and (not thread.filter or thread.filter(process, thread, ev)) then
        local old_dead = dead
        dead = false
        thread.filter = nil
        local params
        if thread.yielding then
            --syslog.debug("Resuming yielded syscall")
            params = {n = thread.syscall_return.n, true, "syscall", thread.yielding, table.unpack(thread.syscall_return, 4, thread.syscall_return.n)}
            thread.yielding = nil
        else
            --syslog.debug("Resuming thread", process.id, thread.id)
            assert(process.globalMetatables, "Process " .. process.id .. " has no global metatables")
            currentThread = thread
            local old = globalMetatables
            globalMetatables = process.globalMetatables
            updateGlobalMetatables()
            local start = procTime()
            params = table.pack(coroutine.resume(thread.coro, table.unpack(args, 1, args.n)))
            --syslog.debug("Yield", params.n, table.unpack(params, 1, params.n))
            process.cputime = process.cputime + (procTime() - start) / 1000
            globalMetatables = old
            updateGlobalMetatables()
            currentThread = nil
        end
        if params[2] == "secure_syscall" then params[2] = "syscall"
        elseif params[2] == "secure_event" then params[2] = nil end
        if params[2] == "syscall" then
            --syslog.debug("Calling syscall", params[3])
            thread.status = "syscall"
            local oldAllWaiting = allWaiting
            allWaiting = false
            if params[3] and syscalls[params[3]] then
                local start = procTime()
                thread.syscall_return = table.pack(coroutine.resume(thread.syscall, params[3], process, thread, table.unpack(params, 4, params.n)))
                process.systime = process.systime + (procTime() - start) / 1000
                if thread.syscall_return[2] == kSyscallComplete then
                    if not thread.syscall_return[3] and type(thread.syscall_return[4]) == "string" then
                        syslog.log({level = "debug", category = "Syscall Failure", process = 0, module = params[3]}, thread.syscall_return[4])
                        thread.syscall_return[4] = thread.syscall_return[4]:gsub("kernel:%d+: ", "")
                    end
                    if thread.syscall_return[4] == kSyscallYield then
                        thread.yielding = thread.syscall_return[5]
                        allWaiting = oldAllWaiting
                    end
                else
                    thread.yielding = params[3]
                end
            else thread.syscall_return = {false, "No such syscall", n = 2} end
        elseif params[2] == "preempt" then
            thread.status = "preempt"
            allWaiting = false
        elseif coroutine.status(thread.coro) == "dead" then
            thread.status = "dead"
            thread.return_value = params[2]
            if params[1] then process.lastReturnValue = {pid = process.id, thread = thread.id, value = params[2], n = params.n - 1, table.unpack(params, 2, params.n)}
            else process.lastReturnValue = {pid = process.id, thread = thread.id, error = params[2], traceback = debug.traceback(thread.coro)} end
            if not params[1] then
                thread.did_error = true
                syslog.log({level = _G.args.traceback and "error" or "debug", process = process.id, thread = thread.id, category = "Application Error", traceback = true}, debug.traceback(thread.coro, params[2]))
                if params[2] and process.stderr and process.stderr.isTTY then terminal.write(process.stderr, params[2] .. "\n") end
            end
            process.threads[thread.id] = nil
            dead = old_dead
        else
            --syslog.debug("Standard yield", params.n, table.unpack(params, 1, params.n))
            --syslog.debug(debug.traceback(thread.coro))
            thread.status = "suspended"
            allWaiting = allWaiting and #process.eventQueue == 0
        end
    end
    return dead, allWaiting
end

--- The main coroutine for the computer.
mainThread = coroutine.running()

--- Executes a function in user mode from kernel code.
-- @tparam Process process The process to execute as
-- @tparam function func The function to execute
-- @tparam any ... Any parameters to pass to the function
-- @treturn boolean Whether the function returned successfully
-- @treturn any The value that the function returned.
function userModeCallback(process, func, ...)
    local id = syscalls.newthread(process, nil, func, ...)
    local thread = process.threads[id]
    thread.name = "<user mode callback>"
    while thread.status ~= "dead" do
        --syslog.log({level = "debug", process = process.id, thread = id}, debug.traceback("Waiting on user mode callback"))
        if coroutine.running() == mainThread then error("userModeCallback not called from a yieldable context", 2) end
        coroutine.yield()
    end
    --syslog.log({level = "debug", process = process.id, thread = id}, "Usermode callback completed")
    return not thread.did_error, thread.return_value
end

--- Creates a new _ENV shadow environment for a table. The resulting table can
-- have its environment set through `t._ENV = val`.
-- @tparam table env The environment table to use
-- @treturn table A new _ENV-ized table
function make_ENV(env)
    if type(env) ~= "table" or _VERSION ~= "Lua 5.1" then return env end
    repeat
        local mt = getmetatable(env)
        if mt and mt.__env then env = mt.__env end
    until not mt or not mt.__env
    local t = setmetatable({}, {
        __index = function(self, idx)
            if self == env then env = getmetatable(self).__env end -- ????????
            if idx == "_ENV" then return env
            else return env[idx] end
        end,
        __newindex = function(self, idx, val)
            if self == env then env = getmetatable(self).__env end -- ????????
            if idx == "_ENV" then env = val
            else env[idx] = val end
        end,
        __pairs = function(self)
            if self == env then env = getmetatable(self).__env end -- ????????
            return next, env
        end,
        __len = function(self)
            if self == env then env = getmetatable(self).__env end -- ????????
            return #env
        end,
        __env = env
    })
    return t
end

for _,v in ipairs({...}) do
    local key, value = v:match("^([^=]+)=(.+)$")
    if key and value then
        if type(args[key]) == "boolean" then args[key] = value:lower() == "true" or value == "1"
        elseif type(args[key]) == "number" then args[key] = tonumber(value)
        else args[key] = value end
    elseif key == "silent" then args.loglevel = 5
    elseif key == "quiet" then args.loglevel = 3
    end
end
if _HEADLESS then
    args.headless = true
end

local function minver(version)
    local res
    if _CC_VERSION then res = version <= _CC_VERSION
    elseif not _HOST then res = version <= os.version():gsub("CraftOS ", "")
    elseif _HOST:match("ComputerCraft 1%.1%d+") ~= version:match("1%.1%d+") then
      version = version:gsub("(1%.)([02-9])", "%10%2")
      local host = _HOST:gsub("(ComputerCraft 1%.)([02-9])", "%10%2")
      res = version <= host:match("ComputerCraft ([0-9%.]+)")
    else res = version <= _HOST:match("ComputerCraft ([0-9%.]+)") end
    return res
end

if not minver "1.87.0" then panic("Phoenix requires ComputerCraft 1.87.0 or later. Please upgrade your version of ComputerCraft.") end
if jit and args.preemptive then panic("Phoenix does not support preemption when running under LuaJIT. Please set preemptive to false in the kernel arguments.") end
if not debug and args.preemptive then panic("Phoenix does not support preemption without the debug API. Please set preemptive to false in the kernel arguments.") end
if args.preemptive then PHOENIX_BUILD = PHOENIX_BUILD .. " PREEMPT" end
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
elseif getfenv(function() end) == _ENV then
    local getfenv, d_getfenv, env = getfenv, debug.getfenv, _ENV
    function _G.getfenv(o)
        local e = getfenv(o)
        if e == env then
            e = nil
            local i = 1
            if type(o) == "number" then o = debug.getinfo(o).func end
            while true do
                local name, val = debug.getupvalue(o, i)
                if name == "_ENV" and val ~= env then return val
                elseif not name then break end
                i = i + 1
            end
        end
        return e
    end
    function debug.getfenv(o)
        local e = d_getfenv(o)
        if e == env then
            e = nil
            local i = 1
            if type(o) == "number" then o = debug.getinfo(o).func end
            while true do
                local name, val = debug.getupvalue(o, i)
                if name == "_ENV" and val ~= env then return val
                elseif not name then break end
                i = i + 1
            end
        end
        return e
    end
end

-- Split global metatables into process-specific metatables
globalMetatables = {
    ["nil"] = {},
    ["boolean"] = {},
    ["number"] = {},
    ["string"] = {__index = string},
    ["function"] = {},
    -- This adds the coroutine library to coroutine types, and allows calling coroutines to resume
    -- ex: while coro:status() == "suspended" do coro("hello") end
    -- This should be a thing in base Lua, but since not we'll make it available system-wide!
    -- Programs can rely on this behavior existing
    ["thread"] = {__index = coroutine, __call = coroutine.resume},
    ["userdata"] = {}
}

local debug_getmetatable, debug_setmetatable = debug.getmetatable, debug.setmetatable
function updateGlobalMetatables()
    debug_setmetatable(nil, globalMetatables["nil"])
    debug_setmetatable(false, globalMetatables["boolean"])
    debug_setmetatable(0, globalMetatables["number"])
    debug_setmetatable("", globalMetatables["string"])
    debug_setmetatable(assert, globalMetatables["function"])
    debug_setmetatable(coroutine.running(), globalMetatables["thread"])
    if debug.upvalueid then debug_setmetatable(debug.upvalueid(executeThread, 1), globalMetatables["userdata"]) end
end

local type = type
function debug.getmetatable(val)
    if type(val) == "table" then return debug_getmetatable(val)
    else return globalMetatables[type(val)] end
end
function debug.setmetatable(val, tab)
    expect(2, tab, "table")
    if type(val) == "table" then return debug_setmetatable(val, tab)
    else globalMetatables[type(val)] = tab end
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

    local error, getinfo, running, select, setmetatable, type, tonumber = error, debug.getinfo, coroutine.running, select, setmetatable, type, tonumber

    local superprotected

    local function keys(t, v, ...)
        if v then t[v] = true end
        if select("#", ...) > 0 then return keys(t, ...)
        else return t end
    end

    local function superprotect(v, ...)
        if select("#", ...) > 0 then return superprotected[v or ""] or v, superprotect(...)
        else return superprotected[v or ""] or v end
    end

    local function checkint32(n)
        n = bit32.band(tonumber(n), 0xFFFFFFFF)
        if bit32.btest(n, 0x80000000) then n = n - 0x100000000 end
        return n
    end

    function debug.getinfo(thread, func, what)
        if type(thread) ~= "thread" then what, func, thread = func, thread, running() end
        local retval
        if tonumber(func) then retval = getinfo(thread, func+1, what)
        else retval = getinfo(thread, func, what) end
        if retval and retval.func then retval.func = superprotected[retval.func] or retval.func end
        return retval
    end

    function debug.getlocal(thread, level, loc)
        if loc == nil then loc, level, thread = level, thread, running() end
        local k, v
        if type(level) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[level] and not (caller and protectedObjects[level][caller.func]) then return nil end
            k, v = superprotect(getlocal(level, loc))
        elseif tonumber(level) then
            local info = getinfo(thread, level + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then return nil end
            k, v = superprotect(getlocal(thread, level + 1, loc))
        else k, v = superprotect(getlocal(thread, level, loc)) end
        return k, v
    end

    function debug.getupvalue(func, up)
        if type(func) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[func] and not (caller and protectedObjects[func][caller.func]) then return nil end
        end
        local k, v = superprotect(getupvalue(func, up))
        return k, v
    end

    function debug.setlocal(thread, level, loc, value)
        if loc == nil then loc, level, thread = level, thread, running() end
        if tonumber(level) then
            local info = getinfo(thread, level + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then error("attempt to set local of protected function", 2) end
            setlocal(thread, level + 1, loc, value)
        else setlocal(thread, level, loc, value) end
    end

    function debug.setupvalue(func, up, value)
        if type(func) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[func] and not (caller and protectedObjects[func][caller.func]) then error("attempt to set upvalue of protected function", 2) end
        end
        setupvalue(func, up, value)
    end

    function _G.getfenv(f)
        local v
        if f == nil then v = n_getfenv(2)
        elseif tonumber(f) and checkint32(f) > 0 then
            local info = getinfo(f + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then return nil end
            v = n_getfenv(f+1)
        elseif type(f) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[f] and not (caller and protectedObjects[f][caller.func]) then return nil end
            v = n_getfenv(f)
        else v = n_getfenv(f) end
        return v
    end

    function _G.setfenv(f, tab)
        if tonumber(f) and checkint32(f) > 0 then
            local info = getinfo(f + 1, "f")
            local caller = getinfo(2, "f")
            if info and protectedObjects[info.func] and not (caller and protectedObjects[info.func][caller.func]) then error("attempt to set environment of protected function", 2) end
            n_setfenv(f+1, tab)
        elseif type(f) == "function" then
            local caller = getinfo(2, "f")
            if protectedObjects[f] and not (caller and protectedObjects[f][caller.func]) then error("attempt to set environment of protected function", 2) end
        end
        n_setfenv(f, tab)
    end

    if d_getfenv then
        function debug.getfenv(o)
            if type(o) == "function" then
                local caller = getinfo(2, "f")
                if protectedObjects[o] and not (caller and protectedObjects[o][caller.func]) then return nil end
            end
            local v = d_getfenv(o)
            return v
        end

        function debug.setfenv(o, tab)
            if type(o) == "function" then
                local caller = getinfo(2, "f")
                if protectedObjects[o] and not (caller and protectedObjects[o][caller.func]) then error("attempt to set environment of protected function", 2) end
            end
            d_setfenv(o, tab)
        end
    end

    if upvaluejoin then
        function debug.upvaluejoin(f1, n1, f2, n2)
            if type(f1) == "function" and type(f2) == "function" then
                local caller = getinfo(2, "f")
                if protectedObjects[f1] and not (caller and protectedObjects[f1][caller.func]) then error("attempt to get upvalue of protected function", 2) end
                if protectedObjects[f2] and not (caller and protectedObjects[f2][caller.func]) then error("attempt to set upvalue of protected function", 2) end
            end
            upvaluejoin(f1, n1, f2, n2)
        end
    end

    function debug.protect(func)
        if type(func) ~= "function" then error("bad argument #1 (expected function, got " .. type(func) .. ")", 2) end
        if protectedObjects[func] then error("attempt to protect a protected function", 2) end
        protectedObjects[func] = keys(setmetatable({}, {__mode = "k"}))
    end

    superprotected = {
        [getlocal] = debug.getlocal,
        [setlocal] = debug.setlocal,
        [getupvalue] = debug.getupvalue,
        [setupvalue] = debug.setupvalue,
        [getinfo] = debug.getinfo,
        [superprotect] = function() end,
        [Cload] = function() end,
    }
    if debug.upvaluejoin then superprotected[upvaluejoin] = debug.upvaluejoin end
    if debug.getfenv then superprotected[d_getfenv] = debug.getfenv end
    if debug.setfenv then superprotected[d_setfenv] = debug.setfenv end
    if _G.getfenv then superprotected[n_getfenv] = _G.getfenv end
    if _G.setfenv then superprotected[n_setfenv] = _G.setfenv end

    protectedObjects = keys(setmetatable({}, {__mode = "k"}),
        getfenv,
        setfenv,
        debug.getfenv,
        debug.setfenv,
        debug.getlocal,
        debug.setlocal,
        debug.getupvalue,
        debug.setupvalue,
        debug.upvaluejoin,
        debug.getinfo,
        superprotect,
        debug.protect
    )
    for k,v in pairs(protectedObjects) do protectedObjects[k] = {} end
end

debug.protect(_G.load)
if _G.load ~= Cload then debug.protect(Cload) end
debug.protect(debug.getmetatable)
debug.protect(debug.setmetatable)
