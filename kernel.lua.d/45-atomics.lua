local nextMutexID = 0

function syscalls.lockmutex(process, thread, mtx)
    expect(1, mtx, "table")
    while mtx.owner ~= nil and mtx.owner ~= thread.id do coroutine.yield() end
    if mtx.owner then
        if type(mtx.recursive) == "number" then
            mtx.recursive = mtx.recursive + 1
            return
        else error("cannot recursively lock mutex", 0) end
    end
    mtx.owner = thread.id
    if mtx.recursive then mtx.recursive = 1 end
end

function syscalls.__timeout_check(process, thread, info)
    if info.timeout then return false end
    return syscalls[info.call](process, thread, info.object, 0)
end

function syscalls.timelockmutex(process, thread, mtx, timeout)
    expect(1, mtx, "table")
    expect(2, timeout, "number")
    if mtx.owner then
        if mtx.owner ~= thread.id then
            local timer = os.startTimer(timeout)
            local info = {object = mtx, timeout = false, call = "timelockmutex"}
            thread.filter = function(process, thread, ev)
                if ev[1] == "timer" and ev[2].id == timer then
                    info.timeout = true
                    return true
                end
                return mtx.owner == nil or mtx.owner == thread.id
            end
            return kSyscallYield, "__timeout_check", info
        elseif type(mtx.recursive) == "number" then
            mtx.recursive = mtx.recursive + 1
        else error("cannot recursively lock mutex", 0) end
    else
        mtx.owner = thread.id
        if mtx.recursive then mtx.recursive = 1 end
    end
    return true
end

function syscalls.unlockmutex(process, thread, mtx)
    expect(1, mtx, "table")
    if mtx.owner == thread.id then
        if type(mtx.recursive) == "number" then
            mtx.recursive = mtx.recursive - 1
            if mtx.recursive <= 0 then mtx.owner = nil end
        else mtx.owner = nil end
    elseif mtx.owner == nil then error("mutex already unlocked", 0)
    else error("mutex not locked by current thread") end
end

function syscalls.trylockmutex(process, thread, mtx)
    expect(1, mtx, "table")
    if mtx.owner then
        if mtx.owner ~= process.id then
            return false
        elseif type(mtx.recursive) == "number" then
            mtx.recursive = mtx.recursive + 1
            return true
        else error("cannot recursively lock mutex", 0) end
    else
        mtx.owner = process.id
        if mtx.recursive then mtx.recursive = 1 end
        return true
    end
end

function syscalls.acquiresemaphore(process, thread, sem)
    expect(1, sem, "table")
    expect.field(sem, "count", "number")
    while sem.count <= 0 do coroutine.yield() end
    sem.count = sem.count - 1
end

function syscalls.timeacquiresemaphore(process, thread, sem, timeout)
    expect(1, sem, "table")
    expect.field(sem, "count", "number")
    expect(2, timeout, "number")
    if sem.count <= 0 then
        local timer = os.startTimer(timeout)
        local info = {object = sem, timeout = false, call = "timeacquiresemaphore"}
        thread.filter = function(process, thread, ev)
            if ev[1] == "timer" and ev[2].id == timer then
                info.timeout = true
                return true
            end
            return type(sem.count) ~= "number" or sem.count > 0
        end
        return kSyscallYield, "__timeout_check", info
    end
    sem.count = sem.count - 1
    return true
end

function syscalls.releasesemaphore(process, thread, sem)
    expect(1, sem, "table")
    expect.field(sem, "count", "number")
    sem.count = sem.count + 1
end