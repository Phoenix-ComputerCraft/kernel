-- Phoenix Kernel v0.1

args = {
    init = "/sbin/init.lua",
    root = "/root",
    rootfs = "craftos",
    preemptive = true,
    quantum = 2000
}

syscalls = {}
processes = {
    [0] = {
        name = "kernel",
        id = 0,
        user = "root",
        dir = "/",
        dependents = {}
    }
}
KERNEL = processes[0]

kSyscallYield = {}

process = {}
filesystem = {}
terminal = {}
user = {}
syslog = {}

--#region Kernel initialization

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

local function do_syscall(call, ...)
    local res = table.pack(coroutine.yield("syscall", call, ...))
    if res[1] then return table.unpack(res, 2, res.n)
    else error(res[2], 3) end
end

local function deepcopy(tab)
    if type(tab) == "table" then
        local retval = setmetatable({}, getmetatable(tab))
        for k,v in pairs(tab) do retval[deepcopy(k)] = deepcopy(v) end
        return retval
    else return tab end
end

local function split(str, sep)
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

--#endregion

--#region Filesystem implementation

--[[
    CraftOS mount metadata is stored in the following format: {
        meta = {
            type = "directory",
            owner = "root",
            permissions = {
                root = {read = true, write = true, execute = true}
            },
            worldPermissions = {read = true, write = false, execute = true}
        },
        contents = {
            home = {
                meta = {
                    type = "directory",
                    owner = "user",
                    permissions = {
                        user = {read = true, write = true, execute = true},
                        admins = {read = true, write = false, execute = true}
                    },
                    worldPermissions = {read = false, write = false, execute = false}
                },
                contents = {
                    ["info.txt"] = {
                        meta = {
                            type = "link",
                            owner = "user",
                            permissions = {
                                user = {read = true, write = true, execute = false}
                            },
                            worldPermissions = {read = false, write = false, execute = false}
                        },
                        link = "../info.txt"
                    }
                }
            },
            ["info.txt"] = {
                meta = {
                    type = "file",
                    owner = "root",
                    permissions = {
                        root = {read = true, write = true, execute = false}
                    },
                    worldPermissions = {read = true, write = false, execute = false}
                }
            }
        }
    }
]]

-- This is really unfinished. Please make this work properly.
mounts = {}
filesystems = {
    craftos = {
        meta = {
            meta = {
                type = "directory",
                owner = "root",
                permissions = {
                    root = {read = true, write = true, execute = true}
                },
                worldPermissions = {read = true, write = false, execute = true}
            },
            contents = {}
        }
    },
    tmpfs = {},
    drivefs = {}
}

local file = fs.open("/meta.ltn", "r")
if file then
    filesystems.craftos.meta = unserialize(file.readAll())
    file.close()
end

function filesystems.craftos:getmeta(user, path)
    local t = self.meta
    for _,p in ipairs(split(path, "/\\")) do
        if not t then return nil
        elseif t.meta.type ~= "directory" then error("Not a directory", 2)
        elseif t.meta.permissions[user] then if not t.meta.permissions[user].execute then error("Permission denied", 2) end
        elseif not t.meta.worldPermissions.execute then error("Permission denied", 2) end
        t = t.contents[p]
        -- TODO: handle link traversal
        --if t and t.meta.type == "link" then t = ? end
    end
    return t and t.meta
end

function filesystems.craftos:setmeta(user, path, meta)
    local t = self.meta
    for _,p in ipairs(split(path, "/\\")) do
        if t.meta.type ~= "directory" then error("Not a directory", 2)
        elseif t.meta.permissions[user] then if not t.meta.permissions[user].execute then error("Permission denied", 2) end
        elseif not t.meta.worldPermissions.execute then error("Permission denied", 2) end
        if not t.contents[p] then t.contents[p] = { -- Initialize with default directory meta if not present
            meta = {                                -- This means the directory was created on-disk but the metadata was never set
                type = "directory",                 -- We'll set it properly at the end (or something)
                owner = "root",                     -- TODO: maybe set this to the parent's permissions? (Would maybe make more sense)
                permissions = {
                    root = {read = true, write = true, execute = true}
                },
                worldPermissions = {read = true, write = false, execute = true}
            },
            contents = {}
        } end
        t = t.contents[p]
        -- TODO: handle link traversal
        --if t and t.meta.type == "link" then t = ? end
    end
    t.meta = {
        type = meta.type,
        owner = meta.owner,
        permissions = meta.permissions,
        worldPermissions = meta.worldPermissions
    }
    if meta.type ~= "directory" then t.contents = nil end
    local file = fs.open("/meta.ltn", "w")
    file.write(serialize(self.meta))
    file.close()
end

function filesystems.craftos:new(process, path, options)
    return setmetatable({
        path = path
    }, {__index = self})
end

