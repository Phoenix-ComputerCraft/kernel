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

-- TODO: Add disk space metrics
-- TODO: Add links, FIFOs, special file support

--- Stores the current mounts as a key-value table of paths to filesystem objects.
mounts = {}

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
        }
    },
    tmpfs = {},
    drivefs = {}
}

-- craftos fs implementation

do
    local file = fs.open("/meta.ltn", "r")
    if file then
        filesystems.craftos.meta = unserialize(file.readAll()) or filesystems.craftos.meta
        file.close()
    end
end

function filesystems.craftos:getmeta(user, path)
    local stack = {}
    local t = self.meta
    for _,p in ipairs(split(path, "/\\")) do
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
            -- TODO: handle link traversal
            --if t and t.meta.type == "link" then t = ? end
        end
    end
    return t and t.meta
end

function filesystems.craftos:setmeta(user, path, meta)
    local stack = {}
    local t = self.meta
    local name
    for _,p in ipairs(split(path, "/\\")) do
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
                    owner = t.meta.owner or "root",     -- TODO: maybe set this to the parent's permissions? (Would maybe make more sense)
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
            -- TODO: handle link traversal
            --if t and t.meta.type == "link" then t = ? end
        end
    end
    if meta ~= nil then
        t.meta = {
            type = meta.type,
            owner = meta.owner,
            permissions = deepcopy(meta.permissions),
            worldPermissions = deepcopy(meta.worldPermissions),
            setuser = meta.setuser
        }
        if meta.type ~= "directory" then t.contents = nil end
    else stack[#stack].contents[name] = nil end
    local file = fs.open("/meta.ltn", "w")
    file.write(serialize(self.meta, {compact = true}))
    file.close()
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
    if not ok then return nil, stat
    elseif not stat then
        if mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a" then
            if self.readOnly then return nil, "Read-only filesystem" end
            local pok, pstat = pcall(self.stat, self, process, fs.getDir(path))
            if not pok or not pstat then
                local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
                if not mok then return nil, err:gsub("kernel:%d: ", "") end
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
    if (mode:sub(1, 1) == "r" and not perms.read) or ((mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a") and not perms.write) then return nil, "Permission denied" end
    return setmetatable(fs.open(fs.combine(self.path, path), mode), {__name = "file"})
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
function filesystems.craftos:stat(process, path)
    local p = fs.combine(self.path, path)
    if p:find(self.path:gsub("^/", ""):gsub("/$", ""), 1, false) ~= 1 then return nil end
    local ok, attr = pcall(fs.attributes, p)
    if not ok or not attr then return nil end
    attr.type = attr.isDir and "directory" or "file"
    attr.special = {}
    attr.isDir = nil
    if not attr.modified then attr.modified = attr.modification end
    attr.modification = nil
    attr.capacity = fs.getCapacity(p)
    attr.freeSpace = fs.getFreeSpace(p)
    if attr.isReadOnly then
        -- If the file is read-only, it's from the ROM so permissions can't be set
        -- No owner
        attr.permissions = {}
        attr.worldPermissions = {read = true, write = false, execute = true}
        return attr
    end
    attr.isReadOnly = nil
    local meta = self:getmeta(process.user, fs.combine(self.path, path))
    -- The path may exist on the filesystem but have no metadata.
    if meta then
        attr.owner = meta.owner
        attr.permissions = deepcopy(meta.permissions)
        attr.worldPermissions = deepcopy(meta.worldPermissions)
        attr.type = meta.type or attr.type
        attr.setuser = meta.setuser
    else
        attr.owner = "root" -- all files are root-owned by default
        attr.permissions = {
            root = {read = true, write = true, execute = true}
        }
        attr.worldPermissions = {read = true, write = false, execute = true}
        attr.setuser = false
    end
    return attr
end

function filesystems.craftos:remove(process, path)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path)
    if not stat then return end
    local function checkWriteRecursive(p)
        local s = self:stat(process, p)
        local perms = s.permissions[process.user] or s.worldPermissions
        if process.user ~= "root" and not perms.write then error(p .. ": Permission denied", 3) end
        if s.type == "directory" then
            if process.user ~= "root" and not perms.read then error(p .. ": Permission denied", 3) end
            for _, v in ipairs(fs.list(fs.combine(self.path, p))) do checkWriteRecursive(fs.combine(p, v)) end
        end
    end
    checkWriteRecursive(path)
    fs.delete(fs.combine(self.path, path))
    self:setmeta(process.user, fs.combine(self.path, path), nil)
end

function filesystems.craftos:rename(process, from, to)
    if self.readOnly then error("Read-only filesystem", 2) end
    local fromstat = self:stat(process, from)
    local tostat = self:stat(process, to)
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
    self:setmeta(process.user, fs.combine(self.path, to), self:getmeta(process.user, fs.combine(self.path, from)))
    self:setmeta(process.user, fs.combine(self.path, from), nil)
end

function filesystems.craftos:mkdir(process, path)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path)
    if stat then
        if stat.type == "directory" then return
        else error(path .. ": File already exists", 2) end
    end
    local parts = split(path, "/\\")
    local i = #parts - 1
    repeat
        stat = self:stat(process, table.concat(parts, "/", 1, i))
        if stat then
            if stat.type == "directory" then break
            else error(path .. ": File already exists", 2) end
        end
        i=i-1
    until stat or i <= 0
    if path:match "^/" then stat = assert(self:stat(process, "/"))
    else stat = assert(self:stat(process, process.dir)) end
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
        self:setmeta(process.user, fs.combine(self.path, table.concat(parts, 1, i)), deepcopy(meta))
        i=i+1
    end
    fs.makeDir(fs.combine(self.path, path))
end

function filesystems.craftos:chmod(process, path, user, mode)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path)
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
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat))
end

