local function trim(s) return string.match(s, '^()%s*$') and '' or string.match(s, '^%s*(.*%S)') end
local expect, do_syscall = expect, do_syscall

local function ar_load(data)
    local pos = 1
    local function read(c)
        if pos > #data then return nil end
        c = c or 1
        local s = data:sub(pos, pos + c - 1)
        pos = pos + c
        return s
    end
    if read(8) ~= "!<arch>\n" then error("Not an ar archive", 2) end
    local retval = {}
    local name_table = nil
    local name_rep = {}
    while true do
        local data = {}
        local first_c = read()
        while first_c == "\n" do first_c = read() end
        if first_c == nil then break end
        local name = read(15)
        if name == nil then break end
        name = first_c .. name
        if string.find(name, "/") and string.find(name, "/") > 1 then name = string.sub(name, 1, string.find(name, "/") - 1)
        else name = trim(name) end
        data.timestamp = tonumber(trim(read(12)))
        data.owner = tonumber(trim(read(6)))
        data.group = tonumber(trim(read(6)))
        data.mode = tonumber(trim(read(8)), 8)
        local size = tonumber(trim(read(10)))
        if read(2) ~= "`\n" then error("Invalid header for file " .. name, 2) end
        if string.match(name, "^#1/%d+$") then name = read(tonumber(string.match(name, "#1/(%d+)")))
        elseif string.match(name, "^/%d+$") then if name_table then
            local n = tonumber(string.match(name, "/(%d+)"))
            name = name_table:match("[^/]*", n+1)
        else table.insert(name_rep, name) end end
        data.name = name
        data.data = read(size)
        if name == "//" then name_table = data.data
        elseif name ~= "/" and name ~= "/SYM64/" then table.insert(retval, data) end
    end
    if name_table then for k,v in pairs(name_rep) do
        local n = tonumber(string.match(v, "/(%d+)"))
        for l,w in pairs(retval) do if w.name == v then w.name = name_table:match("[^/]*", n+1) break end end
    end end
    local retval2 = {}
    for _, v in ipairs(retval) do retval2[v.name] = v end
    return retval2
end

