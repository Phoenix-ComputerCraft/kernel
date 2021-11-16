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

-- This is really unfinished. Please make this work properly.
mounts = {}
filesystems = {
    craftos = {
        meta = {
            meta = {
                type = "directory",
                owner = "root",
                permissions = {
                    root = {read = true, write = true, execute = true}
                },
                worldPermissions = {read = true, write = false, execute = true}
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
        filesystems.craftos.meta = unserialize(file.readAll())
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
                    owner = "root",                     -- TODO: maybe set this to the parent's permissions? (Would maybe make more sense)
                    permissions = {
                        root = {read = true, write = true, execute = true}
                    },
                    worldPermissions = {read = true, write = false, execute = true}
                },
                contents = {}
            } end
            stack[#stack+1] = t
            t = t.contents[p]
            -- TODO: handle link traversal
            --if t and t.meta.type == "link" then t = ? end
        end
    end
    t.meta = {
        type = meta.type,
        owner = meta.owner,
        permissions = meta.permissions,
        worldPermissions = meta.worldPermissions
    }
    if meta.type ~= "directory" then t.contents = nil end
    local file = fs.open("/meta.ltn", "w")
    file.write(serialize(self.meta))
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
            if not pok then
                local mok, err = pcall(self.mkdir, self, process, fs.getDir(path))
                if not mok then return nil, err:gsub("kernel:%d: ", "") end
                pstat = self:stat(process, fs.getDir(path))
            end
            local perms = pstat.permissions[process.user] or pstat.worldPermissions
            if not perms.write then return nil, "Permission denied" end
            local meta = {
                type = "file",
                owner = process.user,
                permissions = deepcopy(pstat.permissions),
                worldPermissions = deepcopy(pstat.worldPermissions)
            }
            -- We do a swap here so it doesn't break if pstat.owner == process.user
            local t = meta.permissions[pstat.owner]
            meta.permissions[pstat.owner] = nil
            meta.permissions[process.user] = t
            self:setmeta(process.user, fs.combine(self.path, path), meta)
            return fs.open(fs.combine(self.path, path), mode)
        else return nil, "File not found" end
    elseif stat.type == "directory" then return nil, "Is a directory" end
    local perms = stat.permissions[process.user] or stat.worldPermissions
    --syslog.debug(path, mode, perms.read, perms.write, perms.execute)
    if (mode:sub(1, 1) == "r" and not perms.read) or ((mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a") and not perms.write) then return nil, "Permission denied" end
    return fs.open(fs.combine(self.path, path), mode)
end

function filesystems.craftos:list(process, path)
    local stat = self:stat(process, path)
    if not stat or stat.type ~= "directory" then error(path .. ": Not a directory", 2) end
    local perms = stat.permissions[process.user] or stat.worldPermissions
    if not perms.read then error(path .. ": Permission denied", 2) end
    return fs.list(fs.combine(self.path, path))
end

function filesystems.craftos:stat(process, path)
    local p = fs.combine(self.path, path)
    if not p:find(self.path:gsub("^/", ""):gsub("/$", ""), 1, false) then return nil end
    local ok, attr = pcall(fs.attributes, p)
    if not ok or not attr then return nil end
    attr.type = attr.isDir and "directory" or "file"
    attr.special = {}
    attr.isDir = nil
    attr.modification = nil
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
    else
        attr.owner = "root" -- all files are root-owned by default
        attr.permissions = {
            root = {read = true, write = true, execute = true}
        }
        attr.worldPermissions = {read = true, write = false, execute = true}
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
        if not perms.write then error(p .. ": Permission denied", 3) end
        if s.type == "directory" then
            if not perms.read then error(p .. ": Permission denied", 3) end
            for _, v in ipairs(fs.list(fs.combine(self.path, p))) do checkWriteRecursive(fs.combine(p, v)) end
        end
    end
    checkWriteRecursive(path)
    fs.remove(fs.combine(self.path, path))
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
    local perms = tostat.permissions[process.user] or tostat.worldPermissions
    if not perms.write then error(to .. ": Permission denied", 2) end
    fs.move(fs.combine(self.path, from), fs.combine(self.path, to))
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
    local perms = stat.permissions[process.user] or stat.worldPermissions
    if not perms.write then error(path .. ": Permission denied", 2) end
    local meta = {
        type = "directory",
        owner = process.user,
        permissions = deepcopy(stat.permissions),
        worldPermissions = deepcopy(stat.worldPermissions)
    }
    local t = meta.permissions[stat.owner]
    meta.permissions[stat.owner] = nil
    meta.permissions[process.user] = t
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
        perms = stat.permissions[process.user]
        if not perms then
            perms = deepcopy(stat.worldPermissions)
            stat.permissions[process.user] = perms
        end
    end
    if type(mode) == "string" then
        if mode:match "^[+-=][rwx]+$" then
            local m = mode:sub(1, 1)
            local t = {}
            for c in mode:gmatch("[rwx]") do
                if c == "r" then t.read = true
                elseif c == "w" then t.write = true
                else t.execute = true end
            end
            if m == "+" then
                if t.read then perms.read = true end
                if t.write then perms.write = true end
                if t.execute then perms.execute = true end
            elseif m == "-" then
                if t.read then perms.read = false end
                if t.write then perms.write = false end
                if t.execute then perms.execute = false end
            else
                perms.read = t.read or false
                perms.write = t.write or false
                perms.execute = t.execute or false
            end
        else
            perms.read = mode:sub(1, 1) ~= "-"
            perms.write = mode:sub(2, 2) ~= "-"
            perms.execute = mode:sub(3, 3) ~= "-"
        end
    elseif type(mode) == "number" then
        perms.read = bit32.band(mode, 4)
        perms.write = bit32.band(mode, 2)
        perms.execute = bit32.band(mode, 1)
    else
        if mode.read ~= nil then perms.read = mode.read end
        if mode.write ~= nil then perms.write = mode.write end
        if mode.execute ~= nil then perms.execute = mode.execute end
    end
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat))
end

function filesystems.craftos:chown(process, path, owner)
    if self.readOnly then error(path .. ": Read-only filesystem", 2) end
    local stat = self:stat(process, path)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    stat.owner = owner
    self:setmeta(process.user, fs.combine(self.path, path), deepcopy(stat))
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
            created = os.epoch "utc",
            modified = os.epoch "utc",
            contents = {}
        } end
        t = t.contents[p]
        -- TODO: handle link traversal
        --if t and t.meta.type == "link" then t = ? end
    end
    if t.type ~= "directory" then error("Not a directory", 2)
    elseif t.permissions[user] then if not t.permissions[user].execute then error("Permission denied", 2) end
    elseif not t.worldPermissions.execute then error("Permission denied", 2) end
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
        created = os.epoch "utc",
        modified = os.epoch "utc",
        contents = {}
    }, {__index = self})
