---@class Thread
local thread_template = {
    id = 0,
    name = "",
    coro = coroutine.create(function() end),
    coroStack = {},
    status = "starting",
    args = {"a", n = 1},
    filter = function(process, thread, event) end,
    paused = false
}

---@class Process
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
    debugging = false,
    allowDebug = true,
    debugger = nil,
    breakpoints = {},
    hookf = function() end,
    env = {},
    syscallyield = nil,
    eventQueue = {},
    signalHandlers = {},
    paused = false,
    nice = 0,
    threads = {
        [0] = thread_template
    },
    globalMetatables = {},
}

local nextProcessID = 1

local function mkenv(process)
    local env = createLuaLib(process)
    if _VERSION < "Lua 5.2" then env = make_ENV(env) end
    env._G = env
    return env
end

local coyield, corunning, debugHooks = coroutine.yield, coroutine.running, debugHooks
local function preempt_hook(event, line)
    if event == "count" then coyield("preempt") end
    local h = debugHooks[corunning()]
    if h then
        if event == "count" and not h.count then return end
        return h.func(event, line)
    end
end

local process_loaders = {load}

--- Adds a loader function to the list of loaders. These are used by exec(2) to
--- load a file into a function.
---@param loader fun(chunk:string,name:string,mode:string,env:table):function|nil The loader function to add
function addProcessLoader(loader)
    table.insert(process_loaders, 1, loader)
end

--- Removes a previously added loader function.
---@param loader fun(chunk:string,name:string,mode:string,env:table):function|nil The loader function to remove
function removeProcessLoader(loader)
    for i, v in ipairs(process_loaders) do
        if v == loader then
            table.remove(process_loaders, i)
            return
        end
    end
end

--- Finishes a process's resources so it can be removed cleanly.
---@param process Process The process to reap
function reap_process(process)
    -- TODO: finish this
    syslog.debug("Reaping process " .. process.id .. " (" .. process.name .. ")")
    for _, v in ipairs(process.dependents) do v:gc() end
    if process.stdin and process.stdin.isTTY then
        if process.stdin.frontmostProcess == process then
            process.stdin.frontmostProcess = table.remove(process.stdin.processList)
            process.stdin.preBuffer = ""
            if discord and process.stdout == currentTTY and process.stdout.frontmostProcess then discord("Phoenix", "Executing " .. process.stdout.frontmostProcess.name) end
        else for i, v in ipairs(process.stdin.processList) do
            if v == process then table.remove(process.stdin.processList, i) break end
        end end
    end
    if process.stdout and process.stdout.isTTY then
        if process.stdout.frontmostProcess == process then
            process.stdout.frontmostProcess = table.remove(process.stdout.processList)
        else for i, v in ipairs(process.stdout.processList) do
            if v == process then table.remove(process.stdout.processList, i) break end
        end end
    end
    if process.stderr and process.stderr.isTTY then
        if process.stderr.frontmostProcess == process then
            process.stderr.frontmostProcess = table.remove(process.stderr.processList)
        else for i, v in ipairs(process.stderr.processList) do
            if v == process then table.remove(process.stderr.processList, i) break end
        end end
    end
end

---@param process Process
---@param thread Thread
function syscalls.getpid(process, thread)
    return process.id
end

---@param process Process
---@param thread Thread
function syscalls.getppid(process, thread)
    return process.parent
end

---@param process Process
---@param thread Thread
function syscalls.clock(process, thread)
    return process.cputime
end

---@param process Process
---@param thread Thread
function syscalls.getenv(process, thread)
    return process.vars
end

---@param process Process
---@param thread Thread
function syscalls.getfenv(process, thread)
    return process.env
end

---@param process Process
---@param thread Thread
function syscalls.getname(process, thread)
    return process.name
end

---@param process Process
---@param thread Thread
function syscalls.getcwd(process, thread)
    return process.dir
end

---@param process Process
---@param thread Thread
function syscalls.chdir(process, thread, dir)
    expect(1, dir, "string")
    local stat = filesystem.stat(process, dir)
    if not stat or stat.type ~= "directory" then return false, "No such file or directory"
    elseif not (stat.permissions[process.user] or stat.worldPermissions).execute then return false, "Permission denied" end
    process.dir = dir:gsub("^([^/])", "/" .. process.dir .. "/%1")
    return true
end

