local process_template = {
    id = 1,
    name = "init",
    user = "root",
    dependents = {
        {gc = function() end}
    },
    parent = 0,
    dir = "/",
    stdin = TTY[1],
    stdout = {}, -- pipe
    stderr = TTY[1],
    cputime = 0.2,
    systime = 0.1,
    env = {},
    syscallyield = nil,
    eventQueue = {},
    signalHandlers = {},
    paused = false,
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
    local env = createLuaLib(process)
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

--- Finishes a process's resources so it can be removed cleanly.
-- @tparam Process process The process to reap
function reap_process(process)
    -- TODO: finish this
    syslog.debug("Reaping process " .. process.id .. " (" .. process.name .. ")")
    for _, v in ipairs(process.dependents) do v:gc() end
    if process.stdin and process.stdin.isTTY and process.stdin.frontmostProcess == process then
        process.stdin.frontmostProcess = table.remove(process.stdin.processList)
        process.stdin.preBuffer = ""
    end
    if process.stdout and process.stdout.isTTY and process.stdout.frontmostProcess == process then
        process.stdout.frontmostProcess = table.remove(process.stdout.processList)
    end
    if process.stderr and process.stdout.isTTY and process.stdout.frontmostProcess == process then
        process.stdout.frontmostProcess = table.remove(process.stdout.processList)
    end
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

function syscalls.getname(process, thread)
    return process.name
end

function syscalls.getcwd(process, thread)
    return process.dir
end

function syscalls.chdir(process, thread, dir)
    expect(1, dir, "string")
    local stat = filesystem.stat(process, dir)
    if not stat or stat.type ~= "directory" then return false, "No such file or directory"
    elseif not (stat.permissions[process.user] or stat.worldPermissions).execute then return false, "Permission denied" end
    process.dir = dir:gsub("^([^/])", "/" .. process.dir .. "/%1")
    return true
end

function syscalls.fork(process, thread, func, name, ...)
    expect(1, func, "function")
    expect(2, name, "string", "nil")
    local id = #processes + 1
    local p
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
        systime = 0,
        syscallyield = nil,
        eventQueue = {},
        signalHandlers = {
            [1] = function() return coroutine.yield("syscall", "exit", 1) end,
            [2] = function() return coroutine.yield("syscall", "exit", 1) end,
            [3] = function()
                -- TODO: finalize this behavior
                coroutine.yield("syscall", "syslog", {level = "error", category = "Application Error", traceback = true}, debug.traceback("Quit"))
                return coroutine.yield("syscall", "exit", 1)
            end,
            [6] = function(err)
                -- TODO: finalize this behavior
                coroutine.yield("syscall", "syslog", {level = "error", category = "Application Error", traceback = true}, debug.traceback(err or "Aborted"))
                return coroutine.yield("syscall", "exit", 1)
            end,
            [13] = function() return coroutine.yield("syscall", "exit", 1) end,
            [15] = function() return coroutine.yield("syscall", "exit", 1) end,
            [19] = function() p.paused = true end,
            [21] = function() p.paused = true end,
            [22] = function() p.paused = true end,
        },
        paused = false,
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
    p = processes[id]
    processes[id].env = mkenv(processes[id])
    setfenv(func, processes[id].env)
    if process.stdin and process.stdin.isTTY then
        process.stdin.processList[#process.stdin.processList+1] = process.stdin.frontmostProcess
        process.stdin.frontmostProcess = processes[id]
        process.stdin.preBuffer = ""
    end
    if process.stdout and process.stdout.isTTY and process.stdout.frontmostProcess ~= processes[id] then
        process.stdout.processList[#process.stdout.processList+1] = process.stdout.frontmostProcess
        process.stdout.frontmostProcess = processes[id]
    end
    if process.stderr and process.stderr.isTTY and process.stderr.frontmostProcess ~= processes[id] then
        process.stderr.processList[#process.stderr.processList+1] = process.stderr.frontmostProcess
        process.stderr.frontmostProcess = processes[id]
    end
    if args.preemptive then debug.sethook(processes[id].threads[0].coro, preempt_hook, "", args.quantum) end
    return id
end

function syscalls.exec(process, thread, path, ...)
    expect(1, path, "string")
    local file, err = filesystem.open(process, path, "rb")
    if not file then
        path = path .. ".lua"
        file, err = filesystem.open(process, path, "rb")
        if not file then error("Could not open file: " .. err, 0) end
    end
    local contents = file.readAll()
    file.close()
    local stat = filesystem.stat(process, path)
    if not (stat.permissions[stat.owner] or stat.worldPermissions).execute then error("Could not execute file: Permission denied", 0) end
    if contents:sub(1, 2) == "#!" then
        local command = contents:sub(3, contents:find("\n") - 1)
        local args, i = {}, 0
        for s in command:gmatch "%S+" do args[i] = s i=i+1 end
        for _,v in ipairs{...} do args[i] = v i=i+1 end
        if args[0] == path then error("Recursive path detected while resolving shebang", 0) end
        syscalls.exec(process, thread, args[0], table.unpack(args, 1, i - 1))
        local f = filesystem.open(process, path, "rb")
        process.stdin = {read = function(n) if n then return f.read(n) else return f.readLine() end end}
        process.name = path
    else
        local func, err = load(contents, "@" .. path, "bt")
        if not func then error("Could not execute file: " .. err, 0) end
        process.name = path
        process.threads = {
            [0] = {
                id = 0,
                name = "<main thread>",
                coro = coroutine.create(func),
                status = "starting",
                args = table.pack(...),
                filter = nil,
            }
        }
        setfenv(func, process.env)
        if args.preemptive then debug.sethook(process.threads[0].coro, preempt_hook, "", args.quantum) end
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
    -- TODO
    for _, thread in pairs(process.threads) do thread.status = "dead" end
end

function syscalls.getplist(process, thread)
    local pids = {}
    for k in pairs(processes) do pids[#pids+1] = k end
    table.sort(pids)
    return pids
end

function syscalls.getpinfo(process, thread, pid)
    expect(1, pid, "number")
    local p = processes[pid]
    if not p then return nil, "No such process" end
    local stdin, stdout, stderr
    for i, v in ipairs(TTY) do
        if p.stdin == v then stdin = i end
        if p.stdout == v then stdout = i end
        if p.stderr == v then stderr = i end
    end
    local threads = {}
    if p.threads then for i, v in pairs(p.threads) do threads[i] = {
        id = v.id,
        name = v.name,
        status = v.status,
    } end end
    return {
        id = p.id,
        name = p.name,
        user = p.user,
        parent = p.parent,
        dir = p.dir,
        stdin = stdin,
        stdout = stdout,
        stderr = stderr,
        cputime = p.cputime or 0,
        systime = p.systime or 0,
        threads = threads,
    }
end