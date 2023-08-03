--- syslog
-- @section syslog

--- Stores all open system logs.
syslogs = {
    default = {
        --file = filesystem.open(KERNEL, "/var/log/default.log", "a"),
        stream = {},
        tty = KERNEL.stdout, -- console (tty0)
        tty_level = args.loglevel,
        colorize = true
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

local lognames = {}
for i = 0, #loglevels do lognames[loglevels[i]:lower()] = i end

local logcolors = {[0] = '\27[90m', '\27[97m', '\27[36m', '\27[93m', '\27[31m', '\27[95m', '\27[96m'}

local function concat(t, sep, i, j)
    if i >= j then return tostring(t[i])
    else return tostring(t[i]) .. sep .. concat(t, sep, i + 1, j) end
end

function syscalls.syslog(process, thread, options, ...)
    local args = table.pack(...)
    if type(options) == "table" then
        expect.field(options, "name", "string", "nil")
        expect.field(options, "category", "string", "nil")
        expect.field(options, "level", "number", "string", "nil")
        expect.field(options, "time", "number", "nil")
        expect.field(options, "process", "number", "nil")
        expect.field(options, "thread", "number", "nil")
        expect.field(options, "module", "string", "nil")
        expect.field(options, "traceback", "boolean", "nil")
        if type(options.level) == "string" then
            options.level = lognames[options.level:lower()]
            if not options.level then error("bad field 'level' (invalid name)", 0) end
        elseif options.level and (options.level < 0 or options.level > #loglevels) then error("bad field 'level' (level out of range)", 0) end
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
                local process = processes[v.pid]
                if process then
                    process.eventQueue[#process.eventQueue+1] = {"syslog", deepcopy(options)}
                end
            end
        end
    end
    if log.tty and log.tty_level <= options.level then
        if log.tty.isTTY then
            local str = concat(args, " ", 1, args.n)
            if log.colorize and options.traceback then
                str = str:gsub("\t", "  ")
                         :gsub("([^\n]+):(%d+):", "\27[96m%1\27[37m:\27[95m%2\27[37m:")
                         :gsub("'([^']+)'\n", "\27[93m'%1'\27[37m\n")
            end
            terminal.write(log.tty, ("%s[%s]%s %s[%d%s]%s [%s]: %s%s\n"):format(
                log.colorize and logcolors[options.level] or "",
                os.date("%b %d %X", options.time / 1000),
                options.category and " <" .. options.category .. ">" or "",
                processes[options.process] and processes[options.process].name or "(unknown)",
                options.process,
                options.thread and ":" .. options.thread or "",
                options.module and " (" .. options.module .. ")" or "",
                loglevels[options.level],
                str,
                log.colorize and "\27[0m" or ""
            ))
            terminal.redraw(log.tty)
        else end
    end
end

function syscalls.mklog(process, thread, name, streamed, path)
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
    expect(1, name, "string")
    if name == "default" then error("Cannot delete default log", 0) end
    if not syslogs[name] then error("Log does not exist", 0) end
    if syslogs[name].stream then for _,v in pairs(syslogs[name].stream) do
        processes[v.pid].eventQueue[#processes[v.pid].eventQueue+1] = {"syslog_close", {id = v.id}}
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
    local pid = process.id
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
            if v.pid == process.id then
                process.dependents[v.id] = nil
                syslogs[name].stream[i] = nil
            end
        end
    else
        -- Close log connection with ID
        if not process.dependents[name] then error("Log connection does not exist", 0) end
        local log = syslogs[process.dependents[name].name].stream
        for i,v in pairs(log) do
            if v.pid == process.id and v.id == name then
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
    expect(2, tty, "table", "number", "nil")
    expect(3, level, "number", "nil")
    if not syslogs[name] then error("Log does not exist", 0) end
    syslogs[name].tty = type(tty) == "table" and tty or TTY[tty]
    syslogs[name].tty_level = level
    return true
end

function syslog.log(options, ...)
    return pcall(syscalls.syslog, KERNEL, nil, options, ...)
end

function syslog.debug(...)
    return pcall(syscalls.syslog, KERNEL, nil, {level = "debug", process = 0}, ...)
end

local oldpanic = panic
--- Immediately halts the system and shows an error message on screen.
-- This function can be called either standalone or from within xpcall.
-- This function never returns.
-- @tparam[opt] any message A message to display on screen
function panic(message)
    xpcall(function()
        syslog.log({level = "panic"}, "Kernel panic:", message)
        if debug then
            local traceback = debug.traceback(nil, 2)
            syslog.log({level = "panic", traceback = true}, traceback)
        end
        syslog.log({level = "panic"}, "We are hanging here...")
        term.setCursorBlink(false)
        while true do coroutine.yield() end
    end, function(m)
        oldpanic(message .. "; and an error occurred while logging the error: " .. m)
    end)
end

xpcall(function()
    local err
    syslogs.default.file, err = filesystem.open(KERNEL, "/var/log/default.log", "a")
    shutdownHooks[#shutdownHooks+1] = function() if syslogs.default.file then syslogs.default.file.close() end end

    syslog.log("Starting Phoenix version", PHOENIX_VERSION, PHOENIX_BUILD)
    syslog.log("Initialized system logger")
    syslog.log("System started at " .. systemStartTime .. " on computer " .. os.computerID() .. (os.computerLabel() and "('" .. os.computerLabel() .. "')" or ""))
    syslog.log("Computer host is " .. _HOST)
    if syslogs.default.file == nil then syslog.log({level = "notice"}, "An error occurred while opening the log file at /var/log/default.log:", err, ". System logs will not be saved to disk.") end
end, panic)
