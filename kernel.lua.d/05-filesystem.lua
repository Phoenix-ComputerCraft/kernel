--- filesystem
-- @section filesystem

--[[
    CraftOS mount metadata is stored in the following format: {
        meta = {
            type = "directory",
            owner = "root",
            permissions = {
                root = {read = true, write = true, execute = true}
            },
            worldPermissions = {read = true, write = false, execute = true}
        },
        contents = {
            home = {
                meta = {
                    type = "directory",
                    owner = "user",
                    permissions = {
                        user = {read = true, write = true, execute = true},
                        admins = {read = true, write = false, execute = true}
                    },
                    worldPermissions = {read = false, write = false, execute = false}
                },
                contents = {
                    ["info.txt"] = {
                        meta = {
                            type = "link",
                            owner = "user",
                            permissions = {
                                user = {read = true, write = true, execute = false}
                            },
                            worldPermissions = {read = false, write = false, execute = false}
                        },
                        link = "../info.txt"
                    }
                }
            },
            ["info.txt"] = {
                meta = {
                    type = "file",
                    owner = "root",
                    permissions = {
                        root = {read = true, write = true, execute = false}
                    },
                    worldPermissions = {read = true, write = false, execute = false}
                }
            }
        }
    }
]]

--- Stores the current mounts as a key-value table of paths to filesystem objects.
mounts = {}

--- Stores all FIFOs in a table-indexed table.
fifos = {}

--- Stores paths that have fsevents registered, and the process(es) that are listening.
fsevents = {}

--- This table contains all filesystem types. Use this to insert more filesystem
-- types into the system.
--
-- A filesystem type has to implement one method for each function in the
-- filesystem API, with the exception of mounting-related functions and `combine`,
-- as well as a `new` method that is called with the process, the source device,
-- and the options table (if present). Paths passed to these methods (outside
-- `new`) take a relative path to the mountpoint, NOT the absolute path.
filesystems = {
    craftos = {
        meta = {
            meta = {
                type = "directory",
                owner = "root",
                permissions = {
                    root = {read = true, write = true, execute = true}
                },
                worldPermissions = {read = true, write = false, execute = true},
                setuser = false
            },
            contents = {}
        },
        metapath = "/meta.ltn",
        lastDispatch = 0
    },
    tmpfs = {},
    drivefs = {},
    tablefs = {},
    bind = {},
}

local function getRealPath(process, path)
    local p = fs.combine(process.root, path:sub(1, 1) == "/" and "" or process.dir, path)
    if "/" .. p .. "/" ~= process.root and p:find(process.root:sub(2), 1, true) ~= 1 then error(path .. ": No such file or directory", 4) end
    return p
end

