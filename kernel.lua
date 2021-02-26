-- Phoenix Kernel v0.1

args = {
    init = "/sbin/init",
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
        uid = 0,
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
    expect = loadstring(file.readAll(), "@/rom/modules/main/cc/expect.lua")()
    file.close()
    setmetatable(expect, {__call = function(self, ...) return self.expect(...) end})
end

-- textutils.[un]serialize is also very useful, so we load that in (but not anything else)
do
    local file = fs.open("/rom/apis/textutils.lua", "r")
    local fn = loadstring(file.readAll(), "@/rom/apis/textutils.lua")
    file.close()
    local env = setmetatable({}, {__index = _G})
    setfenv(fn, env)
    fn()
    serialize, unserialize = env.serialize, env.unserialize
end

-- Early version of panic function, before log initialization finishes (this is redefined later to use syslog)
function panic(message)
    term.setBackgroundColor(32768)
    term.setTextColor(16384)
    term.setCursorPos(1, 1)
    term.setCursorBlink(false)
    term.clear()
    local x, y = 1, 1
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
    for match in str:match "[^" .. (sep or "%s") .. "]+" do t[#t+1] = match end
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

--#endregion

--#region Filesystem implementation

mounts = {}
filesystems = {
    craftos = {
        meta = (function()
            local file = fs.open("/meta.ltn")
            if not file then return end
            local meta = unserialize(file.readAll())
            file.close()
            return meta
        end)() or {},
        new = function(self, process, path, options)
            return setmetatable({
                path = path
            }, {__index = self})
        end
    },
    tmpfs = {

    },
    drivefs = {

    }
}

local function getMount(process, path)
    local fullPath = split(fs.combine(path:sub(1, 1) == "/" and "" or process.dir, path))
    local maxPath
    for k in pairs(mounts) do
        local ok = true
        for i,c in ipairs(k) do if fullPath[i] ~= c then ok = false break end end
        if ok and (not maxPath or #k > #maxPath) then maxPath = k end
    end
    if not maxPath then panic("Could not find mount for path " .. path .. ". Where is root?") end
    return mounts[maxPath], fs.combine(table.unpack(fullPath, #maxPath + 1, #fullPath))
end

function syscalls.open(process, thread, path, mode)
    expect(1, path, "string")
    expect(2, mode, "string")
    if not mode:match "^[rwa]b?$" then error("Invalid mode", 0) end
    local mount, p = getMount(process, path)
    return mount:open(process, p, mode)
end

function syscalls.list(process, thread, path)
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:list(process, p)
end

function syscalls.stat(process, thread, path)
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:stat(process, p)
end

function syscalls.remove(process, thread, path)
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:remove(process, p)
end

function syscalls.rename(process, thread, from, to)
    expect(1, from, "string")
    expect(2, to, "string")
    local mountA, pA = getMount(process, from)
    local mountB, pB = getMount(process, to)
    if mountA ~= mountB then error("Attempt to rename file across two filesystems", 0) end
    return mountA:rename(process, pA, pB)
end

function syscalls.mkdir(process, thread, path)
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:mkdir(process, p)
end

function syscalls.chmod(process, thread, path, mode)
    expect(1, path, "string")
    expect(2, mode, "number")
    local mount, p = getMount(process, path)
    return mount:chmod(process, p, mode)
end

function syscalls.chown(process, thread, path, user)
    expect(1, path, "string")
    expect(2, user, "number")
    local mount, p = getMount(process, path)
    return mount:chown(process, p, user)
end

function syscalls.mount(process, thread, type, src, dest, options)
    expect(1, type, "string")
    expect(2, src, "string")
    expect(3, dest, "string")
    expect(4, options, "table", "nil")

end

function syscalls.unmount(process, thread, path)
    expect(1, path, "string")

end

function syscalls.combine(process, thread, ...)
    return fs.combine(...)
end

--#endregion

--#region Lua base library implementation

local G = {}

function G.getfenv(level)

end

function G.setfenv(level, env)

end

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
} -- Note to self: don't forget stdin/out/err!

-- Nicely, we're providing a real `os` implementation instead of whatever jumbled mess CC gives us
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

local olddebug = debug
G.debug = {

}

--#endregion

--#region Terminal/IO support

--#endregion

--#region System logger

local syslogs = {
    default = {
        file = filesystem.open(KERNEL, "/var/log/default.log", "a"),
        stream = {},
        tty = {} -- console (tty0)
    }
}

local textutils
do
    local file = fs.open("/rom/apis/textutils.lua", "r")
    local fn = loadstring(file.readAll(), "@/rom/apis/textutils.lua")
    file.close()
    setmetatable(textutils, {__index = _G})
    setfenv(fn, textutils)
    fn()
    setmetatable(textutils, nil)
end

local loglevels = {
    [0] = "Debug",
    "Info",
    "Notice",
    "Warning",
    "Error",
    "Critical",
    "Panic"
}

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
        options.level = options.level or 1
    else
        table.insert(args, 1, options)
        options = {process = process.id, level = 1, name = "default"}
    end
    local log = syslogs[options.name]
    if log == nil then error("No such log named " .. options.name, 0) end
    local message
    for i = 1, args.n do message = (i == 1 and "" or message .. " ") .. textutils.serialize(args[i]) end
    if log.file then
        log.file.writeLine(("[%s]%s %s[%d%s]%s [%s]: %s"):format(
            os.date("%b %d %X"),
            options.category and " <" .. options.category .. ">" or "",
            processes[options.process] and processes[options.process].name or "(unknown)",
            options.process,
            options.thread and ":" .. options.thread or "",
            options.module and " (" .. options.module .. ")" or "",
            loglevels[options.level]
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
    if process.uid ~= 0 then return false, "Permission denied" end
    expect(1, name, "string")
    expect(2, streamed, "boolean", "nil")
    expect(3, path, "string", "nil")
    if syslogs[name] then return false, "Log already exists" end
    syslogs[name] = {}
    if path then
        local err
        syslogs[name].file, err = filesystem.open(process, path, "a")
        if syslogs[name].file == nil then
            syslogs[name] = nil
            return false, "Could not open log file: " .. err
        end
    end
    if streamed then syslogs[name].stream = {} end
    return true
end

function syscalls.rmlog(process, thread, name)
    if process.uid ~= 0 then return false, "Permission denied" end
    expect(1, name, "string")
    if not syslogs[name] then return false, "Log does not exist" end
    if syslogs[name].stream then for _,v in pairs(syslogs[name].stream) do
        process.queueEvent(v.pid, "syslog_close", v.id)
        processes[v.pid].dependents[v.id] = nil
    end end
    syslogs[name] = nil
    return true
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
        if not syslogs[name] then return false, "Log does not exist" end
        if not syslogs[name].stream then return false, "Log does not have streaming enabled" end
        for i,v in pairs(syslogs[name].stream) do
            if v.pid == process.pid then
                process.dependents[v.id] = nil
                syslogs[name].stream[i] = nil
            end
        end
        return true
    else
        -- Close log connection with ID
        if not process.dependents[name] then return false, "Log connection does not exist" end
        local log = syslogs[process.dependents[name].name].stream
        for i,v in pairs(log) do
            if v.pid == process.pid and v.id == name then
                process.dependents[v.id] = nil
                log[i] = nil
                break
            end
        end
        return true
    end
end

function syscalls.logtty(process, thread, name, tty, level)
    if process.uid ~= 0 then return false, "Permission denied" end
    expect(1, name, "string")
    expect(2, tty, "table", "nil")
    expect(3, level, "number", "nil")
    if not syslogs[name] then return false, "Log does not exist" end
    syslogs[name].tty = tty
    syslogs[name].tty_level = level
    return true
end

function syslog.log(options, ...)
    return pcall(syscalls.syslog, KERNEL, nil, options, ...)
end

local oldpanic = panic
-- This function can be called either standalone or from within xpcall.
function panic(message)
    -- TODO: Write the syslog-related version
    return oldpanic(message)
end

--#endregion

--#region Dynamic linker & path management

--#endregion

--#region Event system

--#endregion

--#region Process manager

local process_template = {
    id = 1,
    name = "init",
    uid = 0,
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
    local env = setmetatable(deepcopy(G), {
        __index = function(self, idx)
            if idx == "_ENV" then return getfenv(2) end
            return nil
        end,
        __newindex = function(self, idx, val)
            if idx == "_ENV" then setfenv(2, val) end
            rawset(self, idx, val)
        end
    })
    env._G = env
    return env
end

local function preempt_hook()
    coroutine.yield("preempt")
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
        uid = process.uid,
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
    local file, err = filesystem.open(process, path, "rb")
    if not file then error("Could not open file: " .. err, 0) end
    local contents = file.readAll()
    file.close()
    if contents:sub(1, 2) == "#!" then
        local command = contents:sub(3, contents:find("\n") - 1)
        local args, i = {}, 0
        for s in command:gmatch "%S+" do args[i] = s i=i+1 end
        for _,v in ipairs{...} do args[i] = v i=i+1 end
        if args[0] == path then error("Recursive path detected while resolving shebang", 0) end
        local id = syscalls.exec(process, thread, args[0], table.unpack(args, 1, i - 1))
        processes[id].name = path
        return id
    else
        local func, err = load(contents, "@" .. path, "bt")
        if not func then error("Could not execute file: " .. err, 0) end
        local id = #processes + 1
        processes[id] = {
            id = id,
            name = path,
            uid = process.uid,
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
    if args.preemptive then debug.sethook(processes[id].threads[id].coro, preempt_hook, "", args.quantum) end
    return id
end

function syscalls.exit(process, thread, code)

end

function syscalls.waitpid(process, thread, pid)

end

function syscalls.getpinfo(process, thread, pid)

end

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
            return kSyscallYield, "lockmutex"
        elseif mtx.recursive then
            mtx.recursive = mtx.recursive + 1
        else error("cannot recursively lock mutex", 0) end
    else
        mtx.owner = process.id
        if mtx.recursive then mtx.recursive = 1 end
    end
end

function syscalls.unlockmutex(process, thread, mtx)
    expect(1, mtx, "table")
    if not getmetatable(mtx) or getmetatable(mtx).__name ~= "mutex" then error("bad argument #1 (expected mutex, got table)", 0) end
    if mtx.owner == process.owner then
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

end

function syscalls.setuid(process, thread, uid)

end

--#endregion

--#region Device drivers

--#endregion

--#region Kernel module loader

--#endregion

--#region Main loop execution

--#endregion