end

-- TODO: check if this exposes any vulnerabilities through upvalues (dbprotect required?)
function filesystems.tmpfs:_open_internal(user, path, mode)
    local pos = 0
    local closed = false
    if mode == "r" then
        local data = self:getpath(user, path).data
        return {
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
        local data = self:getpath(user, path)
        if mode == "w" then data.data, data.modified = "", os.epoch "utc" else pos = #data.data end
        local buf = data.data
        return {
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
                data.data, data.modified = buf, os.epoch "utc"
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                data.data, data.modified = buf, os.epoch "utc"
                closed = true
            end
        }
    elseif mode == "rb" then
        local data = self:getpath(user, path).data
        return {
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
                if whence == "set" then pos = offset
                elseif whence == "cur" then pos = pos + offset
                elseif whence == "end" then pos = #data - offset
                else error("Invalid whence", 2) end
                return pos
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                closed = true
            end
        }
    elseif mode == "wb" or mode == "ab" then
        local data = self:getpath(user, path)
        if mode == "wb" then data.data, data.modified = "", os.epoch "utc" else pos = #data.data end
        local buf = data.data
        return {
            write = function(d)
                if closed then error("attempt to use a closed file", 2) end
                if type(d) == "number" then buf = buf:sub(1, pos - 1) .. string.char(d) .. buf:sub(pos)
                elseif type(d) == "string" then buf = buf:sub(1, pos - 1) .. d .. buf:sub(pos)
                else error("bad argument #1 (expected string or number, got " .. type(d) .. ")", 2) end
            end,
            seek = function(whence, offset)
                if whence ~= nil and type(whence) ~= "string" then error("bad argument #1 (expected string, got " .. type(whence) .. ")", 2) end
                if offset ~= nil and type(offset) ~= "number" then error("bad argument #2 (expected number, got " .. type(offset) .. ")", 2) end
                whence = whence or "cur"
                offset = offset or 0
                if closed then error("attempt to use closed file", 2) end
                if whence == "set" then pos = offset
                elseif whence == "cur" then pos = pos + offset
                elseif whence == "end" then pos = #buf - offset
                else error("Invalid whence", 2) end
                return pos
            end,
            flush = function()
                if closed then error("attempt to use a closed file", 2) end
                data.data, data.modified = buf, os.epoch "utc"
            end,
            close = function()
                if closed then error("attempt to use a closed file", 2) end
                data.data, data.modified = buf, os.epoch "utc"
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
            local perms = pstat.permissions[process.user] or pstat.worldPermissions
            if not perms.write then return nil, "Permission denied" end
            local meta = {
                type = "file",
                owner = process.user,
                permissions = deepcopy(pstat.permissions),
                worldPermissions = deepcopy(pstat.worldPermissions),
                created = os.epoch "utc",
                modified = os.epoch "utc",
                data = ""
            }
            -- We do a swap here so it doesn't break if pstat.owner == process.user
            local t = meta.permissions[pstat.owner]
            meta.permissions[pstat.owner] = nil
            meta.permissions[process.user] = t
            self:setpath(process.user, path, meta)
            return self:_open_internal(process.user, path, mode)
        else return nil, "File not found" end
    elseif stat.type == "directory" then return nil, "Is a directory" end
    local perms = stat.permissions[process.user] or stat.worldPermissions
    --syslog.debug(path, mode, perms.read, perms.write, perms.execute)
    if (mode:sub(1, 1) == "r" and not perms.read) or ((mode:sub(1, 1) == "w" or mode:sub(1, 1) == "a") and not perms.write) then return nil, "Permission denied" end
    return self:_open_internal(process.user, path, mode)
end

function filesystems.tmpfs:list(process, path)
    local data = self:getpath(process.user, path)
    if not data or data.type ~= "directory" then error(path .. ": Not a directory", 2) end
    local perms = data.permissions[process.user] or data.worldPermissions
    if not perms.read then error(path .. ": Permission denied", 2) end
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
        special = {}
    }
end

function filesystems.tmpfs:remove(process, path)
    local parent = self:getpath(process.user, fs.getDir(path))
    local name = fs.getName(path)
    if not parent or parent.type ~= "directory" or not parent.contents[name] then return end
    if not (parent.permissions[process.user] or parent.worldPermissions).write then error(path .. ": Permission denied", 2) end
    local data = parent.contents[name]
    if not (data.permissions[process.user] or data.worldPermissions).write then error(path .. ": Permission denied", 2) end
    local function checkWriteRecursive(s)
        local perms = s.permissions[process.user] or s.worldPermissions
        if not perms.write then error(path .. ": Permission denied", 3) end
        if s.type == "directory" then
            if not perms.read then error(path .. ": Permission denied", 3) end
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
    if not (fparent.permissions[process.user] or fparent.worldPermissions).write then error(from .. ": Permission denied", 2) end
    local fdata = fparent.contents[fname]
    if not (fdata.permissions[process.user] or fdata.worldPermissions).write then error(from .. ": Permission denied", 2) end
    local tparent = self:getpath(process.user, fs.getDir(to))
    local tname = fs.getName(to)
    if not tparent or tparent.type ~= "directory" then error(to .. ": No such file or directory", 2) end
    if not (tparent.permissions[process.user] or tparent.worldPermissions).write then error(to .. ": Permission denied", 2) end
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
        elseif not perms.execute then error(path .. ": Permission denied", 2) end
        if not t.contents[p] then
            if not perms.write then error(path .. ": Permission denied", 2) end
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
        perms = stat.permissions[process.user]
        if not perms then
            perms = deepcopy(stat.worldPermissions)
            stat.permissions[process.user] = perms
        end
    end
    if type(mode) == "string" then
        if mode:match "^[+-=][rwx]+$" then
            local m = mode:sub(1, 1)
            local t = {}
            for c in mode:gmatch("[rwx]") do
                if c == "r" then t.read = true
                elseif c == "w" then t.write = true
                else t.execute = true end
            end
            if m == "+" then
                if t.read then perms.read = true end
                if t.write then perms.write = true end
                if t.execute then perms.execute = true end
            elseif m == "-" then
                if t.read then perms.read = false end
                if t.write then perms.write = false end
                if t.execute then perms.execute = false end
            else
                perms.read = t.read or false
                perms.write = t.write or false
                perms.execute = t.execute or false
            end
        else
            perms.read = mode:sub(1, 1) ~= "-"
            perms.write = mode:sub(2, 2) ~= "-"
            perms.execute = mode:sub(3, 3) ~= "-"
        end
    elseif type(mode) == "number" then
        perms.read = bit32.band(mode, 4)
        perms.write = bit32.band(mode, 2)
        perms.execute = bit32.band(mode, 1)
    else
        if mode.read ~= nil then perms.read = mode.read end
        if mode.write ~= nil then perms.write = mode.write end
        if mode.execute ~= nil then perms.execute = mode.execute end
    end
    --self:setpath(process.user, fs.combine(self.path, path), deepcopy(stat)) -- may not be needed?
end

function filesystems.tmpfs:chown(process, path, owner)
    local stat = self:getpath(process.user, path)
    if not stat then error(path .. ": No such file or directory", 2) end
    if not stat.owner or (process.user ~= "root" and process.user ~= stat.owner) then error(path .. ": Permission denied", 2) end
    stat.owner = owner
    --self:setpath(process.user, fs.combine(self.path, path), deepcopy(stat))
end

-- drivefs implementation
-- drivefs just inherits from craftos, but automatically locates drive mounts from sides.

function filesystems.drivefs:new(process, src, options)
    local path
    if peripheral.isPresent(src) then
        if peripheral.getType(src) == "drive" then
            if peripheral.call(src, "isDiskPresent") then path = peripheral.call(src, "getMountPath")
            else error("Drive has no disk inserted", 2) end
        else error("Peripheral is not a drive", 2) end
    else
        for _, v in ipairs(redstone.getSides()) do
            if peripheral.getType(v) == "modem" and not peripheral.call(v, "isWireless") and peripheral.call(v, "isPresentRemote", src) then
                if peripheral.call(v, "getTypeRemote", src) == "drive" then
                    if peripheral.call(v, "callRemote", src, "isDiskPresent") then path = peripheral.call(v, "callRemote", src, "getMountPath") break
                    else error("Drive has no disk inserted", 2) end
                else error("Peripheral is not a drive", 2) end
            end
        end
    end
    if not path then error("Could not find drive at " .. src, 2) end
    return filesystems.craftos:new(process, path, options)
end

-- Syscalls

local function getMount(process, path)
    local fullPath = split(fs.combine(path:sub(1, 1) == "/" and "" or process.dir, path), "/\\")
    if #fullPath == 0 then return mounts[""], path end
    local maxPath
    for k in pairs(mounts) do
        local ok = true
        for i,c in ipairs(split(k, "/\\")) do if fullPath[i] ~= c then ok = false break end end
        if ok and (not maxPath or #k > #maxPath) then maxPath = k end
    end
    if not maxPath then panic("Could not find mount for path " .. path .. ". Where is root?") end
    local parts = split(maxPath, "/\\")
    local p = #fullPath >= #parts + 1 and fs.combine(table.unpack(fullPath, #parts + 1, #fullPath)) or ""
    syslog.debug(path, #parts, #fullPath, p)
    return mounts[maxPath], p
end

function filesystem.open(process, path, mode)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, mode, "string")
    if not mode:match "^[rwa]b?$" then error("Invalid mode", 0) end
    local mount, p = getMount(process, path)
    return mount:open(process, p, mode)
end

function filesystem.list(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:list(process, p)
end

function filesystem.stat(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:stat(process, p)
end

function filesystem.remove(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:remove(process, p)
end

function filesystem.rename(process, from, to)
    expect(0, process, "table")
    expect(1, from, "string")
    expect(2, to, "string")
    local mountA, pA = getMount(process, from)
    local mountB, pB = getMount(process, to)
    if mountA ~= mountB then error("Attempt to rename file across two filesystems", 0) end
    return mountA:rename(process, pA, pB)
end

function filesystem.mkdir(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    local mount, p = getMount(process, path)
    return mount:mkdir(process, p)
end

function filesystem.chmod(process, path, user, mode)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, user, "string", "nil")
    expect(3, mode, "number", "string", "table")
    if type(mode) == "string" and not mode:match "^[+-=][rwx]+$" and not mode:match "^[r-][w-][x-]$" then
        error("bad argument #2 (invalid mode)", 2)
    elseif type(mode) == "table" then
        expect.field(mode, "read", "boolean", "nil")
        expect.field(mode, "write", "boolean", "nil")
        expect.field(mode, "execute", "boolean", "nil")
    end
    local mount, p = getMount(process, path)
    return mount:chmod(process, p, user, mode)
end

function filesystem.chown(process, path, user)
    expect(0, process, "table")
    expect(1, path, "string")
    expect(2, user, "string")
    local mount, p = getMount(process, path)
    return mount:chown(process, p, user)
end

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
    elseif not (stat.permissions[process.user] or stat.worldPermissions).write then error("Could not mount to " .. dest .. ": Permission denied", 2) end
    local mount = filesystems[type]:new(process, src, options or {})
    mounts[fs.combine(dest)] = mount
end

function filesystem.unmount(process, path)
    expect(0, process, "table")
    expect(1, path, "string")
    if not mounts[fs.combine(path)] then error(path .. ": No such mount", 2) end
    local stat = mounts[fs.combine(path)]:stat(process, "")
    if not stat then error("Internal error in unmount: could not get stat for root! Please report this to the maintainer of the target filesystem.", 2)
    elseif not (stat.permissions[process.user] or stat.worldPermissions).write then error(path .. ": Permission denied", 2) end
    mounts[fs.combine(path)] = nil
end

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
function syscalls.combine(process, thread, ...) return filesystem.combine(...) end

-- This syscall provides CraftOS APIs (and modules) without having to mount the entire ROM.
-- It uses the process's environment, so if the API requires other CraftOS APIs, load them
-- as globals in the process's environment first.
function syscalls.loadCraftOSAPI(process, thread, apiName)
    expect(1, apiName, "string")
    local env
    env = setmetatable({dofile = function(path)
        local file, err = fs.open(path, "rb")
        if not file then error("Could not open module: " .. err, 0) end
        local fn, err = load(file.readAll(), "@" .. path, nil, env)
        file.close()
        if not fn then error("Could not load module: " .. err, 0) end
        return fn()
    end}, {__index = process.env})
    if apiName:sub(1, 3) == "cc." then
        local path = fs.combine("rom/modules/main", apiName:gmatch("%.", "/") .. ".lua")
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