local function getMount(process, path, list)
    local fullPath = split(getRealPath(process, path), "/\\")
    if #fullPath == 0 then
        if list then return mounts[""], path, "" end
        return mounts[""][1], path, ""
    end
    local maxPath
    for k in pairs(mounts) do
        local ok = true
        for i,c in ipairs(split(k, "/\\")) do if fullPath[i] ~= c then ok = false break end end
        if ok and (not maxPath or #k > #maxPath) then maxPath = k end
    end
    if not maxPath then panic("Could not find mount for path " .. path .. ". Where is root?") end
    local parts = split(maxPath, "/\\")
    local p = #fullPath >= #parts + 1 and fs.combine(table.unpack(fullPath, #parts + 1, #fullPath)) or ""
    --syslog.debug(path, #parts, #fullPath, p)
    local mounts = mounts[maxPath]
    if list then return mounts, p, maxPath end
    local mount = mounts[1]
    if #mounts > 1 then
        for _, v in ipairs(mounts) do
            local ok, res = pcall(v.stat, v, process, p, true)
            if ok and res then
                mount = v
                break
            end
        end
    end
    return mount, p, maxPath
end

--- Creates a new read file handle over string data.
-- @tparam Process process The process to open as
-- @tparam string data The contents of the file to read
-- @tparam boolean binary Whether to open in binary mode
-- @treturn[1] Handle The new file handle
-- @treturn[2] nil If an error occurred
-- @treturn[2] string An error message describing why the file couldn't be opened
function filesystem.readhandle(process, data, binary)
    if data == "" then
        local didRead = false
        local function read()
            if didRead then return nil end
            didRead = true
            return ""
        end
        local handle = {
            readLine = read,
            readAll = read,
            read = read,
            close = function() end
        }
        if binary then
            function handle.seek() didRead = false end
            function handle.read(n) if not n then return nil end return read() end
        end
        return handle
    end
    local pos = 1
    local closed = false
    local t = {
        readLine = function(newline)
            if closed then error("attempt to use a closed file", 2) end
            if pos > #data then return nil end
            local d
            d, pos = data:match("([^\n]*" .. (newline and "\n?)" or ")\n?") .. "()", pos)
            return d
        end,
        readAll = function()
            if closed then error("attempt to use a closed file", 2) end
            if pos > #data then return nil end
            local d = data:sub(pos)
            pos = #d + 1
            return d
        end,
        read = function(n)
            if closed then error("attempt to use a closed file", 2) end
            if n ~= nil and type(n) ~= "number" then error("bad argument #1 (expected number, got " .. type(n) .. ")", 2) end
            n = n or 1
            if pos > #data then return nil end
            local d = data:sub(pos, pos + n - 1)
            pos = pos + n
            return d
        end,
        close = function()
            if closed then error("attempt to use a closed file", 2) end
            closed = true
        end
    }
    if binary then
        t.read = function(n)
            if closed then error("attempt to use a closed file", 2) end
            if n ~= nil and type(n) ~= "number" then error("bad argument #1 (expected number, got " .. type(n) .. ")", 2) end
            if pos > #data then return nil end
            if n then
                local d = data:sub(pos, pos + n - 1)
                pos = pos + n
                return d
            else
                local d = data:byte(pos)
                pos = pos + 1
                return d
            end
        end
        t.seek = function(whence, offset)
            if whence ~= nil and type(whence) ~= "string" then error("bad argument #1 (expected string, got " .. type(whence) .. ")", 2) end
            if offset ~= nil and type(offset) ~= "number" then error("bad argument #2 (expected number, got " .. type(offset) .. ")", 2) end
            whence = whence or "cur"
            offset = offset or 0
            if closed then error("attempt to use closed file", 2) end
            if whence == "set" then pos = offset + 1
            elseif whence == "cur" then pos = pos + offset
            elseif whence == "end" then pos = math.max(#data - offset, 1)
            else error("Invalid whence", 2) end
            return pos - 1
        end
    else
        data = data:gsub("[\x80-\xFF]+", function(s)
            local r = ""
            if not pcall(function() for _, code in utf8.codes(s) do r = r .. (code < 256 and string.char(code) or "?") end end) then return s end
            return r
        end)
    end
    for _, v in pairs(t) do setfenv(v, process.env) debug.protect(v) end
    return setmetatable(t, {__name = "file"})
end

--- Creates a new write file handle with a generic writer.
-- @tparam Process process The process to open as
-- @tparam function(data:string,reset:boolean) writer A function to call to write pending data to the file - user mode!
-- If reset is true, data contains the entire file and old contents should be replaced; otherwise, it contains just the new data to append
-- @tparam boolean binary Whether to open in binary mode
-- @treturn[1] Handle The new file handle
-- @treturn[2] nil If an error occurred
-- @treturn[2] string An error message describing why the file couldn't be opened
function filesystem.writehandle(process, writer, binary)
    setfenv(writer, process.env)
    local function setenv(t)
        for _, v in pairs(t) do setfenv(v, process.env) debug.protect(v) end
        return setmetatable(t, {__name = "file"})
    end
    local closed = false
    if binary then
        local pos = 1
        local buf = ""
        local partial = ""
        return setenv {
            write = function(d)
                if closed then error("attempt to use a closed file", 2) end
                if type(d) == "number" then
                    buf, pos = buf:sub(1, pos - 1) .. string.char(d) .. buf:sub(pos + 1), pos + 1
                    if partial then partial = partial .. string.char(d) end
                elseif type(d) == "string" then
                    buf, pos = buf:sub(1, pos - 1) .. d .. buf:sub(pos + #d), pos + #d
                    if partial then partial = partial .. d end
                else error("bad argument #1 (expected string or number, got " .. type(d) .. ")", 2) end
            end,
            writeLine = function(d)
                if closed then error("attempt to use a closed file", 2) end
                if type(d) == "number" then
                    buf, pos = buf:sub(1, pos - 1) .. string.char(d) .. "\n" .. buf:sub(pos + 2), pos + 2
                    if partial then partial = partial .. string.char(d) .. "\n" end
                elseif type(d) == "string" then
                    buf, pos = buf:sub(1, pos - 1) .. d .. "\n" .. buf:sub(pos + #d + 1), pos + #d + 1
                    if partial then partial = partial .. d .. "\n" end
                else error("bad argument #1 (expected string or number, got " .. type(d) .. ")", 2) end
            end,
            seek = function(whence, offset)
                if whence ~= nil and type(whence) ~= "string" then error("bad argument #1 (expected string, got " .. type(whence) .. ")", 2) end
                if offset ~= nil and type(offset) ~= "number" then error("bad argument #2 (expected number, got " .. type(offset) .. ")", 2) end
                whence = whence or "cur"
                offset = offset or 0
                if closed then error("attempt to use closed file", 2) end
                local oldp = pos
                if whence == "set" then pos = offset + 1
                elseif whence == "cur" then pos = pos + offset
                elseif whence == "end" then pos = math.max(#buf - offset, 1)
                else error("Invalid whence", 2) end
                if oldp ~= pos then partial = nil end
                return pos - 1
            end,
            flush = function()
                if closed then error("attempt to use a closed file", 2) end
                if partial then writer(partial, false)
                else writer(buf, true) end
                partial = ""
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                closed = true
                if partial then writer(partial, false)
                else writer(buf, true) end
                partial = ""
            end
        }
    else
        local buf = ""
        return setenv {
            write = function(d)
                if closed then error("attempt to use a closed file", 2) end
                buf = buf .. tostring(d)
            end,
            writeLine = function(d)
                if closed then error("attempt to use a closed file", 2) end
                buf = buf .. tostring(d) .. "\n"
            end,
            flush = function()
                if closed then error("attempt to use a closed file", 2) end
                writer(buf, false)
                buf = ""
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                writer(buf, false)
                buf = ""
                closed = true
            end
        }
    end
end

--- Creates a new file handle for a generic FIFO object.
-- @tparam Process process The process to open as
-- @tparam {data=string} obj A handle for the shared FIFO data
-- @tparam string mode The mode to open in
-- @treturn[1] Handle The new file handle
-- @treturn[2] nil If an error occurred
-- @treturn[2] string An error message describing why the file couldn't be opened
function filesystem.fifohandle(process, obj, mode)
    local closed = false
    local function setenv(t)
        for _, v in pairs(t) do setfenv(v, process.env) debug.protect(v) end
        return setmetatable(t, {__name = "file"})
    end
    if mode == "r" then
        return setenv {
            readLine = function(newline)
                if closed then error("attempt to use a closed file", 2) end
                if #obj.data == 0 then return nil end
                local d
                d, obj.data = obj.data:match("([^\n]*" .. (newline and "\n?)" or ")\n?") .. "(.*)")
                return d
            end,
            readAll = function()
                if closed then error("attempt to use a closed file", 2) end
                if #obj.data == 0 then return nil end
                local d = obj.data
                obj.data = ""
                return d
            end,
            read = function(n)
                if closed then error("attempt to use a closed file", 2) end
                if n ~= nil and type(n) ~= "number" then error("bad argument #1 (expected number, got " .. type(n) .. ")", 2) end
                n = n or 1
                if #obj.data == 0 then return nil end
                local d = obj.data:sub(1, n)
                obj.data = obj.data:sub(n + 1)
                return d
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                closed = true
            end
        }
    elseif mode == "w" or mode == "a" then
        local buf = obj.data
        return setenv {
            write = function(d)
                if closed then error("attempt to use a closed file", 2) end
                buf = buf .. tostring(d)
            end,
            writeLine = function(d)
                if closed then error("attempt to use a closed file", 2) end
                buf = buf .. tostring(d) .. "\n"
            end,
            flush = function()
                if closed then error("attempt to use a closed file", 2) end
                obj.data = buf
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                obj.data = buf
                closed = true
            end
        }
    elseif mode == "rb" then
        return setenv {
            readLine = function(newline)
                if closed then error("attempt to use a closed file", 2) end
                if #obj.data == 0 then return nil end
                local d
                d, obj.data = obj.data:match("([^\n]*" .. (newline and "\n?)" or ")\n?") .. "(.*)")
                return d
            end,
            readAll = function()
                if closed then error("attempt to use a closed file", 2) end
                if #obj.data == 0 then return nil end
                local d = obj.data
                obj.data = ""
                return d
            end,
            read = function(n)
                if closed then error("attempt to use a closed file", 2) end
                if n ~= nil and type(n) ~= "number" then error("bad argument #1 (expected number, got " .. type(n) .. ")", 2) end
                if #obj.data == 0 then return nil end
                if n then
                    local d = obj.data:sub(1, n)
                    obj.data = obj.data:sub(n + 1)
                    return d
                else
                    local d = obj.data:byte()
                    obj.data = obj.data:sub(2)
                    return d
                end
            end,
            seek = function(whence, offset)
                if whence ~= nil and type(whence) ~= "string" then error("bad argument #1 (expected string, got " .. type(whence) .. ")", 2) end
                if offset ~= nil and type(offset) ~= "number" then error("bad argument #2 (expected number, got " .. type(offset) .. ")", 2) end
                if closed then error("attempt to use closed file", 2) end
                return 0
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                closed = true
            end
        }
    elseif mode == "wb" or mode == "ab" then
        local buf = obj.data
        return setenv {
            write = function(d)
                if closed then error("attempt to use a closed file", 2) end
                if type(d) == "number" then buf = buf .. string.char(d)
                elseif type(d) == "string" then buf = buf .. d
                else error("bad argument #1 (expected string or number, got " .. type(d) .. ")", 2) end
            end,
            writeLine = function(d)
                if closed then error("attempt to use a closed file", 2) end
                if type(d) == "number" then buf = buf .. string.char(d) .. "\n"
                elseif type(d) == "string" then buf = buf .. d .. "\n"
                else error("bad argument #1 (expected string or number, got " .. type(d) .. ")", 2) end
            end,
            seek = function(whence, offset)
                if whence ~= nil and type(whence) ~= "string" then error("bad argument #1 (expected string, got " .. type(whence) .. ")", 2) end
                if offset ~= nil and type(offset) ~= "number" then error("bad argument #2 (expected number, got " .. type(offset) .. ")", 2) end
                if closed then error("attempt to use closed file", 2) end
                return #obj.data + #buf
            end,
            flush = function()
                if closed then error("attempt to use a closed file", 2) end
                obj.data = buf
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                obj.data = buf
                closed = true
            end
        }
    else return nil, "Invalid mode" end
end
filesystem.openfifo = filesystem.fifohandle -- compatibility

-- craftos fs implementation

do
    local file = fs.open("/meta.ltn", "r")
    if file then
        filesystems.craftos.meta = unserialize(file.readAll()) or filesystems.craftos.meta
        filesystems.craftos.lastDispatch = os.epoch "utc"
        file.close()
    end
end

shutdownHooks[#shutdownHooks+1] = function()
    syslog.log("Syncing filesystem")
    local file = fs.open(filesystems.craftos.metapath, "w")
    if file then
        file.write(serialize(filesystems.craftos.meta, {compact = true}))
        file.close()
    end
end

if args.fsmeta then
    local file = fs.open(args.fsmeta, "r")
    if file then
        local meta = unserialize(file.readAll())
        file.close()
        if meta then
            local function merge(src, dest)
                for k, v in pairs(src) do
                    if dest[k] and type(dest[k]) == "table" and type(v) == "table" then merge(v, dest[k])
                    else dest[k] = v end
                end
            end
            merge(meta, filesystems.craftos.meta)
        end
    end
end

function filesystems.craftos:getmeta(user, path, nolink)
    local stack = {}
    local t = self.meta
    local parts = split(path, "/\\")
    for i, p in ipairs(parts) do
        if p == ".." then
            t = table.remove(stack)
            if not t then return nil end
        elseif not p:match "^%.*$" then
            if not t then return nil
            elseif t.meta.type ~= "directory" then error("Not a directory", 2)
            elseif t.meta.permissions[user] then if not t.meta.permissions[user].execute then error("Permission denied", 2) end
            elseif not t.meta.worldPermissions.execute then error("Permission denied", 2) end
            stack[#stack+1] = t
            t = t.contents[p]
            if t and t.meta.type == "link" and not nolink then
                local link = filesystem.combine(t.meta.link, table.unpack(parts, i + 1))
                if fs.combine(link) == fs.combine(path) then error("Loop in link", 2) end
                error {link = true, path = link, orig = path}
            end
        end
    end
    return t and t.meta
end

function filesystems.craftos:setmeta(user, path, meta, nolink)
    local stack = {}
    local t = self.meta
    local name
    local parts = split(path, "/\\")
    for i, p in ipairs(parts) do
        if p == ".." then
            t = table.remove(stack)
            if not t then error("Not a directory", 2) end
        elseif not p:match "^%.*$" then
            if t.meta.type ~= "directory" then error("Not a directory", 2)
            elseif t.meta.permissions[user] then if not t.meta.permissions[user].execute then error("Permission denied", 2) end
            elseif not t.meta.worldPermissions.execute then error("Permission denied", 2) end
            if not t.contents[p] then t.contents[p] = { -- Initialize with default directory meta if not present
                meta = {                                -- This means the directory was created on-disk but the metadata was never set
                    type = "directory",                 -- We'll set it properly at the end (or something)
                    owner = t.meta.owner or "root",
                    permissions = {
                        root = {read = true, write = true, execute = true}
                    },
                    worldPermissions = {read = true, write = false, execute = true},
                    setuser = false
                },
                contents = {}
            } end
            stack[#stack+1] = t
            t = t.contents[p]
            name = p
            if t and t.meta.type == "link" and not nolink then
                local link = filesystem.combine(t.meta.link, table.unpack(parts, i + 1))
                if fs.combine(link) == fs.combine(path) then error("Loop in link", 2) end
                error {link = true, path = link, orig = path}
            end
        end
    end
    if meta ~= nil then
        t.meta = {
            type = meta.type,
            owner = meta.owner,
            permissions = deepcopy(meta.permissions),
            worldPermissions = deepcopy(meta.worldPermissions),
            setuser = meta.setuser,
            link = meta.link
        }
        if meta.type ~= "directory" then t.contents = nil end
    else stack[#stack].contents[name] = nil end
    if os.epoch "utc" - self.lastDispatch > 1000 then
        local file = assert(fs.open(self.metapath, "w"))
        file.write(serialize(self.meta, {compact = true}))
        file.close()
        self.lastDispatch = os.epoch "utc"
    end
end

function filesystems.craftos:new(process, path, options)
    expect.field(options, "ro", "boolean", "nil")
    -- CraftOS mounts will always require root
    if process.user ~= "root" then error("Could not mount " .. path .. ": Permission denied", 3)
    elseif not fs.isDir(path) then error("Could not mount " .. path .. ": No such directory", 3) end
    return setmetatable({
        path = path,
        readOnly = options.ro
    }, {__index = self})
end

function filesystems.craftos:open(process, path, mode)
    local ok, stat = pcall(self.stat, self, process, path)
    if not ok then
        if type(stat) == "table" then error(stat) end
        return nil, stat
    elseif not stat then
        if mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a" then
            if self.readOnly then return nil, "Read-only filesystem" end
            local pok, pstat = pcall(self.stat, self, process, fs.getDir(path))
            if not pok or not pstat then
                if type(pstat) == "table" then error(pstat) end
                local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
                if not mok then
                    if type(err) == "table" then error(err) end
                    return nil, err:gsub("kernel:%d: ", "")
                end
                pstat = self:stat(process, fs.getDir(path))
                if not pstat then return nil, "Could not stat " .. fs.getDir(path) end
            end
            if process.user ~= "root" then
                local perms = pstat.permissions[process.user] or pstat.worldPermissions
                if not perms.write then return nil, "Permission denied" end
            end
            local meta = {
                type = "file",
                owner = process.user,
                permissions = deepcopy(pstat.permissions),
                worldPermissions = deepcopy(pstat.worldPermissions),
                setuser = false
            }
            -- We do a swap here so it doesn't break if pstat.owner == process.user
            if pstat.owner then
                local t = meta.permissions[pstat.owner]
                meta.permissions[pstat.owner] = nil
                meta.permissions[process.user] = t
            end
            self:setmeta(process.user, fs.combine(self.path, path), meta)
            local file, err = fs.open(fs.combine(self.path, path), mode)
            if not file then return file, err end
            return setmetatable(file, {__name = "file"})
        else return nil, "File not found" end
    elseif stat.type == "directory" then return nil, "Is a directory" end
    local perms = stat.permissions[process.user] or stat.worldPermissions
    --syslog.debug(path, mode, perms.read, perms.write, perms.execute)
    if process.user ~= "root" and ((mode:sub(1, 1) == "r" and not perms.read) or ((mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a") and not perms.write)) then return nil, "Permission denied" end
    if stat.type == "fifo" then
        local meta = self:getmeta(process.user, fs.combine(self.path, path))
        local fifo = fifos[meta]
        if not fifo then
            fifo = {data = ""}
            fifos[meta] = fifo
        end
        return filesystem.fifohandle(process, fifo, mode)
    end
    local file, err = fs.open(fs.combine(self.path, path), mode)
    if not file then return nil, err end
    return setmetatable(file, {__name = "file"})
end

function filesystems.craftos:list(process, path)
    local stat = self:stat(process, path)
    if not stat or stat.type ~= "directory" then error(path .. ": Not a directory", 2) end
    if process.user ~= "root" then
        local perms = stat.permissions[process.user] or stat.worldPermissions
        if not perms.read then error(path .. ": Permission denied", 2) end
    end
    return fs.list(fs.combine(self.path, path))
end

-- TODO: Block access when a parent directory isn't readable
function filesystems.craftos:stat(process, path, nolink)
    local p = fs.combine(self.path, path)
    if p:find(self.path:gsub("^/", ""):gsub("/$", ""), 1, false) ~= 1 then return nil end
    local ok, attr = pcall(fs.attributes, p)
    if not ok or not attr then return nil end
    attr.type = attr.isDir and "directory" or "file"
    attr.special = {}
    attr.isDir = nil
    if not attr.modified then attr.modified = attr.modification end
    attr.modification = nil
    attr.capacity = fs.getCapacity(p) or 0
    attr.freeSpace = fs.getFreeSpace(p)
    local ro = attr.isReadOnly
    attr.isReadOnly = nil
    local meta = self:getmeta(process.user, fs.combine(self.path, path), nolink)
    -- The path may exist on the filesystem but have no metadata.
    if meta then
        attr.owner = meta.owner
        attr.permissions = deepcopy(meta.permissions)
        attr.worldPermissions = deepcopy(meta.worldPermissions)
        attr.type = meta.type or attr.type
        attr.setuser = meta.setuser
        attr.link = meta.link
    else
        attr.owner = "root" -- all files are root-owned by default
        attr.permissions = {
            root = {read = true, write = true, execute = true}
        }
        attr.worldPermissions = {read = true, write = false, execute = true}
        attr.setuser = false
    end
    if ro then
        attr.worldPermissions.write = false
        for _, v in pairs(attr.permissions) do v.write = false end
    end
    return attr
end

function filesystems.craftos:remove(process, path)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path, true)
    if not stat then return end
    local function checkWriteRecursive(p)
        local s = self:stat(process, p, true)
        local perms = s.permissions[process.user] or s.worldPermissions
        if process.user ~= "root" and not perms.write then error(p .. ": Permission denied", 3) end
        if s.type == "directory" then
            if process.user ~= "root" and not perms.read then error(p .. ": Permission denied", 3) end
            for _, v in ipairs(fs.list(fs.combine(self.path, p))) do checkWriteRecursive(fs.combine(p, v)) end
        end
    end
    checkWriteRecursive(path)
    fs.delete(fs.combine(self.path, path))
    self:setmeta(process.user, fs.combine(self.path, path), nil, true)
end

function filesystems.craftos:rename(process, from, to)
    if self.readOnly then error("Read-only filesystem", 2) end
    local fromstat = self:stat(process, from, true)
    local tostat = self:stat(process, to, true)
    if not fromstat then error(from .. ": No such file or directory", 2)
    elseif tostat then error(to .. ": " .. tostat.type:gsub("%w", string.upper, 1) .. " already exists", 2) end
    tostat = self:stat(process, fs.getDir(to))
    if not tostat then
        self:mkdir(process, fs.getDir(to))
        tostat = self:stat(process, fs.getDir(to))
    end
    if process.user ~= "root" then
        local perms = tostat.permissions[process.user] or tostat.worldPermissions
        if not perms.write then error(to .. ": Permission denied", 2) end
    end
    fs.move(fs.combine(self.path, from), fs.combine(self.path, to))
    self:setmeta(process.user, fs.combine(self.path, to), self:getmeta(process.user, fs.combine(self.path, from), true), true)
    self:setmeta(process.user, fs.combine(self.path, from), nil, true)
end

function filesystems.craftos:mkdir(process, path)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path)
    if stat then
        if stat.type == "directory" then return
        else error(path .. ": File already exists", 2) end
    end
    local parts = split(path, "/\\")
    local i = #parts
    repeat
        i=i-1
        stat = self:stat(process, table.concat(parts, "/", 1, i))
        if stat then
            if stat.type == "directory" then break
            else error(path .. ": File already exists", 2) end
        end
    until stat or i <= 0
    if not stat then
        if path:match "^/" then stat = assert(self:stat(process, "/"))
        else stat = assert(filesystem.stat(process, process.dir)) end
    end
    if process.user ~= "root" then
        local perms = stat.permissions[process.user] or stat.worldPermissions
        if not perms.write then error(path .. ": Permission denied", 2) end
    end
    local meta = {
        type = "directory",
        owner = process.user,
        permissions = deepcopy(stat.permissions),
        worldPermissions = deepcopy(stat.worldPermissions)
    }
    if stat.owner then
        local t = meta.permissions[stat.owner]
        meta.permissions[stat.owner] = nil
        meta.permissions[process.user] = t
    end
    i=i+1
    while i <= #parts do
        self:setmeta(process.user, fs.combine(self.path, table.concat(parts, "/", 1, i)), deepcopy(meta))
        i=i+1
    end
    fs.makeDir(fs.combine(self.path, path))
end

function filesystems.craftos:link(process, path, location)
    local stat = self:stat(process, path, true)
    if stat then error(path .. ": File exists", 2) end
    self:setmeta(process.user, fs.combine(self.path, path), nil, true)
    assert(self:open(process, path, "w")).close()
    local meta = self:getmeta(process.user, fs.combine(self.path, path), true)
    meta.type, meta.link = "link", location
    self:setmeta(process.user, fs.combine(self.path, path), meta, true)
end

function filesystems.craftos:mkfifo(process, path)
    local stat = self:stat(process, path)
    if stat then error(path .. ": File exists", 2) end
    assert(self:open(process, path, "w")).close()
    local meta = self:getmeta(process.user, fs.combine(self.path, path), true)
    meta.type = "fifo"
    self:setmeta(process.user, fs.combine(self.path, path), meta, true)
end

function filesystems.craftos:chmod(process, path, user, mode)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path, true)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    local perms
    if user == nil then perms = stat.worldPermissions
    else
        perms = stat.permissions[user]
        if not perms then
            perms = deepcopy(stat.worldPermissions)
            stat.permissions[user] = perms
        end
    end
    if type(mode) == "string" then
        if mode:match "^[%+%-=][rwxs]+$" then
            local m = mode:sub(1, 1)
            local t = {}
            for c in mode:gmatch("[rwxs]") do
                if c == "r" then t.read = true
                elseif c == "w" then t.write = true
                elseif c == "s" then t.setuser = true
                else t.execute = true end
            end
            if m == "+" then
                if t.read then perms.read = true end
                if t.write then perms.write = true end
                if t.execute then perms.execute = true end
                if t.setuser then stat.setuser = true end
            elseif m == "-" then
                if t.read then perms.read = false end
                if t.write then perms.write = false end
                if t.execute then perms.execute = false end
                if t.setuser then stat.setuser = false end
            else
                perms.read = t.read or false
                perms.write = t.write or false
                perms.execute = t.execute or false
                stat.setuser = t.setuser or false
            end
        else
            perms.read = mode:sub(1, 1) ~= "-"
            perms.write = mode:sub(2, 2) ~= "-"
            perms.execute = mode:sub(3, 3) ~= "-"
            stat.setuser = mode:sub(3, 3) == "s"
        end
    elseif type(mode) == "number" then
        stat.setuser = bit32.btest(mode, 8)
        perms.read = bit32.btest(mode, 4)
        perms.write = bit32.btest(mode, 2)
        perms.execute = bit32.btest(mode, 1)
    else
        if mode.read ~= nil then perms.read = mode.read end
        if mode.write ~= nil then perms.write = mode.write end
        if mode.execute ~= nil then perms.execute = mode.execute end
        if mode.setuser ~= nil then stat.setuser = mode.setuser end
    end
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat), true)
end

function filesystems.craftos:chown(process, path, owner)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path, true)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    stat.owner = owner
    stat.setuser = false
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat), true)
end

function filesystems.craftos:info()
    return "craftos", self.path, {ro = self.readOnly}
end

-- tmpfs implementation
-- tmpfs stores data in the same format as craftos meta, but with the addition of storing file data in .data

function filesystems.tmpfs:getpath(user, path, nolink)
    local t = self
    local parts = split(path, "/\\")
    for i, p in ipairs(parts) do
        if not t then return nil
        elseif t.type ~= "directory" then error("Not a directory", 2)
        elseif t.permissions[user] then if not t.permissions[user].execute then error("Permission denied", 2) end
        elseif not t.worldPermissions.execute then error("Permission denied", 2) end
        t = t.contents[p]
        if t and t.type == "link" and not (nolink and i == #parts) then error {link = true, path = filesystem.combine(t.link, table.unpack(parts, i + 1)), orig = path} end
    end
    return t
end

function filesystems.tmpfs:setpath(user, path, data, nolink)
    local t = self
    local e = split(path, "/\\")
    local last = e[#e]
    e[#e] = nil
    for i, p in ipairs(e) do
        if t.type ~= "directory" then error("Not a directory", 2)
        elseif t.permissions[user] then if not t.permissions[user].execute then error("Permission denied", 2) end
        elseif not t.worldPermissions.execute then error("Permission denied", 2) end
        if not t.contents[p] then t.contents[p] = { -- Initialize with default directory meta if not present
            type = "directory",
            owner = t.owner,
            permissions = deepcopy(t.permissions),
            worldPermissions = deepcopy(t.worldPermissions),
            setuser = false,
            created = os.epoch "utc",
            modified = os.epoch "utc",
            contents = {}
        } end
        t = t.contents[p]
        if t and t.type == "link" then error {link = true, path = filesystem.combine(t.link, table.unpack(e, i + 1)), orig = path} end
    end
    if t.type ~= "directory" then error("Not a directory", 2)
    elseif user ~= "root" then
        if t.permissions[user] then if not t.permissions[user].execute then error("Permission denied", 2) end
        elseif not t.worldPermissions.execute then error("Permission denied", 2) end
    end
    if not nolink and t.contents[last] and t.contents[last].type == "link" then error {link = true, path = t.contents[last].link, orig = path} end
    t.contents[last] = data
end

function filesystems.tmpfs:new(process, src, options)
    return setmetatable({
        type = "directory",
        owner = process.user,
        permissions = {
            [process.user] = {read = true, write = true, execute = true}
        },
        worldPermissions = {read = true, write = false, execute = true},
        setuser = false,
        created = os.epoch "utc",
        modified = os.epoch "utc",
        contents = {}
    }, {__index = self})
end

function filesystems.tmpfs:_open_internal(process, path, mode)
    local epoch = os.epoch
    local data = self:getpath(process.user, path)
    if not data then return nil, "No such file" end
    if mode == "r" or mode == "rb" then return filesystem.readhandle(process, data.data, mode == "rb")
    elseif mode == "w" or mode == "wb" then
        data.data = ""
        data.modified = epoch "utc"
        return filesystem.writehandle(process, function(buf, full)
            if full then data.data = buf else data.data = data.data .. buf end
            data.modified = epoch "utc"
            if self.__flush then self:__flush() end
        end, mode == "wb")
    elseif mode == "a" or mode == "ab" then
        local orig = data.data
        return filesystem.writehandle(process, function(buf, full)
            if full then data.data = orig .. buf else data.data = data.data .. buf end
            data.modified = epoch "utc"
            if self.__flush then self:__flush() end
        end, mode == "ab")
    else return nil, "Invalid mode" end
end

function filesystems.tmpfs:open(process, path, mode)
    if self.readOnly and (mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a") then return nil, "Read-only filesystem" end
    local ok, stat = pcall(self.stat, self, process, path)
    if not ok then
        if type(stat) == "table" then error(stat) end
        return nil, stat
    elseif not stat then
        if mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a" then
            local pok, pstat = pcall(self.stat, self, process, fs.getDir(path))
            if not pok or not pstat then
                if type(pstat) == "table" then error(pstat) end
                local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
                if not mok then
                    if type(err) == "table" then error(err) end
                    return nil, err:gsub("kernel:%d: ", "")
                end
                pstat = self:stat(process, fs.getDir(path))
            end
            if process.user ~= "root" then
                local perms = pstat.permissions[process.user] or pstat.worldPermissions
                if not perms.write then return nil, "Permission denied" end
            end
            local meta = {
                type = "file",
                owner = process.user,
                permissions = deepcopy(pstat.permissions),
                worldPermissions = deepcopy(pstat.worldPermissions),
                setuser = false,
                created = os.epoch "utc",
                modified = os.epoch "utc",
                data = ""
            }
            -- We do a swap here so it doesn't break if pstat.owner == process.user
            local t = meta.permissions[pstat.owner]
            meta.permissions[pstat.owner] = nil
            meta.permissions[process.user] = t
            self:setpath(process.user, path, meta)
            return self:_open_internal(process, path, mode)
        else return nil, "File not found" end
    elseif stat.type == "directory" then return nil, "Is a directory" end
    if process.user ~= "root" then
        local perms = stat.permissions[process.user] or stat.worldPermissions
        --syslog.debug(path, mode, perms.read, perms.write, perms.execute)
        if (mode:sub(1, 1) == "r" and not perms.read) or ((mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a") and not perms.write) then return nil, "Permission denied" end
    end
    if stat.type == "fifo" then
        local meta = self:getpath(process.user, path)
        local fifo = fifos[meta]
        if not fifo then
            fifo = {data = ""}
            fifos[meta] = fifo
        end
        return filesystem.fifohandle(process, fifo, mode)
    end
    return self:_open_internal(process, path, mode)
end

function filesystems.tmpfs:list(process, path)
    local data = self:getpath(process.user, path)
    if not data or data.type ~= "directory" then error(path .. ": Not a directory", 2) end
    if process.user ~= "root" then
        local perms = data.permissions[process.user] or data.worldPermissions
        if not perms.read then error(path .. ": Permission denied", 2) end
    end
    local retval = {}
    for k in pairs(data.contents) do retval[#retval+1] = k end
    table.sort(retval)
    return retval
end

function filesystems.tmpfs:stat(process, path, nolink)
    local data = self:getpath(process.user, path, nolink)
    if not data then return nil end
    return {
        size = data.type == "file" and #data.data or (data.type == "directory" and #data.contents or 0),
        type = data.type,
        created = data.created,
        modified = data.modified,
        owner = data.owner,
        permissions = deepcopy(data.permissions),
        worldPermissions = deepcopy(data.worldPermissions),
        setuser = data.setuser,
        capacity = math.huge,
        freeSpace = math.huge,
        link = rawget(data, "link"),
        special = {}
    }
end

function filesystems.tmpfs:remove(process, path)
    if self.readOnly then error("Read-only filesystem", 2) end
    local parent = self:getpath(process.user, fs.getDir(path))
    local name = fs.getName(path)
    if not parent or parent.type ~= "directory" or not parent.contents[name] then return end
    if process.user ~= "root" and not (parent.permissions[process.user] or parent.worldPermissions).write then error(path .. ": Permission denied", 2) end
    local data = parent.contents[name]
    if process.user ~= "root" and not (data.permissions[process.user] or data.worldPermissions).write then error(path .. ": Permission denied", 2) end
    local function checkWriteRecursive(s)
        local perms = s.permissions[process.user] or s.worldPermissions
        if process.user ~= "root" and not perms.write then error(path .. ": Permission denied", 3) end
        if s.type == "directory" then
            if process.user ~= "root" and not perms.read then error(path .. ": Permission denied", 3) end
            for _, v in pairs(s.contents) do checkWriteRecursive(v) end
        end
    end
    checkWriteRecursive(data)
    parent.contents[name] = nil
    parent.modified = os.epoch "utc"
end

function filesystems.tmpfs:rename(process, from, to)
    if self.readOnly then error("Read-only filesystem", 2) end
    local fparent = self:getpath(process.user, fs.getDir(from))
    local fname = fs.getName(from)
    if not fparent or fparent.type ~= "directory" or not fparent.contents[fname] then error(from .. ": No such file or directory", 2) end
    if process.user ~= "root" and not (fparent.permissions[process.user] or fparent.worldPermissions).write then error(from .. ": Permission denied", 2) end
    local fdata = fparent.contents[fname]
    if process.user ~= "root" and not (fdata.permissions[process.user] or fdata.worldPermissions).write then error(from .. ": Permission denied", 2) end
    local tparent = self:getpath(process.user, fs.getDir(to))
    local tname = fs.getName(to)
    if not tparent or tparent.type ~= "directory" then error(to .. ": No such file or directory", 2) end
    if process.user ~= "root" and not (tparent.permissions[process.user] or tparent.worldPermissions).write then error(to .. ": Permission denied", 2) end
    local tdata = tparent.contents[tname]
    if tdata then error(to .. ": File already exists", 2) end
    tparent.contents[tname], fparent.contents[fname] = fdata, nil
    local time = os.epoch "utc"
    fparent.modified, tparent.modified = time, time
end

function filesystems.tmpfs:mkdir(process, path)
    if self.readOnly then error("Read-only filesystem", 2) end
    local t = self
    for _,p in ipairs(split(path, "/\\")) do
        local perms = t.permissions[process.user] or t.worldPermissions
        if t.type ~= "directory" then error(path .. ": File exists", 2)
        elseif process.user ~= "root" and not perms.execute then error(path .. ": Permission denied", 2) end
        if not t.contents[p] then
            if process.user ~= "root" and not perms.write then error(path .. ": Permission denied", 2) end
            t.contents[p] = { -- Initialize with default directory meta if not present
                type = "directory",
                owner = t.owner,
                permissions = deepcopy(t.permissions),
                worldPermissions = deepcopy(t.worldPermissions),
                created = os.epoch "utc",
                modified = os.epoch "utc",
                contents = {}
            }
            t.modified = os.epoch "utc"
        end
        t = t.contents[p]
        -- TODO: handle link traversal
        --if t and t.meta.type == "link" then t = ? end
    end
end

function filesystems.tmpfs:link(process, path, location)
    if self.readOnly then error("Read-only filesystem", 2) end
    local stat = self:stat(process, path)
    if stat then error(path .. ": File exists", 2) end
    local pok, pstat = pcall(self.stat, self, process, fs.getDir(path))
    if not pok or not pstat then
        if type(pstat) == "table" then error(pstat) end
        local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
        if not mok then
            if type(err) == "table" then error(err) end
            return nil, type(err) == "string" and err:gsub("kernel:%d: ", "") or err
        end
        pstat = self:stat(process, fs.getDir(path))
    end
    self:setpath(process.user, path, {
        type = "link",
        owner = process.user,
        permissions = deepcopy(pstat.permissions),
        worldPermissions = deepcopy(pstat.worldPermissions),
        setuser = false,
        created = os.epoch "utc",
        modified = os.epoch "utc",
        path = location
    }, true)
end

function filesystems.tmpfs:mkfifo(process, path)
    if self.readOnly then error("Read-only filesystem", 2) end
    local stat = self:stat(process, path)
    if stat then error(path .. ": File exists", 2) end
    local pok, pstat = pcall(self.stat, self, process, fs.getDir(path))
    if not pok or not pstat then
        if type(pstat) == "table" then error(pstat) end
        local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
        if not mok then
            if type(err) == "table" then error(err) end
            return nil, type(err) == "string" and err:gsub("kernel:%d: ", "") or err
        end
        pstat = self:stat(process, fs.getDir(path))
    end
    self:setpath(process.user, path, {
        type = "fifo",
        owner = process.user,
        permissions = deepcopy(pstat.permissions),
        worldPermissions = deepcopy(pstat.worldPermissions),
        setuser = false,
        created = os.epoch "utc",
        modified = os.epoch "utc"
    }, true)
end

function filesystems.tmpfs:chmod(process, path, user, mode)
    if self.readOnly then error("Read-only filesystem", 2) end
    local stat = self:getpath(process.user, path, true)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    local perms
    if user == nil then perms = stat.worldPermissions
    else
        perms = stat.permissions[user]
        if not perms then
            perms = deepcopy(stat.worldPermissions)
            stat.permissions[user] = perms
        end
    end
    if type(mode) == "string" then
        if mode:match "^[%+%-=][rwxs]+$" then
            local m = mode:sub(1, 1)
            local t = {}
            for c in mode:gmatch("[rwxs]") do
                if c == "r" then t.read = true
                elseif c == "w" then t.write = true
                elseif c == "s" then t.setuser = true
                else t.execute = true end
            end
            if m == "+" then
                if t.read then perms.read = true end
                if t.write then perms.write = true end
                if t.execute then perms.execute = true end
                if t.setuser then stat.setuser = true end
            elseif m == "-" then
                if t.read then perms.read = false end
                if t.write then perms.write = false end
                if t.execute then perms.execute = false end
                if t.setuser then stat.setuser = false end
            else
                perms.read = t.read or false
                perms.write = t.write or false
                perms.execute = t.execute or false
                stat.setuser = t.setuser or false
            end
        else
            perms.read = mode:sub(1, 1) ~= "-"
            perms.write = mode:sub(2, 2) ~= "-"
            perms.execute = mode:sub(3, 3) ~= "-"
            stat.setuser = mode:sub(3, 3) == "s"
        end
    elseif type(mode) == "number" then
        stat.setuser = bit32.btest(mode, 8)
        perms.read = bit32.btest(mode, 4)
        perms.write = bit32.btest(mode, 2)
        perms.execute = bit32.btest(mode, 1)
    else
        if mode.read ~= nil then perms.read = mode.read end
        if mode.write ~= nil then perms.write = mode.write end
        if mode.execute ~= nil then perms.execute = mode.execute end
        if mode.setuser ~= nil then stat.setuser = mode.setuser end
    end
end

function filesystems.tmpfs:chown(process, path, owner)
    if self.readOnly then error("Read-only filesystem", 2) end
    local stat = self:getpath(process.user, path, true)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    stat.owner = owner
    stat.setuser = false
end

function filesystems.tmpfs:info()
    return "tmpfs", "memory", {ro = self.readOnly}
end

-- drivefs implementation
-- drivefs just inherits from craftos, but automatically locates drive mounts from hardware devices.

setmetatable(filesystems.drivefs, {__index = filesystems.craftos})

function filesystems.drivefs:stat(process, path)
    local res, err = filesystems.craftos.stat(self, process, path)
    if path == "" and res == nil then return {
        size = 0,
        type = "directory",
        created = 0,
        modified = 0,
        owner = self.owner,
        capacity = 0,
        freeSpace = 0,
        permissions = {[self.owner] = {read = false, write = true, execute = false}},
        worldPermissions = {read = false, write = false, execute = false},
        setuser = false
    } end
    return res, err
end

function filesystems.drivefs:new(process, src, options)
    local drive = hardware.get(src)
    if not drive then error("Could not find drive at " .. src) end
    local path = hardware.call(process, drive, "getMountPath")
    local fs = filesystems.craftos:new(process, path, options)
    fs.drive = drive.uuid
    fs.owner = process.user
    fs.meta = {
        meta = {
            type = "directory",
            owner = "root",
            permissions = {
                root = {read = true, write = true, execute = true}
            },
            worldPermissions = {read = true, write = false, execute = true},
            setuser = false
        },
        contents = {}
    }
    fs.metapath = fs.combine(path, ".meta.ltn")
    local file = fs.open(fs.metapath, "r")
    if file then
        fs.meta = unserialize(file.readAll()) or fs.meta
        file.close()
    end
    return setmetatable(fs, {__index = self})
end

function filesystems.drivefs:info()
    return "drivefs", self.drive, {ro = self.readOnly}
end

-- tablefs implementation
-- tablefs just inherits from tmpfs, but automatically loads the structure from a file (and can optionally be saved).
-- options: ro = do not allow writing to files; rw = flush data to disk after writing (neither = keep changes in memory only)

setmetatable(filesystems.tablefs, {__index = filesystems.tmpfs})

function filesystems.tablefs:new(process, src, options)
    local t
    local file, err
    if process ~= KERNEL and mounts[""] then file, err = filesystem.open(process, src, "r")
    else file, err = fs.open(src, "r") end
    if file then
        local data = file.readAll() or ""
        file.close()
        local ok, res = pcall(unserialize, data)
        if not ok then error("Could not mount " .. src .. ": " .. res, 3)
        elseif type(res) ~= "table" or res.type ~= "directory" or type(res.contents) ~= "table" then error("Could not mount " .. src .. ": Invalid table file", 3) end
        t = res
    else
        if not (options.rw and not options.ro) then error("Could not mount " .. src .. ": " .. err, 3) end
        t = {
            type = "directory",
            owner = process.user,
            permissions = {
                [process.user] = {read = true, write = true, execute = true}
            },
            worldPermissions = {read = true, write = false, execute = true},
            setuser = false,
            created = os.epoch "utc",
            modified = os.epoch "utc",
            contents = {}
        }
    end
    t.src = src
    t.readOnly = options.ro
    if options.rw and not options.ro then function t:__flush()
        local f, s = self.__flush, self.src
        self.__flush, self.src = nil
        local ok, res = pcall(serialize, self)
        self.__flush, self.src = f, s
        if not ok then error(res) end
        local file, err = filesystem.open(process, src, "w")
        if not file then syslog.log({level = 4}, "Could not save mount to " .. src .. ": " .. err) return end
        file.write(res)
        file.close()
    end end
    return setmetatable(t, {__index = self})
end

function filesystems.tablefs:info()
    return "tablefs", self.src, {rw = self.__flush ~= nil, ro = self.readOnly}
end

-- bind implementation

function filesystems.bind:new(process, path, options)
    local stat, err = filesystem.stat(process, path)
    if not stat then error("Could not bind " .. path .. ": " .. err, 3)
    elseif stat.type ~= "directory" then error("Could not bind " .. path .. ": Not a directory", 3) end
    return setmetatable({
        path = path
    }, {__index = self})
end

function filesystems.bind:open(process, path, mode)
    return filesystem.open(process, fs.combine(self.path, path), mode)
end

function filesystems.bind:list(process, path)
    return filesystem.list(process, fs.combine(self.path, path))
end

function filesystems.bind:stat(process, path, nolink)
    return filesystem.stat(process, fs.combine(self.path, path), nolink)
end

function filesystems.bind:remove(process, path)
    return filesystem.remove(process, fs.combine(self.path, path))
end

function filesystems.bind:rename(process, from, to)
    return filesystem.rename(process, fs.combine(self.path, from), fs.combine(self.path, to))
end

function filesystems.bind:mkdir(process, path)
    return filesystem.mkdir(process, fs.combine(self.path, path))
end

function filesystems.bind:link(process, path, location)
    return filesystem.link(process, fs.combine(self.path, path), location)
end

function filesystems.bind:mkfifo(process, path)
    return filesystem.mkfifo(process, fs.combine(self.path, path))
end

function filesystems.bind:chmod(process, path, user, mode)
    return filesystem.chmod(process, fs.combine(self.path, path), user, mode)
end

function filesystems.bind:chown(process, path, owner)
    return filesystem.chown(process, fs.combine(self.path, path), owner)
end

function filesystems.bind:info()
    return "bind", self.path, {}
end

-- Syscalls

local function dofsevent(process, path, event, dir)
    local rp = getRealPath(process, path)
    if dir then
        if rp == "" then rp = nil
        else rp = fs.getDir(rp) end
    end
    --syslog.debug("Triggering fsevents for", rp)
    if rp and fsevents[rp] then for _, v in pairs(fsevents[rp]) do
        local pp = rp
        if pp:find(v.root, 1, true) == 1 then pp = pp:sub(#v.root + 1) end
        v.eventQueue[#v.eventQueue+1] = {"fsevent", {path = pp, event = event, name = dir and fs.getName(rp) or nil, process = process.id}}
        wakeup(v)
    end end
end

--- Opens a file for reading or writing.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to open, which may be absolute or relative
-- to the process's working directory
-- @tparam string mode The mode to open the file as
-- @treturn[1] Handle The new file handle
-- @treturn[2] nil If an error occurred
-- @treturn[2] string An error message describing why the file couldn't be opened
function filesystem.open(process, path, mode)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, mode, "string")
    if not mode:match "^[rwa]b?$" then error("Invalid mode", 0) end
    for _ = 1, 1000 do
        local ok, mount, p = pcall(getMount, process, path)
        if not ok then return nil, mount end
        local res = table.pack(pcall(mount.open, mount, process, p, mode))
        if res[1] then
            if res[2] and mode ~= "r" and mode ~= "rb" then
                dofsevent(process, path, "open", false)
                dofsevent(process, path, "open_child", true)
            end
            return table.unpack(res, 2, res.n)
        elseif type(res[2]) ~= "table" or type(res[2].path) ~= "string" then error(res[2], 2) end
        path = res[2].path
    end
    error("Too many levels of symbolic links", 2)
end

local function list_inner(process, path, root)
    local retval = {}
    local mounts, p = getMount(process, path, true)
    for _, mount in ipairs(mounts) do
        local ok, res = pcall(mount.list, mount, process, p)
        if not ok then
            if type(res) ~= "table" or type(res.path) ~= "string" then
                if #mounts == 1 and root then error(res, 2)
                else res = {} end
            else res = list_inner(process, res.path, false) end
        end
        for _, v in ipairs(res) do retval[#retval+1] = v end
    end
    return retval
end

--- Returns a list of file names in the directory.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to list, which may be absolute or relative
-- to the process's working directory
-- @treturn {string} A list of file names present in the directory
function filesystem.list(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local retval = list_inner(process, path, true)
    table.sort(retval)
    return retval
end

--- Returns a table with information about the selected path.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to stat, which may be absolute or relative
-- to the process's working directory
-- @tparam boolean nolink Whether to not follow a link at the destination path,
-- returning the link itself instead of its target
-- @treturn[1] table A table with information about the path (see the docs for
-- the `stat` syscall for more info)
-- @treturn[2] nil If an error occurred
-- @treturn[2] string An error message describing why the file couldn't be opened
function filesystem.stat(process, path, nolink)
    expect(0, process, "table")
    expect(1, path, "string")
    for _ = 1, 1000 do
        local ok, mount, p, mp = pcall(getMount, process, path)
        if not ok then return nil, mount end
        local ok2, res, err = pcall(mount.stat, mount, process, p, nolink)
        if ok2 then
            if res then res.mountpoint = "/" .. mp end
            return res, err
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        path = res.path
    end
    error("Too many levels of symbolic links", 2)
end

--- Removes a file or directory.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to remove, which may be absolute or relative
-- to the process's working directory
function filesystem.remove(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    for _ = 1, 1000 do
        local mount, p = getMount(process, path)
        local ok, res = pcall(mount.remove, mount, process, p)
        if ok then
            dofsevent(process, path, "remove", false)
            dofsevent(process, path, "remove_child", true)
            return
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        path = res.path
    end
    error("Too many levels of symbolic links", 2)
end

--- Renames (moves) a file or directory.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to rename, which may be absolute or relative
-- to the process's working directory
-- @tparam The new path the file will be at, which may be in another directory
-- but must be on the same mountpoint
function filesystem.rename(process, from, to)
    expect(0, process, "table")
    expect(1, from, "string")
    expect(2, to, "string")
    for _ = 1, 1000 do
        local mountA, pA = getMount(process, from)
        local mountB, pB = getMount(process, to)
        if mountA ~= mountB then error("Attempt to rename file across two filesystems", 0) end
        local ok, res = pcall(mountA.rename, mountA, process, pA, pB)
        if ok then
            dofsevent(process, from, "rename_from", false)
            dofsevent(process, from, "rename_from_child", true)
            dofsevent(process, to, "rename_to", false)
            dofsevent(process, to, "rename_to_child", true)
            return
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        if res.orig == from then from = res.path
        else to = res.path end
    end
    error("Too many levels of symbolic links", 2)
end

--- Creates a new directory and any parent directories.
-- @tparam Process process The process to operate as
-- @tparam string path The directory to create, which may be absolute or relative
-- to the process's working directory
function filesystem.mkdir(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    for _ = 1, 1000 do
        local mount, p = getMount(process, path)
        local ok, res = pcall(mount.mkdir, mount, process, p)
        if ok then
            dofsevent(process, path, "mkdir", false)
            dofsevent(process, path, "mkdir_child", true)
            return
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        path = res.path
    end
    error("Too many levels of symbolic links", 2)
end

--- Creates a new (symbolic) link.
-- @tparam Process process The process to operate as
-- @tparam string path The path of the new link
-- @tparam string location The original path to link to
function filesystem.link(process, path, location)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, location, "string")
    if fs.combine(path) == fs.combine(location) then error("Cannot link file to itself", 2) end
    syslog.debug("Creating link", path, " => ", location)
    for _ = 1, 1000 do
        local mount, p = getMount(process, path)
        if not mount.link then error("Filesystem does not support links", 2) end
        local ok, res = pcall(mount.link, mount, process, p, location)
        if ok then
            dofsevent(process, path, "link", false)
            dofsevent(process, path, "link_child", true)
            return
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        path = res.path
    end
    error("Too many levels of symbolic links", 2)
end

--- Creates a new FIFO.
-- @tparam Process process The process to operate as
-- @tparam string path The path of the new FIFO
function filesystem.mkfifo(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    for _ = 1, 1000 do
        local mount, p = getMount(process, path)
        if not mount.mkfifo then error("Filesystem does not support FIFOs", 2) end
        local ok, res = pcall(mount.mkfifo, mount, process, p)
        if ok then
            dofsevent(process, path, "mkfifo", false)
            dofsevent(process, path, "mkfifo_child", true)
            return
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        path = res.path
    end
    error("Too many levels of symbolic links", 2)
end

--- Changes the permissions (mode) of a file or directory for the specified user.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to modify, which may be absolute or relative
-- to the process's working directory
-- @tparam string|nil user The user to change the permissions for, or `nil` for all users
-- @tparam number|string|{read = boolean?, write = boolean?, execute = boolean?} mode The
-- new permissions for the user (see the docs for the `chmod` syscall for more info)
function filesystem.chmod(process, path, user, mode)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, user, "string", "nil")
    expect(3, mode, "number", "string", "table")
    if type(mode) == "string" and not mode:match "^[%+%-=][rwxs]+$" and not mode:match "^[r%-][w%-][xs%-]$" then
        error("bad argument #3 (invalid mode)", 2)
    elseif type(mode) == "table" then
        expect.field(mode, "read", "boolean", "nil")
        expect.field(mode, "write", "boolean", "nil")
        expect.field(mode, "execute", "boolean", "nil")
    end
    for _ = 1, 1000 do
        local mount, p = getMount(process, path)
        local ok, res = pcall(mount.chmod, mount, process, p, user, mode)
        if ok then return
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        path = res.path
    end
    error("Too many levels of symbolic links", 2)
end

--- Changes the owner of a file or directory.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to modify, which may be absolute or relative
-- to the process's working directory
-- @tparam string user The user that will own the file
function filesystem.chown(process, path, user)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, user, "string")
    for _ = 1, 1000 do
        local mount, p = getMount(process, path)
        local ok, res = pcall(mount.chown, mount, process, p, user)
        if ok then return
        elseif type(res) ~= "table" or type(res.path) ~= "string" then error(res, 2) end
        path = res.path
    end
    error("Too many levels of symbolic links", 2)
end

--- Changes the root directory for the current (and future child) processes.
-- @tparam Process process The process to operate as
-- @tparam string path The path to the new root directory. This is always relative
-- to the current root.
function filesystem.chroot(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    if process.user ~= "root" then error("Could not change root: Permission denied", 2) end
    local newroot = filesystem.combine(process.root, path) .. "/"
    if newroot:find(process.root, 1, true) ~= 1 then error("Could not change root: No such file or directory", 2) end
    local s = filesystem.stat(process, "/" .. path)
    if not s then error(path .. ": No such directory", 2) end
    if s.type ~= "directory" then error(path .. ": Not a directory", 2) end
    process.root = newroot
end

--- Mounts a disk device to a path using the specified filesystem and options.
-- @tparam Process process The process to operate as
-- @tparam string type The type of filesystem to mount
-- @tparam string src The source device to mount
-- @tparam string dest The destination mountpoint
-- @tparam[opt] table options Any options to pass to the mounter
function filesystem.mount(process, type, src, dest, options)
    expect(0, process, "table")
    expect(1, type, "string")
    expect(2, src, "string")
    expect(3, dest, "string")
    expect(4, options, "table", "nil")
    if not filesystems[type] then error("No such filesystem '" .. type .. "'", 2) end
    local p = getRealPath(process, dest)
    if p == "" then
        if process.user ~= "root" then error("Could not mount to " .. dest .. ": Permission denied", 2) end
        if mounts[p] and not (options and options.overlay) then error("Could not mount to " .. dest .. ": Mount already exists (use overlay to mount over)") end
        if not mounts[p] and (options and options.overlay) then error("Could not mount to " .. dest .. ": No base mount exists for overlay") end
    else
        local stat = filesystem.stat(process, dest)
        if not stat then error("Could not mount to " .. dest .. ": No such directory", 2) end
        if stat.type ~= "directory" then error("Could not mount to " .. dest .. ": Not a directory", 2) end
        if process.user ~= "root" and not (stat.permissions[process.user] or stat.worldPermissions).write then error("Could not mount to " .. dest .. ": Permission denied", 2) end
        if mounts[p] and not (options and options.overlay) then error("Could not mount to " .. dest .. ": Mount already exists (use overlay to mount over)") end
        if not mounts[p] and (options and options.overlay) then error("Could not mount to " .. dest .. ": No base mount exists for overlay") end
    end
    local mount = filesystems[type]:new(process, src, options or {})
    if options and options.overlay then mounts[p][#mounts[p]+1] = mount
    else mounts[p] = {mount} end
end

--- Unmounts a filesystem at a mountpoint.
-- @tparam Process process The process to operate as
-- @tparam string path The mountpoint to remove, which may be absolute or relative
-- to the process's working directory
function filesystem.unmount(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    path = getRealPath(process, path)
    if not mounts[path] then error(path .. ": No such mount", 2) end
    local last = #mounts[path]
    local stat = mounts[path][last]:stat(process, "")
    if not stat then error("Internal error in unmount: could not get stat for root! Please report this to the maintainer of the target filesystem.", 2)
    elseif process.user ~= "root" and not (stat.permissions[process.user] or stat.worldPermissions).write then error(path .. ": Permission denied", 2) end
    if mounts[path][last].unmount then mounts[path][last]:unmount(process) end
    mounts[path][last] = nil
    if last == 1 then mounts[path] = nil end
end

function filesystem.mountlist(process)
    expect(0, process, "table")
    local retval = {}
    for k, v in pairs(mounts) do
        if "/" .. k .. "/" == process.root or k:find(process.root:sub(2), 1, true) == 1 then
            for _, mount in ipairs(v) do
                local type, path, options = mount:info()
                retval[#retval+1] = {path = "/" .. k, type = type, source = path, options = options}
            end
        end
    end
    return retval
end

--- Combines the specified path components into a single path.
-- @tparam string first The first path component
-- @tparam string ... Any additional path components to add
-- @treturn string The final combined path
function filesystem.combine(first, ...)
    expect(1, first, "string")
    local str = fs.combine(first, ...)
    if first:match "^/" then str = "/" .. str end
    return str
end

function syscalls.open(process, thread, ...) return filesystem.open(process, ...) end
function syscalls.list(process, thread, ...) return filesystem.list(process, ...) end
function syscalls.stat(process, thread, ...) return filesystem.stat(process, ...) end
function syscalls.remove(process, thread, ...) return filesystem.remove(process, ...) end
function syscalls.rename(process, thread, ...) return filesystem.rename(process, ...) end
function syscalls.mkdir(process, thread, ...) return filesystem.mkdir(process, ...) end
function syscalls.link(process, thread, ...) return filesystem.link(process, ...) end
function syscalls.mkfifo(process, thread, ...) return filesystem.mkfifo(process, ...) end
function syscalls.chmod(process, thread, ...) return filesystem.chmod(process, ...) end
function syscalls.chown(process, thread, ...) return filesystem.chown(process, ...) end
function syscalls.chroot(process, thread, ...) return filesystem.chroot(process, ...) end
function syscalls.mount(process, thread, ...) return filesystem.mount(process, ...) end
function syscalls.unmount(process, thread, ...) return filesystem.unmount(process, ...) end
function syscalls.mountlist(process, thread, ...) return filesystem.mountlist(process, ...) end
function syscalls.combine(process, thread, ...) return filesystem.combine(...) end

-- This syscall provides CraftOS APIs (and modules) without having to mount the entire ROM.
-- It uses the process's environment, so if the API requires other CraftOS APIs, load them
-- as globals in the process's environment first.
function syscalls.loadCraftOSAPI(process, thread, apiName)
    expect(1, apiName, "string")
    local env
    env = setmetatable({
        dofile = function(path)
            local file, err = fs.open(path, "rb")
            if not file then error("Could not open module: " .. err, 0) end
            local fn, err = load(file.readAll(), "@" .. path, nil, env)
            file.close()
            if not fn then error("Could not load module: " .. err, 0) end
            return fn()
        end,
        require = function(name)
            return env.dofile("rom/modules/main/" .. name:gsub("%.", "/") .. ".lua")
        end
    }, {__index = process.env})
    env._ENV = env
    if apiName:sub(1, 3) == "cc." then
        local path = fs.combine("rom/modules/main", apiName:gsub("%.", "/") .. ".lua")
        if not path:match "^/?rom/modules/main/" then error("Invalid module path", 0) end
        return env.dofile(path)
    else
        if not apiName:match "^[a-z]+$" then error("Invalid API name", 0) end
        local path = fs.combine("rom/apis", apiName .. ".lua")
        local file, err = fs.open(path, "rb")
        if not file then error("Could not open module: " .. err, 0) end
        local fn, err = load(file.readAll(), "@" .. path, nil, env)
        file.close()
        if not fn then error("Could not load module: " .. err, 0) end
        fn()
        local t = {}
        for k,v in pairs(env) do if k ~= "dofile" and k ~= "require" and k ~= "_ENV" then t[k] = v end end
        return t
    end
end

function syscalls.fsevent(process, thread, path, enabled)
    expect(1, path, "string")
    expect(2, enabled, "boolean", "nil")
    if enabled == nil then enabled = true end
    path = getRealPath(process, path)
    syslog.debug("Registering fsevents for", path)
    fsevents[path] = fsevents[path] or setmetatable({}, {__mode = "v"})
    fsevents[path][#fsevents[path]+1] = enabled and process or nil
end

xpcall(function()
    if args.initrd then
        if args.initrd:match "^_G%.." then
            local root = _G[args.initrd:match "^_G%.(.+)"]
            if type(root) ~= "table" then error("Requested root filesystem in global '" .. args.initrd .. "' is not a table") end
            root.src = args.initrd
            mounts[""] = {setmetatable(root, {__index = filesystems.tablefs})}
        else mounts[""] = {filesystems.tablefs:new(KERNEL, args.initrd, {})} end
    else
        local options = {}
        if args.rootflags then
            for m in args.rootflags:gmatch "[^,]+" do
                local k, v = m:match("^([^=]+)=(.*)$")
                if k and v then
                    if v == "true" then options[k] = true
                    elseif v == "false" then options[k] = false
                    else options[k] = tonumber(v) or v end
                else options[m] = true end
            end
        end
        mounts[""] = {filesystems[args.rootfstype]:new(KERNEL, args.root, options)}
    end
end, panic)