-- Phoenix Kernel v1.0

local syscalls = {}
local processes = {
    [0] = {
        name = "kernel",
        id = 0,
        uid = 0,
        dependents = {}
    }
}
local KERNEL = processes[0]

local modules = {
    process = {},
    filesystem = {},
    terminal = {},
    user = {},
    syslog = {}
}


--#region Kernel initialization

-- Expect is a very useful module, so it's loaded for the kernel to use even though it's a CraftOS module.
local expect
do
    local file = fs.open("/rom/modules/main/cc/expect.lua", "r")
    expect = loadstring(file.readAll(), "@/rom/modules/main/cc/expect.lua")()
    file.close()
    setmetatable(expect, {__call = function(self, ...) return self.expect(...) end})
end

local function do_syscall(call, ...)
    local res = table.pack(coroutine.yield("syscall", call, ...))
    if res[1] then return table.unpack(res, 2, res.n)
    else error(res[2], 3) end
end

--#endregion

--#region Filesystem implementation

function syscalls.open(process, path, mode)

end

function syscalls.list(process, path)

end

function syscalls.stat(process, path)

end

function syscalls.remove(process, path)

end

function syscalls.rename(process, path)

end

function syscalls.mkdir(process, path)

end

function syscalls.chmod(process, path, mode)

end

function syscalls.chown(process, path, user)

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
        file = modules.filesystem.open(KERNEL, "/var/log/default.txt", "a"),
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

function syscalls.syslog(process, options, ...)
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
                modules.process.queueEvent(v.pid, "syslog", v.id, options)
            end
        end
    end
    if log.tty and log.tty_level <= options.level then
        -- Do terminal writing (TODO)
        --log.tty.write(message)
    end
end

function syscalls.mklog(process, name, streamed, path)
    if process.uid ~= 0 then return false, "Permission denied" end
    expect(1, name, "string")
    expect(2, streamed, "boolean", "nil")
    expect(3, path, "string", "nil")
    if syslogs[name] then return false, "Log already exists" end
    syslogs[name] = {}
    if path then
        local err
        syslogs[name].file, err = modules.filesystem.open(process, path, "a")
        if syslogs[name].file == nil then
            syslogs[name] = nil
            return false, "Could not open log file: " .. err
        end
    end
    if streamed then syslogs[name].stream = {} end
    return true
end

function syscalls.rmlog(process, name)
    if process.uid ~= 0 then return false, "Permission denied" end
    expect(1, name, "string")
    if not syslogs[name] then return false, "Log does not exist" end
    if syslogs[name].stream then for _,v in pairs(syslogs[name].stream) do
        modules.process.queueEvent(v.pid, "syslog_close", v.id)
        processes[v.pid].dependents[v.id] = nil
    end end
    syslogs[name] = nil
    return true
end

function syscalls.openlog(process, name, filter)
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

function syscalls.closelog(process, name)
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

function syscalls.logtty(process, name, tty, level)
    if process.uid ~= 0 then return false, "Permission denied" end
    expect(1, name, "string")
    expect(2, tty, "table", "nil")
    expect(3, level, "number", "nil")
    if not syslogs[name] then return false, "Log does not exist" end
    syslogs[name].tty = tty
    syslogs[name].tty_level = level
    return true
end

function modules.syslog.log(options, ...)
    return pcall(syscalls.syslog, KERNEL, options, ...)
end

--#endregion

--#region Dynamic linker & path management

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
    coro = coroutine.create(function() end),
    status = "starting",
    args = {"a"},
    filter = {},
    tty = "tty0",
    dir = "/",
    stdin = "tty0",
    stdout = {}, -- pipe
    stderr = "tty0",
    cputime = 0.2,
    env = {}
}

local function runloop()

end

function syscalls.getpid(process)
    return process.id
end

function syscalls.getppid(process)
    return process.parent
end

function syscalls.clock(process)
    return process.cputime
end

function syscalls.getenv(process)
    return process.env
end

function syscalls.fork(process, func, ...)

end

function syscalls.exec(process, path, ...)

end

function syscalls.exit(process, code)

end

--#endregion

--#region User support

function syscalls.getuid(process)

end

function syscalls.setuid(process, uid)

end

--#endregion

--#region Device drivers

--#endregion

--#region Kernel module loader

--#endregion

--#region Main loop execution

--#endregion