---@param process Process
---@param thread Thread
function syscalls.getuser(process, thread)
    return process.user, process.realuser
end

---@param process Process
---@param thread Thread
function syscalls.setuser(process, thread, user)
    expect(1, user, "string")
    if process.user ~= "root" then error("Permission denied") end
    process.user = user
    process.realuser = nil
end

local function makeMetatables(G)
    return {
        ["nil"] = {},
        ["boolean"] = {__unm = function() --[[TODO]] end},
        ["number"] = {},
        ["string"] = {__index = G.string},
        ["function"] = {},
        -- This adds the coroutine library to coroutine types, and allows calling coroutines to resume
        -- ex: while coro:status() == "suspended" do coro("hello") end
        -- This should be a thing in base Lua, but since not we'll make it available system-wide!
        -- Programs can rely on this behavior existing
        ["thread"] = {__index = G.coroutine, __call = G.coroutine.resume},
        ["userdata"] = {}
    }
end

---@param process Process
---@param thread Thread
function syscalls.fork(process, thread, func, name, ...)
    expect(1, func, "function")
    expect(2, name, "string", "nil")
    local id = nextProcessID
    nextProcessID = nextProcessID + 1
    processes[id] = {
        id = id,
        name = name or process.name,
        user = process.user,
        dependents = {},
        parent = process.id,
        dir = process.dir,
        env = nil,
        root = process.root,
        stdin = process.stdin,
        stdout = process.stdout,
        stderr = process.stderr,
        vars = deepcopy(process.vars),
        cputime = 0,
        systime = 0,
        debugging = false,
        allowDebug = true,
        breakpoints = {},
        hookf = preempt_hook,
        quantum = args.quantum,
        syscallyield = nil,
        eventQueue = {},
        globalMetatables = nil,
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
            [19] = function() return coroutine.yield("syscall", "suspend") end,
            [21] = function() return coroutine.yield("syscall", "suspend") end,
            [22] = function() return coroutine.yield("syscall", "suspend") end,
        },
        paused = false,
        nice = 0,
        threads = {
            [0] = {
                id = 0,
                name = "<main thread>",
                coro = coroutine.create(func),
                syscall = coroutine.create(function(...)
                    local args = table.pack(...)
                    while true do
                        args = table.pack(coroutine.yield(kSyscallComplete, xpcall(syscalls[args[1]], debug.traceback, table.unpack(args, 2, args.n))))
                    end
                end),
                status = "starting",
                args = table.pack(...),
                filter = nil,
                coroStack = nil,
                paused = false,
            }
        }
    }
    processes[id].threads[0].coroStack = {processes[id].threads[0].coro}
    processes[id].env = mkenv(processes[id])
    processes[id].globalMetatables = makeMetatables(processes[id].env)
    setfenv(func, processes[id].env)
    if process.stdin and process.stdin.isTTY and not process.stdin.isLocked then
        process.stdin.processList[#process.stdin.processList+1] = process.stdin.frontmostProcess
        process.stdin.frontmostProcess = processes[id]
        process.stdin.preBuffer = ""
        if discord and process.stdout == currentTTY then discord("Phoenix", "Executing " .. process.name) end
    end
    if process.stdout and process.stdout.isTTY and not process.stdout.isLocked and process.stdout.frontmostProcess ~= processes[id] then
        process.stdout.processList[#process.stdout.processList+1] = process.stdout.frontmostProcess
        process.stdout.frontmostProcess = processes[id]
    end
    if process.stderr and process.stderr.isTTY and not process.stderr.isLocked and process.stderr.frontmostProcess ~= processes[id] then
        process.stderr.processList[#process.stderr.processList+1] = process.stderr.frontmostProcess
        process.stderr.frontmostProcess = processes[id]
    end
    if args.preemptive then debug.sethook(processes[id].threads[0].coro, preempt_hook, "", processes[id].quantum) end
    return id
end

---@param process Process
---@param thread Thread
function syscalls.exec(process, thread, path, ...)
    expect(1, path, "string")
    local file, err = filesystem.open(process, path, "r")
    if not file then
        path = path .. ".lua"
        file, err = filesystem.open(process, path, "r")
        if not file then error("Could not open file: " .. err, 0) end
    end
    local contents = file.readAll()
    file.close()
    if contents:find("[%z\1-\31]") then
        file, err = filesystem.open(process, path, "rb")
        if not file then error("Could not open file: " .. err, 0) end
        contents = file.readAll()
        file.close()
    end
    local stat = assert(filesystem.stat(process, path))
    if not (stat.permissions[stat.owner] or stat.worldPermissions).execute then error("Could not execute file: Permission denied", 0) end
    if stat.setuser then process.realuser, process.user = process.user, stat.owner end
    if contents:sub(1, 2) == "#!" then
        local command = contents:sub(3, contents:find("\n") - 1)
        local args, i = {}, 0
        for s in command:gmatch "%S+" do args[i] = s i=i+1 end
        args[i], i = path, i + 1
        for _,v in ipairs{...} do args[i] = v i=i+1 end
        if args[0] == path then error("Recursive path detected while resolving shebang", 0) end
        syscalls.exec(process, thread, args[0], table.unpack(args, 1, i))
        process.name = "/" .. fs.combine(path:sub(1, 1) == "/" and "" or process.dir, path)
    else
        local func, err
        for _, loader in ipairs(process_loaders) do
            func, err = loader(contents, "@" .. path, "bt", process.env)
            if func then break end
        end
        if not func then error("Could not execute file: " .. err, 0) end
        process.name = "/" .. fs.combine(path:sub(1, 1) == "/" and "" or process.dir, path)
        process.threads = {
            [0] = {
                id = 0,
                name = "<main thread>",
                coro = coroutine.create(func),
                syscall = coroutine.create(function(...)
                    local args = table.pack(...)
                    while true do
                        args = table.pack(coroutine.yield(kSyscallComplete, xpcall(syscalls[args[1]], debug.traceback, table.unpack(args, 2, args.n))))
                    end
                end),
                status = "starting",
                args = table.pack(...),
                filter = nil,
            }
        }
        process.threads[0].coroStack = {process.threads[0].coro}
        if args.preemptive then debug.sethook(process.threads[0].coro, process.hookf, process.debugging and "crl" or "", process.quantum) end
    end
    if discord and process.stdin and process.stdin.isTTY and process.stdin.frontmostProcess == process then discord("Phoenix", "Executing " .. process.name) end
end

---@param process Process
---@param thread Thread
function syscalls.newthread(process, thread, func, ...)
    expect(1, func, "function")
    local id = #process.threads + 1
    process.threads[id] = {
        id = id,
        name = "<thread:" .. id .. ">",
        coro = coroutine.create(func),
        syscall = coroutine.create(function(...)
            local args = table.pack(...)
            while true do
                args = table.pack(coroutine.yield(kSyscallComplete, xpcall(syscalls[args[1]], debug.traceback, table.unpack(args, 2, args.n))))
            end
        end),
        status = "starting",
        args = table.pack(...),
        filter = nil,
        coroStack = nil,
        paused = false,
    }
    setfenv(func, process.env)
    process.threads[id].coroStack = {process.threads[id].coro}
    if args.preemptive then debug.sethook(process.threads[id].coro, process.hookf, process.debugging and "crl" or "", process.quantum) end
    return id
end

---@param process Process
---@param thread Thread
function syscalls.exit(process, thread, code)
    -- TODO
    process.lastReturnValue = {pid = process.id, thread = thread.id, value = code, n = 1, code}
    for _, thread in pairs(process.threads) do
        thread.status = "dead"
        thread.return_value = code
    end
end

---@param process Process
---@param thread Thread
function syscalls.atexit(process, thread, fn)
    expect(1, fn, "function")
    process.dependents[#process.dependents+1] = {gc = function()
        local id = syscalls.newthread(process, nil, fn)
        local i = 0
        while process.threads[id] and process.threads[id].coro:status() == "suspended" and i < 100 do
            executeThread(process, process.threads[id], {n = 0}, false, false)
            i = i + 1
        end
    end}
end

---@param process Process
---@param thread Thread
function syscalls.getplist(process, thread)
    local pids = {}
    for k in pairs(processes) do pids[#pids+1] = k end
    table.sort(pids)
    return pids
end

---@param process Process
---@param thread Thread
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
        paused = v.pause or false,
    } end end
    return {
        id = p.id,
        name = p.name,
        user = p.user,
        realuser = p.realuser,
        parent = p.parent,
        dir = p.dir,
        stdin = stdin,
        stdout = stdout,
        stderr = stderr,
        cputime = p.cputime or 0,
        systime = p.systime or 0,
        threads = threads,
        allowDebug = p.allowDebug,
        debugging = p.debugging,
    }
end

---@param process Process
---@param thread Thread
function syscalls.suspend(process, thread)
    process.paused = true
end

---@param process Process
---@param thread Thread
function syscalls.nice(process, thread, level, pid)
    expect(1, level, "number")
    expect.range(level, -20, 20)
    expect(2, pid, "number", "nil")
    if level < 0 and process.user ~= "root" then error("Permission denied", 0) end
    local target = pid and assert(processes[pid], "Invalid process ID") or process
    if target.user ~= process.user and process.user ~= "root" then error("Permission denied", 0) end
    target.nice = level
    target.quantum = args.quantum * 10^(level / -10)
    if args.preemptive then for _, t in pairs(target.threads) do debug.sethook(t.coro, preempt_hook, "", target.quantum) end end
end

---@param process Process
local function setDebugHook(process)
    local str_find, next, debug_getinfo, getCurrentThread, wakeup = string.find, next, debug.getinfo, getCurrentThread, wakeup
    local function hook(event, line)
        if event == "count" then coyield("preempt") end
        local info = debug_getinfo(2)
        local thread = getCurrentThread()
        for id, bp in next, process.breakpoints do
            if bp.type == event or (bp.type == "call" and event == "tail call") then
                local ok = bp.thread == nil or bp.thread == thread.id
                if bp.filter then
                    for k, v in next, bp.filter do
                        if info[k] ~= v then
                            ok = false
                            break
                        end
                    end
                end
                if ok then
                    bp.process.eventQueue[#bp.process.eventQueue+1] = {"debug_break", {process = process.id, thread = thread.id, breakpoint = id}}
                    wakeup(bp.process)
                    thread.paused = true
                    coyield("preempt")
                    break -- TODO: should we hit multiple breakpoints?
                end
            end
        end
        while thread.pendingExec do
            local res = table.pack(pcall(thread.pendingExec))
            res.ok = table.remove(res, 1)
            res.n = res.n - 1
            if not res.ok then res.error = res[1] end
            res.process = process.id
            res.thread = thread.id
            local eq = thread.pendingExecProcess.eventQueue
            eq[#eq+1] = {"debug_exec_result", res}
            wakeup(thread.pendingExecProcess)
            thread.pendingExec, thread.pendingExecProcess = nil
            thread.paused = true
            coyield("preempt")
        end
        local h = debugHooks[corunning()]
        if h then
            if (event == "count" and not h.count) or
                ((event == "call" or event == "tail call") and not str_find(h.mask, "c")) or
                (event == "return" and not str_find(h.mask, "r")) or
                (event == "line" and not str_find(h.mask, "l"))
                then return end
            return h.func(event, line)
        end
    end
    setfenv(hook, process.env)
    debug.protect(hook)
    process.hookf = hook
    for _, v in pairs(process.threads) do
        for _, w in ipairs(v.coroStack) do
            debug.sethook(w, hook, "clr", process.quantum)
        end
    end
end

local function unsetDebugHook(process)
    for _, v in pairs(process.threads) do
        v.paused = false
        for _, w in ipairs(v.coroStack) do
            local h = debugHooks[w]
            debug.sethook(w, preempt_hook, h and h.mask or "", process.quantum)
        end
    end
    process.hookf = preempt_hook
end

---@param process Process
---@param thread Thread
function syscalls.debug_enable(process, thread, pid, enabled)
    expect(1, pid, "number", "nil")
    expect(2, enabled, "boolean")
    local p
    if pid == process.id or pid == nil then
        p = process
        process.allowDebug = enabled
    else
        p = processes[pid]
        if not p then error("No such process") end
        if not p.allowDebug or (p.user ~= process.user and process.user ~= "root") then error("Permission denied") end
    end
    if p.debugging ~= enabled then
        if enabled then setDebugHook(p)
        else unsetDebugHook(p) end
    end
    p.debugging = enabled
    if enabled and p ~= process then
        p.debugger = process
    end
end

---@param process Process
---@param thread Thread
function syscalls.debug_break(process, thread, pid, tid)
    if pid == nil then
        if not process.debugger or not processes[process.debugger.id] then return end
        process.debugger.eventQueue[#process.debugger.eventQueue+1] = {"debug_break", {process = process.id, thread = thread.id}}
        wakeup(process.debugger)
        thread.paused = true
        return
    end
    expect(1, pid, "number")
    expect(2, tid, "number", "nil")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    if tid then
        local t = p.threads[tid]
        if not t then error("No such thread") end
        if not t.paused then process.eventQueue[#process.eventQueue+1] = {"debug_break", {process = p.id, thread = t.id}} end
        t.paused = true
    else
        for _, t in pairs(p.threads) do
            if not t.paused then process.eventQueue[#process.eventQueue+1] = {"debug_break", {process = p.id, thread = t.id}} end
            t.paused = true
        end
    end
end

---@param process Process
---@param thread Thread
function syscalls.debug_(process, thread, pid)
    expect(1, pid, "number")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
end

---@param process Process
---@param thread Thread
function syscalls.debug_continue(process, thread, pid, tid)
    expect(1, pid, "number")
    expect(2, tid, "number", "nil")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    if tid then
        local t = p.threads[tid]
        if not t then error("No such thread") end
        t.paused = false
    else
        for _, t in pairs(p.threads) do
            t.paused = false
        end
    end
end

local breakpointTypes = {call = true, ["return"] = true, line = true, error = true, resume = true, yield = true}

---@param process Process
---@param thread Thread
function syscalls.debug_setbreakpoint(process, thread, pid, tid, typ, filter)
    expect(1, pid, "number")
    expect(2, tid, "number", "nil")
    expect(3, typ, "string", "number")
    expect(4, filter, "table", "nil")
    if type(typ) ~= "number" and not breakpointTypes[typ] then error("bad argument #3 (invalid option '" .. typ .. "')") end
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    local id = #p.breakpoints+1
    p.breakpoints[id] = {process = process, thread = tid, type = typ, filter = filter}
    return id
end

---@param process Process
---@param thread Thread
function syscalls.debug_unsetbreakpoint(process, thread, pid, breakpoint)
    expect(1, pid, "number")
    expect(2, breakpoint, "number")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    p.breakpoints[breakpoint] = nil
end

---@param process Process
---@param thread Thread
function syscalls.debug_listbreakpoints(process, thread, pid)
    expect(1, pid, "number")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    local retval = {}
    for id, bp in pairs(p.breakpoints) do
        retval[id] = {
            type = bp.type,
            thread = bp.thread
        }
        if bp.filter then for k, v in pairs(bp.filter) do retval[id][k] = v end end
    end
    return retval
end

-- TODO: coroutine stack?

---@param process Process
---@param thread Thread
function syscalls.debug_getinfo(process, thread, pid, tid, level, what)
    expect(1, pid, "number")
    expect(2, tid, "number")
    expect(3, level, "number")
    expect(4, what, "string", "nil")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    local t = p.threads[tid]
    if not t then error("No such thread") end
    return debug.getinfo(t.coroStack[#t.coroStack], level, what)
end

---@param process Process
---@param thread Thread
function syscalls.debug_getlocal(process, thread, pid, tid, level, n)
    expect(1, pid, "number")
    expect(2, tid, "number")
    expect(3, level, "number")
    expect(4, n, "number")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    local t = p.threads[tid]
    if not t then error("No such thread") end
    return debug.getlocal(t.coroStack[#t.coroStack], level, n)
end

---@param process Process
---@param thread Thread
function syscalls.debug_getupvalue(process, thread, pid, tid, level, n)
    expect(1, pid, "number")
    expect(2, tid, "number")
    expect(3, level, "number")
    expect(4, n, "number")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    local t = p.threads[tid]
    if not t then error("No such thread") end
    local info = debug.getinfo(t.coroStack[#t.coroStack], level, "f")
    if not info then error("bad argument #3 (level out of range)") end
    return debug.getupvalue(info.func, n)
end

---@param process Process
---@param thread Thread
function syscalls.debug_exec(process, thread, pid, tid, fn)
    expect(1, pid, "number")
    expect(2, tid, "number")
    expect(3, fn, "function")
    local p = processes[pid]
    if not p then error("No such process") end
    if p.user ~= process.user and process.user ~= "root" then error("Permission denied") end
    if not p.debugging then error("Process does not have debugging enabled") end
    local t = p.threads[tid]
    if not t then error("No such thread") end
    if not t.paused then error("Thread is not paused") end
    setfenv(fn, p.env)
    t.pendingExec = fn
    t.pendingExecProcess = process
    t.paused = false
end