function filesystems.craftos:open(process, path, mode)
    local ok, stat = pcall(self.stat, self, process, path)
    if not ok then return nil, stat
    elseif not stat then
        if mode:sub(1, 1) == "w" then
            local pok, pstat = pcall(self.stat, self, process, fs.getDir(path))
            if not pok then
                local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
                if not mok then return nil, err:gsub("kernel:%d: ", "") end
                pstat = self:stat(process, fs.getDir(path))
            end
            local perms = pstat.permissions[process.user] or pstat.worldPermissions
            if not perms.write then return nil, "Permission denied" end
            local meta = {
                type = "file",
                owner = process.user,
                permissions = deepcopy(pstat.permissions),
                worldPermissions = deepcopy(pstat.worldPermissions)
            }
            -- We do a swap here so it doesn't break if pstat.owner == process.user
            local t = meta.permissions[pstat.owner]
            meta.permissions[pstat.owner] = nil
            meta.permissions[process.user] = t
            self:setmeta(process.user, fs.combine(self.path, path), meta)
            return fs.open(fs.combine(self.path, path), mode)
        else return nil, "File not found" end
    elseif stat.type == "directory" then return nil, "Is a directory" end
    local perms = stat.permissions[process.user] or stat.worldPermissions
    --syslog.debug(path, mode, perms.read, perms.write, perms.execute)
    if (mode:sub(1, 1) == "r" and not perms.read) or ((mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a") and not perms.write) then return nil, "Permission denied" end
    return fs.open(fs.combine(self.path, path), mode)
end

function filesystems.craftos:list(process, path)
    local stat = self:stat(process, path)
    if not stat then return nil
    elseif stat.type ~= "directory" then error(path .. ": Not a directory", 2) end
    local perms = stat.permissions[process.user] or stat.worldPermissions
    if not perms.read then error(path .. ": Permission denied", 2) end
    return fs.list(fs.combine(self.path, path))
end

function filesystems.craftos:stat(process, path)
    local ok, attr = pcall(fs.attributes, fs.combine(self.path, path))
    if not ok or not attr then return nil end
    attr.type = attr.isDir and "directory" or "file"
    attr.special = {}
    attr.isDir = nil
    attr.modification = nil
    if attr.isReadOnly then
        -- If the file is read-only, it's from the ROM so permissions can't be set
        -- No owner
        attr.permissions = {}
        attr.worldPermissions = {read = true, write = false, execute = true}
        return attr
    end
    attr.isReadOnly = nil
    local meta = self:getmeta(process.user, fs.combine(self.path, path))
    -- The path may exist on the filesystem but have no metadata.
    if meta then
        attr.owner = meta.owner
        attr.permissions = meta.permissions
        attr.worldPermissions = meta.worldPermissions
        attr.type = meta.type or attr.type
    else
        attr.owner = "root" -- all files are root-owned by default
        attr.permissions = {
            root = {read = true, write = true, execute = true}
        }
        attr.worldPermissions = {read = true, write = false, execute = true}
    end
    return attr
end

function filesystems.craftos:remove(process, path)

end

function filesystems.craftos:rename(process, from, to)

end

function filesystems.craftos:mkdir(process, path)
    local stat = self:stat(process, path)
    if stat then
        if stat.type == "directory" then return
        else error(path .. ": File already exists", 2) end
    end
    local parts = split(path, "/\\")
    local i = #parts - 1
    while not stat and i > 0 do
        stat = self:stat(process, table.concat(parts, "/", 1, i))
        if stat then
            if stat.type == "directory" then break
            else error(path .. ": File already exists", 2) end
        end
        i=i-1
    end
    local perms = stat.permissions[process.user] or stat.worldPermissions
    if not perms.write then error(path .. ": Permission denied", 2) end
    local meta = {
        type = "directory",
        owner = process.user,
        permissions = deepcopy(stat.permissions),
        worldPermissions = deepcopy(stat.worldPermissions)
    }
    local t = meta.permissions[stat.owner]
    meta.permissions[stat.owner] = nil
    meta.permissions[process.user] = t
    i=i+1
    while i <= #parts do
        self:setmeta(process.user, fs.combine(self.path, table.concat(parts, 1, i)), deepcopy(meta))
        i=i+1
    end
    fs.makeDir(fs.combine(self.path, path))
end

function filesystems.craftos:chmod(process, path, user, mode)
    local stat = self:stat(process, path)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    local perms
    if user == nil then perms = stat.worldPermissions
    else
        perms = stat.permissions[user]
        if not perms then
            perms = deepcopy(stat.worldPermissions)
            stat.permissions[user] = perms
        end
    end
    if type(mode) == "string" then
        if mode:match "^[+-=][rwx]+$" then
            local m = mode:sub(1, 1)
            local t = {}
            for c in mode:gmatch("[rwx]") do
                if c == "r" then t.read = true
                elseif c == "w" then t.write = true
                else t.execute = true end
            end
            if m == "+" then
                if t.read then perms.read = true end
                if t.write then perms.write = true end
                if t.execute then perms.execute = true end
            elseif m == "-" then
                if t.read then perms.read = false end
                if t.write then perms.write = false end
                if t.execute then perms.execute = false end
            else
                perms.read = t.read or false
                perms.write = t.write or false
                perms.execute = t.execute or false
            end
        else
            perms.read = mode:sub(1, 1) ~= "-"
            perms.write = mode:sub(2, 2) ~= "-"
            perms.execute = mode:sub(3, 3) ~= "-"
        end
    elseif type(mode) == "number" then
        perms.read = bit32.band(mode, 4)
        perms.write = bit32.band(mode, 2)
        perms.execute = bit32.band(mode, 1)
    else
        if mode.read ~= nil then perms.read = mode.read end
        if mode.write ~= nil then perms.write = mode.write end
        if mode.execute ~= nil then perms.execute = mode.execute end
    end
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat))
end