--- Creates a new `package` and `require` set in a global table for the specified process.
-- @tparam Process process The process to make the functions for
-- @tparam _G G The global environment to install in
function createRequire(process, G)
    local loaded, preload = {}, {}
    G.package = {}
    local oldenv = processes[process.parent] and processes[process.parent].env
    if oldenv then
        G.package.path = oldenv.package and oldenv.package.path
        G.package.libpath = oldenv.package and oldenv.package.libpath
    end
    G.package.path = G.package.path or "/lib/?.lua;/lib/?/init.lua;/usr/lib/?.lua;/usr/lib/?/init.lua;./?.lua;./?/init.lua"
    G.package.libpath = G.package.libpath or "/lib/lib?.a;/usr/lib/lib?.a"
    G.package.config = "/\n;\n?\n!\n-"
    G.package.loaded = loaded
    G.package.preload = preload
    G.package.forceload = false
    for k, v in pairs(G) do if type(v) == "table" then loaded[k] = v end end

    local sentinel = setmetatable({}, {__newindex = function() end, __metatable = false})
    local localLoaders = {}

    local function fileLoader(name, path)
        local file, err = do_syscall("open", path, "rb")
        if not file then error(path .. ": " .. err, 3) end
        local data = file.readAll()
        file.close()
        local fn, err = load(data, "@" .. path, nil, _ENV)
        if not fn then error(path .. ": " .. err, 3) end
        local dir = path:match("^(.*)/[^/]*$") or "/"
        localLoaders[#localLoaders+1] = function(name2)
            local path, err = package.searchpath(name2, dir .. "/?.lua;" .. dir .. "/?/init.lua")
            if not path then return nil, err end
            return fileLoader, path
        end
        local ok, res = pcall(fn, name)
        localLoaders[#localLoaders] = nil
        if ok then return res
        else error(path .. ": " .. res, 3) end
    end

    local function libraryLoader(name, path)
        local libname
        if path:find "%z" then path, libname = path:match "^([^%z]*)%z(.*)$"
        elseif name:find "%-" then libname = name:match("^([^%-]*)%-(.*)$")
        else libname = "init" end
        local file, err = do_syscall("open", path, "rb")
        if not file then error(path .. ": " .. err, 3) end
        local data = file.readAll()
        file.close()
        local dir = ar_load(data)
        local function preloader(name)
            local p = name .. ".lua"
            if not dir[p] then error(path .. ":" .. p .. ": File not found", 0) end
            local data = dir[p].data
            local fn, err = load(data, "@" .. path .. ":" .. p, nil, _ENV)
            if not fn then error(path .. ":" .. p .. ": " .. err, 3) end
            local ok, res = pcall(fn, name)
            if ok then return res
            else error(path .. ":" .. p .. ": " .. res) end
        end
        localLoaders[#localLoaders+1] = function(name2) return preloader, name2 end
        local res = preloader(libname)
        localLoaders[#localLoaders] = nil
        return res
    end

    localLoaders[1] = function(name)
        local dir = do_syscall("getname"):match("^(.*)/[^/]*$") or "/"
        local path, err = package.searchpath(name, dir .. "/?.lua;" .. dir .. "/?/init.lua")
        if not path then return nil, err end
        return fileLoader, path
    end

    function G.package.searchpath(name, path, sep, rep)
        expect(1, name, "string")
        expect(2, path, "string")
        expect(3, sep, "string", "nil")
        expect(4, rep, "string", "nil")
        sep = (sep or "."):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        rep = (rep or "/"):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
        local msg = ""

        for p in path:gmatch "[^;]+" do
            local pp = p:gsub("%?", name:gsub(sep, rep), nil)
            local file, err = do_syscall("open", pp, "r")
            if file then
                file.close()
                return pp
            else
                msg = msg .. "\t" .. pp .. ": " .. err .. "\n"
            end
        end
        return nil, msg
    end

    G.package.searchers = {
        function(name)
            local p = preload[name]
            if p then return p else return nil, "\tpackage.preload['" .. name .. "']: No such field\n" end
        end,
        function(name)
            local path, err = package.searchpath(name, package.path)
            if not path then return nil, err end
            return fileLoader, path, path
        end,
        function(name)
            local path, err = package.searchpath(name:match("^[^%-]*"), package.libpath)
            if not path then return nil, err end
            local n = name:match("%-(.+)$")
            if n then return libraryLoader, path, path .. ":" .. n
            else return libraryLoader, path, path .. ":init" end
        end,
        function(name)
            if not name:find "%." then return nil end
            local path, err = package.searchpath(name:match("^[^%.]*"), package.libpath)
            if not path then return nil, err end
            local n = name:match("^[^%.]*%.(.*)$")
            return libraryLoader, path .. "\0" .. n, path .. ":" .. n
        end,
        function(name)
            if #localLoaders > 0 then return localLoaders[#localLoaders](name) end
            return nil, "no local loaders found"
        end
    }

    setfenv(fileLoader, G) debug.protect(fileLoader)
    setfenv(libraryLoader, G) debug.protect(libraryLoader)
    setfenv(localLoaders[1], G) debug.protect(localLoaders[1])
    for _,v in pairs(G.package.searchers) do setfenv(v, G) debug.protect(v) end

    function G.require(name)
        expect(1, name, "string")
        local err = "module '" .. name .. "' not found:\n"
        local loader, arg, pathname
        for _, v in ipairs(package.searchers) do
            loader, arg, pathname = v(name)
            if loader then break end
            err = err .. (arg or "")
        end
        if not loader then error(err, 2) end
        if pathname then
            if loaded[pathname] then
                if loaded[pathname] == sentinel then error("loop detected loading '" .. name .. "'", 3)
                elseif not package.forceload then return loaded[pathname] end
            end
            loaded[pathname] = sentinel
        else
            if loaded[name] then
                if loaded[name] == sentinel then error("loop detected loading '" .. name .. "'", 3)
                elseif not package.forceload then return loaded[name] end
            end
        end
        loaded[name] = sentinel
        local ok, res = pcall(loader, name, arg)
        if ok then
            if res ~= nil then loaded[name] = res
            elseif loaded[name] == sentinel then loaded[name] = true end
            if pathname then
                if res ~= nil then loaded[pathname] = res
                elseif loaded[pathname] == sentinel then loaded[pathname] = true end
            end
            return loaded[name]
        else
            loaded[name] = nil
            if pathname then loaded[pathname] = nil end
            error(err .. "\t" .. res .. "\n", 2)
        end
    end

    return G
end
