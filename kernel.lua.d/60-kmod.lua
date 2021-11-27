function syscalls.listmodules()
    local retval = {}
    for k in pairs(modules) do retval[#retval+1] = k end
    return retval
end

-- TODO: Implement module dependencies
function syscalls.loadmodule(process, thread, path)
    expect(1, path, "string")
    if process.user ~= "root" then error("Could not load kernel module: Permission denied", 2) end
    local name = v:match "[^%.]+"
    syslog.log("Loading kernel module " .. name .. " from " .. path)
    local file, err = filesystem.open(KERNEL, path, "rb")
    if file then
        local data = file.readAll()
        file.close()
        local fn, err = load(data, "@" .. path)
        if fn then
            local ok, res = pcall(fn, path)
            if ok then modules[name] = res or true
            else syslog.log({level = 4}, "Kernel module " .. name .. " threw an error:", res) end
        else syslog.log({level = 4}, "Could not load " .. name .. ":", err) end
    else syslog.log({level = 4}, "Could not open " .. path .. ":", err) end
end

-- This call doesn't really do much if the module doesn't use the modules table.
function syscalls.unloadmodule(process, thread, name)
    expect(1, name, "string")
    if process.user ~= "root" then error("Could not load kernel module: Permission denied", 2) end
    if type(modules[name]) == "table" and modules[name].unload then modules[name].unload(process, thread) end
    modules[name] = nil
end

function syscalls.callmodule(process, thread, name, func, ...)
    expect(1, name, "string")
    expect(2, func, "string")
    if not modules[name] then error("Module '" .. name .. "' does not exist", 2)
    elseif type(modules[name]) ~= "table" then error("Module '" .. name .. "' does not have a callable interface", 2)
    elseif type(modules[name][func]) ~= "function" then error("Module '" .. name .. "' does not have a method '" .. func .. "'", 2) end
    return modules[name][func](process, thread, ...)
end

syslog.log("Loading kernel modules from /lib/modules")
local ok, modlist = pcall(filesystem.list, KERNEL, "/lib/modules")
if ok then
    for _, v in ipairs(modlist) do
        syscalls.loadmodule(KERNEL, nil, filesystem.combine("/lib/modules", v))
    end
else syslog.log({level = 2}, "Could not open /lib/modules:", modlist) end