function filesystems.craftos:chown(process, path, owner)
    local stat = self:stat(process, path)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    stat.owner = owner
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat))
end

local function getMount(process, path)
    local fullPath = split(fs.combine(path:sub(1, 1) == "/" and "" or process.dir, path), "/\\")
    if #fullPath == 0 then return mounts[""], path end
    local maxPath
    for k in pairs(mounts) do
        local ok = true
        for i,c in ipairs(split(k, "/\\")) do if fullPath[i] ~= c then ok = false break end end
        if ok and (not maxPath or #k > #maxPath) then maxPath = k end
    end
    if not maxPath then panic("Could not find mount for path " .. path .. ". Where is root?") end
    return mounts[maxPath], fs.combine(table.unpack(fullPath, #maxPath + 1, #fullPath))
end

function filesystem.open(process, path, mode)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, mode, "string")
    if not mode:match "^[rwa]b?$" then error("Invalid mode", 0) end
    local mount, p = getMount(process, path)
    return mount:open(process, p, mode)
end

function filesystem.list(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:list(process, p)
end

function filesystem.stat(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:stat(process, p)
end

function filesystem.remove(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:remove(process, p)
end

function filesystem.rename(process, from, to)
    expect(0, process, "table")
    expect(1, from, "string")
    expect(2, to, "string")
    local mountA, pA = getMount(process, from)
    local mountB, pB = getMount(process, to)
    if mountA ~= mountB then error("Attempt to rename file across two filesystems", 0) end
    return mountA:rename(process, pA, pB)
end

function filesystem.mkdir(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:mkdir(process, p)
end

function filesystem.chmod(process, path, user, mode)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, user, "string", "nil")
    expect(3, mode, "number", "string", "table")
    if type(mode) == "string" and not mode:match "^[+-=][rwx]+$" and not mode:match "^[r-][w-][x-]$" then
        error("bad argument #2 (invalid mode)", 2)
    elseif type(mode) == "table" then
        expect.field(mode, "read", "boolean", "nil")
        expect.field(mode, "write", "boolean", "nil")
        expect.field(mode, "execute", "boolean", "nil")
    end
    local mount, p = getMount(process, path)
    return mount:chmod(process, p, user, mode)
end

function filesystem.chown(process, path, user)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, user, "string")
    local mount, p = getMount(process, path)
    return mount:chown(process, p, user)
end

function filesystem.mount(process, type, src, dest, options)
    expect(0, process, "table")
    expect(1, type, "string")
    expect(2, src, "string")
    expect(3, dest, "string")
    expect(4, options, "table", "nil")

end

function filesystem.unmount(process, path)
    expect(0, process, "table")
    expect(1, path, "string")

end

function filesystem.combine(...)
    return fs.combine(...)
end

function syscalls.open(process, thread, ...) return filesystem.open(process, ...) end
function syscalls.list(process, thread, ...) return filesystem.list(process, ...) end
function syscalls.stat(process, thread, ...) return filesystem.stat(process, ...) end
function syscalls.remove(process, thread, ...) return filesystem.remove(process, ...) end
function syscalls.rename(process, thread, ...) return filesystem.rename(process, ...) end
function syscalls.mkdir(process, thread, ...) return filesystem.mkdir(process, ...) end
function syscalls.chmod(process, thread, ...) return filesystem.chmod(process, ...) end
function syscalls.chown(process, thread, ...) return filesystem.chown(process, ...) end
function syscalls.mount(process, thread, ...) return filesystem.mount(process, ...) end
function syscalls.unmount(process, thread, ...) return filesystem.unmount(process, ...) end
function syscalls.combine(process, thread, ...) return filesystem.combine(...) end

-- This syscall provides CraftOS APIs (and modules) without having to mount the entire ROM.
-- It uses the process's environment, so if the API requires other CraftOS APIs, load them
-- as globals in the process's environment first.
function syscalls.loadCraftOSAPI(process, thread, apiName)
    expect(1, apiName, "string")
    local env
    env = setmetatable({dofile = function(path)
        local file, err = fs.open(path, "rb")
        if not file then error("Could not open module: " .. err, 0) end
        local fn, err = load(file.readAll(), "@" .. path, nil, env)
        file.close()
        if not fn then error("Could not load module: " .. err, 0) end
        return fn()
    end}, {__index = process.env})
    if apiName:sub(1, 3) == "cc." then
        local path = fs.combine("rom/modules/main", apiName:gmatch("%.", "/") .. ".lua")
        if not path:match "^/?rom/modules/main/" then error("Invalid module path", 0) end
        return env.dofile(path)
    else
        if not apiName:match "^[a-z]+$" then error("Invalid API name", 0) end
        local path = fs.combine("rom/apis", apiName .. ".lua")
        local file, err = fs.open(path, "rb")
        if not file then error("Could not open module: " .. err, 0) end
        local fn, err = load(file.readAll(), "@" .. path, nil, env)
        file.close()
        if not fn then error("Could not load module: " .. err, 0) end
        fn()
        local t = {}
        for k,v in pairs(env) do if k ~= "dofile" then t[k] = v end end
        return t
    end
end

--#endregion

--#region Lua base library implementation

local G = {}
for _,v in ipairs{"assert", "error", "getfenv", "getmetatable", "ipairs", "next",
    "pairs", "pcall", "rawequal", "rawget", "rawset", "select", "setfenv",
    "setmetatable", "tonumber", "tostring", "type", "_VERSION", "xpcall"} do G[v] = _G[v] end

function G.dofile(path)

end

function G.load(chunk, name, type, env)

end

function G.loadfile(path, env, name)

end

function G.print(...)

end

G.coroutine = {}
for k,v in pairs(coroutine) do G.coroutine[k] = v end
G.string = string
G.table = table
G.math = math

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

G.io = {
    close = function(file)

    end,
    flush = function()

    end,
    input = function(file)

    end,
    lines = function(filename)

    end,
    open = function(filename, mode)

    end,
    output = function(file)

    end,
    popen = function(path, mode)

    end,
    read = function(...)

    end,
    tmpfile = function()

    end,
    type = function(obj)

    end,
    write = function(...)

    end
} -- TODO: provide stdin/out/err

-- Nicely, we're providing a real `os` implementation instead of the jumbled mess CC gives us
local oldos = os
G.os = {
    clock = function() return do_syscall("clock") end,
    date = os.date,
    difftime = function(a, b) return a - b end,
    execute = function(path)
        -- TODO
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
    elseif type(v) == "table" then for _,w in pairs(v) do if type(w) == "function" then debug.protect(w) end end end
end

--#endregion

--#region Terminal/IO support

--#endregion

--#region System logger

local syslogs = {
    default = {
        --file = filesystem.open(KERNEL, "/var/log/default.log", "a"),
        stream = {},
        --tty = {} -- console (tty0)
    }
}

local loglevels = {
    [0] = "Debug",
    "Info",
    "Notice",
    "Warning",
    "Error",
    "Critical",
    "Panic"
}

local function concat(t, sep, i, j)
    if i == j then return tostring(t[i])
    else return tostring(t[i]) .. sep .. concat(t, sep, i + 1, j) end
end

function syscalls.syslog(process, thread, options, ...)
    local args = table.pack(...)
    if type(options) == "table" then
        expect.field(options, "name", "string", "nil")
        expect.field(options, "category", "string", "nil")
        expect.field(options, "level", "number", "nil")
        expect.field(options, "time", "number", "nil")
        expect.field(options, "process", "number", "nil")
        expect.field(options, "thread", "number", "nil")
        expect.field(options, "module", "string", "nil")
        if options.level and (options.level < 0 or options.level > #loglevels) then error("bad field 'level' (level out of range)", 0) end
        options.name = options.name or "default"
        options.process = options.process or process.id
        options.thread = options.thread or (thread and thread.id)
        options.level = options.level or 1
        options.time = options.time or os.epoch "utc"
    else
        local n = args.n
        table.insert(args, 1, options)
        args.n = n + 1
        options = {process = process.id, thread = thread and thread.id, level = 1, name = "default", time = os.epoch "utc"}
    end
    local log = syslogs[options.name]
    if log == nil then error("No such log named " .. options.name, 0) end
    local message
    for i = 1, args.n do message = (i == 1 and "" or message .. " ") .. serialize(args[i]) end
    if log.file then
        log.file.writeLine(("[%s]%s %s[%d%s]%s [%s]: %s"):format(
            os.date("%b %d %X", options.time / 1000),
            options.category and " <" .. options.category .. ">" or "",
            processes[options.process] and processes[options.process].name or "(unknown)",
            options.process,
            options.thread and ":" .. options.thread or "",
            options.module and " (" .. options.module .. ")" or "",
            loglevels[options.level],
            concat(args, " ", 1, args.n)
        ))
        log.file.flush()
    end
    if log.stream then
        options.message = message
        for _,v in pairs(log.stream) do
            -- A filter consists of a series of clauses separated by semicolons
            -- Each clause consists of a name, operator, and one or more values separated by bars ('|')
            -- String values may be surrounded with double quotes to allow semicolons, bars, and leading spaces
            -- If multiple values are specified, any value matching will cause the clause to resolve to true
            -- Available operators: ==, !=/~=, =% (match), !%/~% (not match), <, <=, >=, > (numbers only)
            -- All clauses must be true for the filter to match
            -- Example: level == 3 | 4 | 5; category != filesystem; process > 0; message =% "Unexpected error"
            local ok = true
            if v.filter then
                local name, op, val = ""
                local i = 1
                local quoted, escaped = false, false
                while i < #v.filter do
                    if op == nil then
                        name, i = v.filter:match("(%a+)%s*()", i)
                        if options[name] == nil then
                            -- Report error?
                            ok = false
                            break
                        end
                        op = ""
                    elseif val == nil then
                        local o = v.filter:sub(i, i+1)
                        if o == "==" or o == "!=" or o == "=%" or o == "!%" or o == "<=" or o == ">=" then op = o
                        elseif o == "~=" then op = "!="
                        elseif o == "~%" then op = "!%"
                        elseif v.filter:sub(i, i) == '<' or v.filter:sub(i, i) == '>' then op = v.filter:sub(i, i)
                        else
                            -- Report error?
                            ok = false
                            break
                        end
                        val = ""
                    else
                        local c = v.filter:sub(i, i)
                        if quoted then
                            if c == quoted and not escaped then
                                quoted, escaped = false, false
                            else
                                val = val .. c
                                if not escaped and c == '\\' then escaped = true
                                else escaped = false end
                            end
                        elseif c == '"' or c == "'" then
                            quoted = c
                        elseif c == '|' or c == ';' then
                            -- Evaluate the current expression
                            if (op == "==" and options[name] == val) or
                               (op == "!=" and options[name] ~= val) or
                               (op == "=%" and options[name]:match(val)) or
                               (op == "!%" and not options[name]:match(val)) or
                               (op == "<" and (tonumber(options[name]) or 0) < (tonumber(val) or 0)) or
                               (op == "<=" and (tonumber(options[name]) or 0) <= (tonumber(val) or 0)) or
                               (op == ">=" and (tonumber(options[name]) or 0) >= (tonumber(val) or 0)) or
                               (op == ">" and (tonumber(options[name]) or 0) > (tonumber(val) or 0)) then
                                if c == '|' then
                                    i = v.filter:match("[^;]*;+()", i)
                                    if i == nil then break end
                                    i=i-1 -- increment gets hit before looping
                                end
                                name, op, val = ""
                                quoted, escaped = false, false
                            else
                                ok = c == '|'
                                val = ""
                                if not ok then break end
                            end
                        elseif not (c == ' ' and val == "") then
                            val = val .. c
                        end
                        i=i+1
                    end
                end
                if quoted then
                    -- Report error?
                    ok = false
                    break
                end
            end
            if ok then
                process.queueEvent(v.pid, "syslog", v.id, options)
            end
        end
    end
    if log.tty and log.tty_level <= options.level then
        -- Do terminal writing (TODO)
        --log.tty.write(message)
    end
end

function syscalls.mklog(process, thread, name, streamed, path)
    if process.user ~= "root" then error("Permission denied", 0) end
    expect(1, name, "string")
    expect(2, streamed, "boolean", "nil")
    expect(3, path, "string", "nil")
    if syslogs[name] then error("Log already exists", 0) end
    syslogs[name] = {}
    if path then
        local err
        syslogs[name].file, err = filesystem.open(process, path, "a")
        if syslogs[name].file == nil then
            syslogs[name] = nil
            return error("Could not open log file: " .. err, 0)
        end
    end
    if streamed then syslogs[name].stream = {} end
end

function syscalls.rmlog(process, thread, name)
    if process.user ~= "root" then error("Permission denied", 0) end
    expect(1, name, "string")
    if name == "default" then error("Cannot delete default log", 0) end
    if not syslogs[name] then error("Log does not exist", 0) end
    if syslogs[name].stream then for _,v in pairs(syslogs[name].stream) do
        process.queueEvent(v.pid, "syslog_close", v.id)
        processes[v.pid].dependents[v.id] = nil
    end end
    syslogs[name] = nil
end

function syscalls.openlog(process, thread, name, filter)
    expect(1, name, "string")
    expect(2, filter, "string", "nil")
    if not syslogs[name] then error("Log does not exist", 0) end
    if not syslogs[name].stream then error("Log does not have streaming enabled", 0) end
    local id = #process.dependents+1
    local pid = process.pid
    process.dependents[id] = {type = "log", name = name, filter = filter, gc = function()
        for i,v in pairs(syslogs[name].stream) do
            if v.id == id and v.pid == pid then
                syslogs[name].stream[i] = nil
            end
        end
    end}
    syslogs[name].stream[#syslogs[name].stream+1] = {pid = pid, id = id, filter = filter}
    return id
end

function syscalls.closelog(process, thread, name)
    expect(1, name, "string", "number")
    if type(name) == "string" then
        -- Close all logs on `name`
        if not syslogs[name] then error("Log does not exist", 0) end
        if not syslogs[name].stream then error("Log does not have streaming enabled", 0) end
        for i,v in pairs(syslogs[name].stream) do
            if v.pid == process.pid then
                process.dependents[v.id] = nil
                syslogs[name].stream[i] = nil
            end
        end
    else
        -- Close log connection with ID
        if not process.dependents[name] then error("Log connection does not exist", 0) end
        local log = syslogs[process.dependents[name].name].stream
        for i,v in pairs(log) do
            if v.pid == process.pid and v.id == name then
                process.dependents[v.id] = nil
                log[i] = nil
                break
            end
        end
    end
end

function syscalls.logtty(process, thread, name, tty, level)
    if process.user ~= "root" then error("Permission denied", 0) end
    expect(1, name, "string")
    expect(2, tty, "table", "nil")
    expect(3, level, "number", "nil")
    if not syslogs[name] then error("Log does not exist", 0) end
    syslogs[name].tty = tty
    syslogs[name].tty_level = level
    return true
end

function syslog.log(options, ...)
    return pcall(syscalls.syslog, KERNEL, nil, options, ...)
end

function syslog.debug(...)
    return pcall(syscalls.syslog, KERNEL, nil, {level = 0, process = 0}, ...)
end

local oldpanic = panic
-- This function can be called either standalone or from within xpcall.
function panic(message)
    -- TODO: Write the syslog-related version
    syslog.log({level = 5, category = "Panic"}, "Kernel panic:", message)
    return oldpanic(message)
end

syslog.log("Initialized system logger")

--#endregion

--#region Dynamic linker & path management

--#endregion

--#region Event system

--#endregion

--#region Process manager

local process_template = {
    id = 1,
    name = "init",
    user = "root",
    dependents = {
        {gc = function() end}
    },
    parent = 0,
    dir = "/",
    stdin = "tty0",
    stdout = {}, -- pipe
    stderr = "tty0",
    cputime = 0.2,
    env = {},
    syscallyield = nil,
    threads = {
        [0] = {
            id = 0,
            name = "",
            coro = coroutine.create(function() end),
            status = "starting",
            args = {"a", n = 1},
            filter = function(process, thread, event) end
        }
    }
}

local function mkenv(process)
    local env = deepcopy(G)
    if _VERSION < "Lua 5.2" then
        -- Emulate _ENV environments on Lua 5.1
        setmetatable(env, {
            __index = function(self, idx)
                if idx == "_ENV" then return getfenv(2) end
                return nil
            end,
            __newindex = function(self, idx, val)
                if idx == "_ENV" then setfenv(2, val) return end
                rawset(self, idx, val)
            end
        })
    end
    env._G = env
    return env
end

local function preempt_hook()
    coroutine.yield("preempt", "test", 7)
end

local function reap_process(process)

end

function syscalls.getpid(process, thread)
    return process.id
end

function syscalls.getppid(process, thread)
    return process.parent
end

function syscalls.clock(process, thread)
    return process.cputime
end

function syscalls.getenv(process, thread)
    return process.env
end

function syscalls.fork(process, thread, func, name, ...)
    expect(1, func, "function")
    expect(2, name, "string", "nil")
    local id = #processes + 1
    processes[id] = {
        id = id,
        name = name or process.name,
        user = process.user,
        dependents = {},
        parent = process.id,
        dir = process.dir,
        stdin = process.stdin,
        stdout = process.stdout,
        stderr = process.stderr,
        cputime = 0,
        syscallyield = nil,
        threads = {
            [0] = {
                id = 0,
                name = "<main thread>",
                coro = coroutine.create(func),
                status = "starting",
                args = table.pack(...),
                filter = nil,
            }
        }
    }
    processes[id].env = mkenv(processes[id])
    setfenv(func, processes[id].env)
    if args.preemptive then debug.sethook(processes[id].threads[0].coro, preempt_hook, "", args.quantum) end
    return id
end

function syscalls.exec(process, thread, path, ...)
    expect(1, path, "string")
    -- TODO: Check execution permissions on the file
    local file, err = filesystem.open(process, path, "rb")
    if not file then
        file, err = filesystem.open(process, path .. ".lua", "rb")
        if not file then error("Could not open file: " .. err, 0) end
    end
    local contents = file.readAll()
    file.close()
    if contents:sub(1, 2) == "#!" then
        local command = contents:sub(3, contents:find("\n") - 1)
        local args, i = {}, 0
        for s in command:gmatch "%S+" do args[i] = s i=i+1 end
        for _,v in ipairs{...} do args[i] = v i=i+1 end
        if args[0] == path then error("Recursive path detected while resolving shebang", 0) end
        local id = syscalls.exec(process, thread, args[0], table.unpack(args, 1, i - 1))
        -- TODO: set the stdin of the process to the file data
        processes[id].name = path
        return id
    else
        local func, err = load(contents, "@" .. path, "bt")
        if not func then error("Could not execute file: " .. err, 0) end
        local id = #processes + 1
        processes[id] = {
            id = id,
            name = path,
            user = process.user,
            dependents = {},
            parent = process.id,
            dir = fs.getDir(path),
            stdin = process.stdin,
            stdout = process.stdout,
            stderr = process.stderr,
            cputime = 0,
            syscallyield = nil,
            threads = {
                [0] = {
                    id = 0,
                    name = "<main thread>",
                    coro = coroutine.create(func),
                    status = "starting",
                    args = table.pack(...),
                    filter = nil,
                }
            }
        }
        processes[id].env = mkenv(processes[id])
        setfenv(func, processes[id].env)
        if args.preemptive then debug.sethook(processes[id].threads[0].coro, preempt_hook, "", args.quantum) end
        return id
    end
end

function syscalls.newthread(process, thread, func, ...)
    expect(1, func, "function")
    local id = #process.threads + 1
    process.threads[id] = {
        id = id,
        name = "<thread:" .. id .. ">",
        coro = coroutine.create(func),
        status = "starting",
        args = table.pack(...),
        filter = nil,
    }
    setfenv(func, process.env)
    if args.preemptive then debug.sethook(process.threads[id].coro, preempt_hook, "", args.quantum) end
    return id
end

function syscalls.exit(process, thread, code)

end

function syscalls.waitpid(process, thread, pid)

end

function syscalls.getpinfo(process, thread, pid)

end

--#endregion

--#region Inter-process communication

--#endregion

--#region Mutex/atomics

local nextMutexID = 0

local mutex = {}

function mutex:lock()
    return do_syscall("lockmutex", self)
end

function mutex:unlock()
    return do_syscall("unlockmutex", self)
end

function mutex:try_lock()
    return do_syscall("trylockmutex", self)
end

-- make this a library function?
function syscalls.newmutex(process, thread, recursive)
    expect(1, recursive, "boolean", "nil")
    nextMutexID = nextMutexID + 1
    return setmetatable({recursive = recursive and 0, id = nextMutexID - 1}, {__name = "mutex", __tostring = function(self) return "mutex: " .. self.id end, __index = mutex})
end

function syscalls.lockmutex(process, thread, mtx)
    expect(1, mtx, "table")
    if not getmetatable(mtx) or getmetatable(mtx).__name ~= "mutex" then error("bad argument #1 (expected mutex, got table)", 0) end
    if mtx.owner then
        if mtx.owner ~= thread.id then
            thread.filter = function(process, thread)
                return mtx.owner == nil or mtx.owner == thread.id
            end
            return kSyscallYield, "lockmutex", mtx
        elseif mtx.recursive then
            mtx.recursive = mtx.recursive + 1
        else error("cannot recursively lock mutex", 0) end
    else
        mtx.owner = thread.id
        if mtx.recursive then mtx.recursive = 1 end
    end
end

function syscalls.unlockmutex(process, thread, mtx)
    expect(1, mtx, "table")
    if not getmetatable(mtx) or getmetatable(mtx).__name ~= "mutex" then error("bad argument #1 (expected mutex, got table)", 0) end
    if mtx.owner == thread.id then
        if mtx.recursive then
            mtx.recursive = mtx.recursive - 1
            if mtx.recursive == 0 then mtx.owner = nil end
        else mtx.owner = nil end
    elseif mtx.owner == nil then error("mutex already unlocked", 0)
    else error("mutex not locked by current thread") end
end

function syscalls.trylockmutex(process, thread, mtx)
    expect(1, mtx, "table")
    if not getmetatable(mtx) or getmetatable(mtx).__name ~= "mutex" then error("bad argument #1 (expected mutex, got table)", 0) end
    if mtx.owner then
        if mtx.owner ~= process.id then
            return false
        elseif mtx.recursive then
            mtx.recursive = mtx.recursive + 1
            return true
        else error("cannot recursively lock mutex", 0) end
    else
        mtx.owner = process.id
        if mtx.recursive then mtx.recursive = 1 end
        return true
    end
end

--#endregion

--#region User support

function syscalls.getuid(process, thread)
    return process.user
end

function syscalls.setuid(process, thread, uid)

end

--#endregion

--#region Device drivers

--#endregion

--#region Kernel module loader

--#endregion

--#region Main loop execution

-- temp mount
mounts[""] = filesystems[args.rootfs]:new(KERNEL, args.root)
G.term = term
syslogs.default.file = filesystem.open(KERNEL, "/var/log/default.log", "a")
syslog.log("Starting init")

local empty_packed_table = {n = 0}
local init_ok, init_pid
if args.init then
    init_ok, init_pid = pcall(syscalls.exec, KERNEL, nil, args.init)
end
if not init_ok then
    syslog.log({level = 4, process = 0}, "Could not load init:", init_pid)
    syslog.log("Could not find provided init, trying default locations")
    for _,v in ipairs{"/sbin/init", "/etc/init", "/bin/init", "/bin/sh"} do
        syslog.log("Trying", v)
        init_ok, init_pid = pcall(syscalls.exec, KERNEL, nil, v)
        if not init_ok then syslog.log({level = 4, process = 0}, "Could not load init:", init_pid) end
        if init_ok then break end
    end
    if not init_ok then panic("No working init found") end
end
local event_queue = {front = 0, back = 0, [0] = empty_packed_table}
local allWaiting = false
local init_retval

while processes[init_pid] do
    if not allWaiting then os.queueEvent("__event_queue_back") end
    while true do
        local ev = table.pack(coroutine.yield())
        if allWaiting or ev[1] == "__event_queue_back" then break end
        event_queue[event_queue.back+1] = ev
        event_queue.back = event_queue.back + 1
    end
    local ev = event_queue[event_queue.front]
    if ev then
        --syslog.debug(event_queue.front, event_queue.back, table.unpack(ev, 1, ev.n))
        event_queue.front = event_queue.front + 1
    else ev = empty_packed_table end
    if ev[1] == "key" and ev[2] == 68 then -- F10 (TODO: get real keys API)
        term.clear()
        term.setCursorPos(1, 1)
        term.write("Entering debug console.")
        local y = 2
        local running = true
        term.setCursorPos(1, y)
        while running do
            local line = ""
            local w, h = term.getSize()
            term.write("lua> ")
            term.setCursorBlink(true)
            while true do
                local ev = {coroutine.yield()}
                if ev[1] == "char" or ev[1] == "paste" then
                    line = line .. ev[2]
                    term.write(ev[2])
                elseif ev[1] == "key" then
                    if ev[2] == 14 and #line > 0 then -- backspace
                        line = line:sub(1, -2)
                        term.setCursorPos(term.getCursorPos() - 1, y)
                        term.write(" ")
                        term.setCursorPos(term.getCursorPos() - 1, y)
                    elseif ev[2] == 28 then -- enter
                        break
                    end
                end
            end
            y = y + 1
            if y > h then
                y = y - 1
                term.scroll(1)
            end
            term.setCursorPos(1, y)
            local fn, err = load("return " .. line, "=lua", "t", setmetatable({exit = function() running = false end}, {__index = _G}))
            if not fn then fn, err = load(line, "=lua", "t", setmetatable({exit = function() running = false end}, {__index = _G})) end
            if fn then
                local res = table.pack(pcall(fn))
                if res[1] then
                    for i = 2, res.n do
                        term.write(tostring(res[i]))
                        y = y + 1
                        if y > h then
                            y = y - 1
                            term.scroll(1)
                        end
                        term.setCursorPos(1, y)
                    end
                else
                    term.setTextColor(16384)
                    term.write(res[2])
                    term.setTextColor(1)
                    y = y + 1
                    if y > h then
                        y = y - 1
                        term.scroll(1)
                    end
                    term.setCursorPos(1, y)
                end
            else
                term.setTextColor(16384)
                term.write(err)
                term.setTextColor(1)
                y = y + 1
                if y > h then
                    y = y - 1
                    term.scroll(1)
                end
                term.setCursorPos(1, y)
            end
        end
        term.setCursorBlink(false)
        term.clear()
    end
    allWaiting = true
    for pid, process in pairs(processes) do if pid ~= 0 then
        local dead = true
        for tid, thread in pairs(process.threads) do
            local args
            if thread.status == "starting" then args = thread.args
            elseif thread.status == "syscall" then args = thread.syscall_return
            elseif thread.status == "preempt" then args = empty_packed_table
            elseif thread.status == "suspended" then args = ev end
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
                    --syslog.debug("Resuming thread", tid)
                    local start = os.epoch "utc"
                    params = table.pack(coroutine.resume(thread.coro, table.unpack(args, 1, args.n)))
                    --syslog.debug("Yield", params.n, table.unpack(params, 1, params.n))
                    process.cputime = process.cputime + (os.epoch "utc" - start) / 1000
                end
                if params[2] == "syscall" then
                    --syslog.debug("Calling syscall", params[3])
                    thread.status = "syscall"
                    allWaiting = false
                    if params[3] and syscalls[params[3]] then
                        thread.syscall_return = table.pack(pcall(syscalls[params[3]], process, thread, table.unpack(params, 4, params.n)))
                        if not thread.syscall_return[1] and type(thread.syscall_return[2]) == "string" then
                            syslog.log({level = 0, category = "Syscall Failure", process = 0}, thread.syscall_return[2])
                            thread.syscall_return[2] = thread.syscall_return[2]:gsub("kernel:%d+: ", "")
                        end
                        if thread.syscall_return[2] == kSyscallYield then thread.yielding = thread.syscall_return[3] end
                    else thread.syscall_return = {false, "No such syscall", n = 2} end
                elseif params[2] == "preempt" then
                    thread.status = "preempt"
                    allWaiting = false
                elseif coroutine.status(thread.coro) == "dead" then
                    thread.status = "dead"
                    thread.return_value = params[2]
                    if not params[1] then syslog.log({level = 4, process = pid, thread = tid, category = "Application Error"}, debug.traceback(thread.coro, params[2])) end
                    -- TODO: handle reaping?
                    dead = old_dead
                else
                    --syslog.debug("Standard yield", params.n, table.unpack(params, 1, params.n))
                    --syslog.debug(debug.traceback(thread.coro))
                    thread.status = "suspended"
                end
            end
        end
        if dead and pid == init_pid then
            init_retval = process.threads[0].return_value
            processes[pid] = nil
        end
    end end
end

if init_retval ~= nil then
    term.setTextColor(16384)
    term.write(tostring(init_retval))
    term.setCursorPos(1, select(2, term.getCursorPos()) + 1)
end
panic("init program exited")

--#endregion
