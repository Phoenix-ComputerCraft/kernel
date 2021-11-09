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
    process.dir = dir:gsub("^([^/])", "/%1")
    return true
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
    -- Really basic for now
    -- TODO: make this do more
    if not processes[pid] then return nil
    elseif not processes[pid].isDead then return kSyscallYield, "waitpid", pid
    else
        local retval = processes[pid].threads[0].return_value
        reap_process(processes[pid])
        processes[pid] = nil
        return retval
    end
end

function syscalls.getpinfo(process, thread, pid)

end