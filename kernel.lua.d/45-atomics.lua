local nextMutexID = 0

local mutex = {}
local do_syscall = do_syscall

function mutex:lock()
    return do_syscall("lockmutex", self)
end

function mutex:unlock()
    return do_syscall("unlockmutex", self)
end

function mutex:try_lock()
    return do_syscall("trylockmutex", self)
end

for _, v in pairs(mutex) do setfenv(v, setmetatable({}, {__newindex = function() end, __metatable = false})) debug.protect(v) end

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