function filesystems.craftos:chown(process, path, owner)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    stat.owner = owner
    stat.setuser = false
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat))
end

function filesystems.craftos:info()
    return "craftos", self.path, {ro = self.readOnly}
end

-- tmpfs implementation
-- tmpfs stores data in the same format as craftos meta, but with the addition of storing file data in .data

function filesystems.tmpfs:getpath(user, path)
    local t = self
    for _,p in ipairs(split(path, "/\\")) do
        if not t then return nil
        elseif t.type ~= "directory" then error("Not a directory", 2)
        elseif t.permissions[user] then if not t.permissions[user].execute then error("Permission denied", 2) end
        elseif not t.worldPermissions.execute then error("Permission denied", 2) end
        t = t.contents[p]
        -- TODO: handle link traversal
        --if t and t.meta.type == "link" then t = ? end
    end
    return t
end

function filesystems.tmpfs:setpath(user, path, data)
    local t = self
    local e = split(path, "/\\")
    local last = e[#e]
    e[#e] = nil
    for _,p in ipairs(e) do
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
        -- TODO: handle link traversal
        --if t and t.meta.type == "link" then t = ? end
    end
    if t.type ~= "directory" then error("Not a directory", 2)
    elseif user ~= "root" then
        if t.permissions[user] then if not t.permissions[user].execute then error("Permission denied", 2) end
        elseif not t.worldPermissions.execute then error("Permission denied", 2) end
    end
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
    local pos = 1
    local closed = false
    local function setenv(t)
        for _, v in pairs(t) do setfenv(v, process.env) debug.protect(v) end
        return setmetatable(t, {__name = "file"})
    end
    local epoch = os.epoch
    if mode == "r" then
        local data = self:getpath(process.user, path).data
        return setenv {
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
    elseif mode == "w" or mode == "a" then
        local data = self:getpath(process.user, path)
        if mode == "w" then data.data, data.modified = "", epoch "utc" else pos = #data.data end
        local buf = data.data
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
                data.data, data.modified = buf, epoch "utc"
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                data.data, data.modified = buf, epoch "utc"
                closed = true
            end
        }
    elseif mode == "rb" then
        local data = self:getpath(process.user, path).data
        return setenv {
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
            end,
            seek = function(whence, offset)
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
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                closed = true
            end
        }
    elseif mode == "wb" or mode == "ab" then
        local data = self:getpath(process.user, path)
        if mode == "wb" then data.data, data.modified = "", epoch "utc" else pos = #data.data end
        local buf = data.data
        return setenv {
            write = function(d)
                if closed then error("attempt to use a closed file", 2) end
                if type(d) == "number" then buf, pos = buf:sub(1, pos - 1) .. string.char(d) .. buf:sub(pos + 1), pos + 1
                elseif type(d) == "string" then buf, pos = buf:sub(1, pos - 1) .. d .. buf:sub(pos + #d), pos + #d
                else error("bad argument #1 (expected string or number, got " .. type(d) .. ")", 2) end
            end,
            writeLine = function(d)
                if closed then error("attempt to use a closed file", 2) end
                if type(d) == "number" then buf, pos = buf:sub(1, pos - 1) .. string.char(d) .. "\n" .. buf:sub(pos + 2), pos + 2
                elseif type(d) == "string" then buf, pos = buf:sub(1, pos - 1) .. d .. "\n" .. buf:sub(pos + #d + 1), pos + #d + 1
                else error("bad argument #1 (expected string or number, got " .. type(d) .. ")", 2) end
            end,
            seek = function(whence, offset)
                if whence ~= nil and type(whence) ~= "string" then error("bad argument #1 (expected string, got " .. type(whence) .. ")", 2) end
                if offset ~= nil and type(offset) ~= "number" then error("bad argument #2 (expected number, got " .. type(offset) .. ")", 2) end
                whence = whence or "cur"
                offset = offset or 0
                if closed then error("attempt to use closed file", 2) end
                if whence == "set" then pos = offset + 1
                elseif whence == "cur" then pos = pos + offset
                elseif whence == "end" then pos = math.max(#buf - offset, 1)
                else error("Invalid whence", 2) end
                return pos - 1
            end,
            flush = function()
                if closed then error("attempt to use a closed file", 2) end
                data.data, data.modified = buf, epoch "utc"
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                data.data, data.modified = buf, epoch "utc"
                closed = true
            end
        }
    else return nil, "Invalid mode" end
end

function filesystems.tmpfs:open(process, path, mode)
    local ok, stat = pcall(self.stat, self, process, path)
    if not ok then return nil, stat
    elseif not stat then
        if mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a" then
            local pok, pstat = pcall(self.stat, self, process, fs.getDir(path))
            if not pok then
                local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
                if not mok then return nil, err:gsub("kernel:%d: ", "") end
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

function filesystems.tmpfs:stat(process, path)
    local data = self:getpath(process.user, path)
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
        special = {}
    }
end

function filesystems.tmpfs:remove(process, path)
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

function filesystems.tmpfs:chmod(process, path, user, mode)
    local stat = self:getpath(process.user, path)
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
    --self:setpath(process.user, fs.combine(self.path, path), deepcopy(stat)) -- may not be needed?
end

function filesystems.tmpfs:chown(process, path, owner)
    local stat = self:getpath(process.user, path)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    stat.owner = owner
    stat.setuser = false
    --self:setpath(process.user, fs.combine(self.path, path), deepcopy(stat))
end

function filesystems.tmpfs:info()
    return "tmpfs", "memory", {}
end

-- drivefs implementation
-- drivefs just inherits from craftos, but automatically locates drive mounts from hardware devices.

setmetatable(filesystems.drivefs, {__index = filesystems.craftos})

function filesystems.drivefs:new(process, src, options)
    local drive = hardware.get(src)
    if not drive then error("Could not find drive at " .. src) end
    local fs = filesystems.craftos:new(process, hardware.call(process, drive, "getMountPath"), options)
    fs.drive = drive.uuid
    return setmetatable(fs, {__index = self})
end

function filesystems.drivefs:info()
    return "drivefs", self.drive, {ro = self.readOnly}
end

-- Syscalls

local function getMount(process, path)
    local fullPath = split(fs.combine(path:sub(1, 1) == "/" and "" or process.dir, path), "/\\")
    if #fullPath == 0 then return mounts[""], path, "" end
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
    return mounts[maxPath], p, maxPath
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
    local mount, p = getMount(process, path)
    return mount:open(process, p, mode)
end

--- Returns a list of file names in the directory.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to list, which may be absolute or relative
-- to the process's working directory
-- @treturn {string} A list of file names present in the directory
function filesystem.list(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:list(process, p)
end

--- Returns a table with information about the selected path.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to stat, which may be absolute or relative
-- to the process's working directory
-- @treturn[1] table A table with information about the path (see the docs for
-- the `stat` syscall for more info)
-- @treturn[2] nil If an error occurred
-- @treturn[2] string An error message describing why the file couldn't be opened
function filesystem.stat(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p, mp = getMount(process, path)
    local res, err = mount:stat(process, p)
    if res then res.mountpoint = "/" .. mp end
    return res, err
end

--- Removes a file or directory.
-- @tparam Process process The process to operate as
-- @tparam string path The file path to remove, which may be absolute or relative
-- to the process's working directory
function filesystem.remove(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:remove(process, p)
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
    local mountA, pA = getMount(process, from)
    local mountB, pB = getMount(process, to)
    if mountA ~= mountB then error("Attempt to rename file across two filesystems", 0) end
    return mountA:rename(process, pA, pB)
end

--- Creates a new directory and any parent directories.
-- @tparam Process process The process to operate as
-- @tparam string path The directory to create, which may be absolute or relative
-- to the process's working directory
function filesystem.mkdir(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:mkdir(process, p)
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
    local mount, p = getMount(process, path)
    return mount:chmod(process, p, user, mode)
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
    local mount, p = getMount(process, path)
    return mount:chown(process, p, user)
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
    local stat = filesystem.stat(process, dest)
    if not stat then error("Could not mount to " .. dest .. ": No such directory", 2)
    elseif stat.type ~= "directory" then error("Could not mount to " .. dest .. ": Not a directory", 2)
    elseif process.user ~= "root" and not (stat.permissions[process.user] or stat.worldPermissions).write then error("Could not mount to " .. dest .. ": Permission denied", 2) end
    local mount = filesystems[type]:new(process, src, options or {})
    mounts[fs.combine(dest)] = mount
end

--- Unmounts a filesystem at a mountpoint.
-- @tparam Process process The process to operate as
-- @tparam string path The mountpoint to remove, which may be absolute or relative
-- to the process's working directory
function filesystem.unmount(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    if not mounts[fs.combine(path)] then error(path .. ": No such mount", 2) end
    local stat = mounts[fs.combine(path)]:stat(process, "")
    if not stat then error("Internal error in unmount: could not get stat for root! Please report this to the maintainer of the target filesystem.", 2)
    elseif process.user ~= "root" and not (stat.permissions[process.user] or stat.worldPermissions).write then error(path .. ": Permission denied", 2) end
    mounts[fs.combine(path)] = nil
end

function filesystem.mountlist(process)
    expect(0, process, "table")
    local retval = {}
    for k, v in pairs(mounts) do
        local type, path, options = v:info()
        retval[#retval+1] = {path = k, type = type, source = path, options = options}
    end
    return retval
end

--- Combines the specified path components into a single path.
-- @tparam string first The first path component
-- @tparam string ... Any additional path components to add
-- @treturn string The final combined path
function filesystem.combine(first, ...)
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
function syscalls.chmod(process, thread, ...) return filesystem.chmod(process, ...) end
function syscalls.chown(process, thread, ...) return filesystem.chown(process, ...) end
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
        for k,v in pairs(env) do if k ~= "dofile" then t[k] = v end end
        return t
    end
end

mounts[""] = filesystems[args.rootfstype]:new(KERNEL, args.root, {})