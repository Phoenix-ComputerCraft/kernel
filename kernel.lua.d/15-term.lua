-- TODO: implement graphics compatibility

local function makeTTY(width, height)
    local retval = {
        isTTY = true,
        flags = {
            cbreak = false,
            delay = true,
            echo = true,
            keypad = false,
            nlcr = true,
            raw = false,
        },
        cursor = {x = 1, y = 1},
        cursorBlink = true,
        colors = {fg = '0', bg = 'f', bold = false},
        size = {width = width, height = height},
        dirtyLines = {},
        palette = {},
        dirtyPalette = {}
    }
    for y = 1, height do
        retval[y] = {(' '):rep(width), ('0'):rep(width), ('f'):rep(width)}
        retval.dirtyLines[y] = true
    end
    for i = 0, 15 do
        retval.palette[i] = {term.nativePaletteColor(2^i)}
        retval.dirtyPalette[i] = true
    end
    return retval
end

do
    local term_width, term_height = term.getSize()
    TTY = {
        makeTTY(term_width, term_height),
        makeTTY(term_width, term_height),
        makeTTY(term_width, term_height),
        makeTTY(term_width, term_height),
        makeTTY(term_width, term_height),
        makeTTY(term_width, term_height),
        makeTTY(term_width, term_height),
        makeTTY(term_width, term_height)
    }
end
currentTTY = TTY[1]

do
    local n = args.console:match "^tty(%d+)$"
    if n then KERNEL.stdout, KERNEL.stderr = TTY[tonumber(n)], TTY[tonumber(n)] end
end

eventHooks.term_resize = eventHooks.term_resize or {}
eventHooks.term_resize[#eventHooks.term_resize+1] = function()
    local w, h = term.getSize()
    --for i = 1, 8 do TTY[i]:resize(w, h) end
end

function terminal.redraw(tty, full)
    if currentTTY ~= tty then return end
    term.setCursorBlink(false)
    if full then
        term.clear()
        for y = 1, tty.size.height do
            term.setCursorPos(1, y)
            term.blit(tty[y][1], tty[y][2], tty[y][3])
        end
        for i = 0, 15 do term.setPaletteColor(2^i, tty.palette[i][1], tty.palette[i][2], tty.palette[i][3]) end
    else
        for y in pairs(tty.dirtyLines) do
            if not tty[y] then error(debug.traceback(y)) end
            term.setCursorPos(1, y)
            if #tty[y][1] ~= #tty[y][2] or #tty[y][2] ~= #tty[y][3] then
                syslog.log({level = 5}, "Bug in text writer! Inequal lengths: " .. #tty[y][1] .. ", " .. #tty[y][2] .. ", " .. #tty[y][3])
                error("Invalid lengths")
            end
            term.blit(tty[y][1], tty[y][2], tty[y][3])
        end
        for i in pairs(tty.dirtyPalette) do term.setPaletteColor(2^i, tty.palette[i][1], tty.palette[i][2], tty.palette[i][3]) end
    end
    term.setCursorPos(tty.cursor.x, tty.cursor.y)
    term.setCursorBlink(tty.cursorBlink)
    tty.dirtyLines, tty.dirtyPalette = {}, {}
end

local function nextline(tty)
    tty.cursor.y = tty.cursor.y + 1
    if tty.cursor.y > tty.size.height then
        table.remove(tty, 1)
        tty[tty.size.height] = {(' '):rep(tty.size.width), tty.colors.fg:rep(tty.size.width), tty.colors.bg:rep(tty.size.width)}
        tty.cursor.y = tty.size.height
    end
end

-- TODO: We could probably optimize a lot of the table indexes here to speed things up.
--       This will become important as things start needing to write quickly.
--       The biggest improvement will likely come from caching `tty.cursor.<x|y>`.

local CSI = {
    ['@'] = function(tty, params) end, -- ICH
    A = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.y = math.max(tty.cursor.y - p, 1)
    end, -- CUU
    B = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.y = math.min(tty.cursor.y + p, tty.size.height)
    end, -- CUD
    C = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.x = math.max(tty.cursor.x - p, 1)
    end, -- CUF
    D = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.x = math.min(tty.cursor.x + p, tty.size.width)
    end, -- CUB
    E = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.y = math.min(tty.cursor.y + p, tty.size.height)
        tty.cursor.x = 1
    end, -- CNL
    F = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.y = math.max(tty.cursor.y - p, 1)
        tty.cursor.x = 1
    end, -- CPL
    G = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.x = math.min(p, tty.size.width)
    end, -- CHA
    H = function(tty, params)
        local r, c = params[1] or 1, params[2] or 1
        if r == 0 then r = 1 end
        if c == 0 then c = 1 end
        tty.cursor.x, tty.cursor.y = math.min(c, tty.size.width), math.min(r, tty.size.height)
    end, -- CUP
    I = function(tty, params) end, -- CHT
    J = function(tty, params)
        local n = params[1] or 0
        if n == 0 then
            tty[tty.cursor.y][1] = tty[tty.cursor.y][1]:sub(1, tty.cursor.x - 1) .. (" "):rep(tty.size.width - tty.cursor.x)
            tty[tty.cursor.y][2] = tty[tty.cursor.y][2]:sub(1, tty.cursor.x - 1) .. tty.colors.fg:rep(tty.size.width - tty.cursor.x)
            tty[tty.cursor.y][3] = tty[tty.cursor.y][3]:sub(1, tty.cursor.x - 1) .. tty.colors.bg:rep(tty.size.width - tty.cursor.x)
            tty.dirtyLines[tty.cursor.y] = true
            for y = tty.cursor.y + 1, tty.size.height do
                tty[y][1] = (" "):rep(tty.size.width)
                tty[y][2] = tty.colors.fg:rep(tty.size.width)
                tty[y][3] = tty.colors.bg:rep(tty.size.width)
                tty.dirtyLines[y] = true
            end
        elseif n == 1 then
            tty[tty.cursor.y][1] = (" "):rep(tty.cursor.x) .. tty[tty.cursor.y][1]:sub(tty.cursor.x)
            tty[tty.cursor.y][2] = tty.colors.fg:rep(tty.cursor.x) .. tty[tty.cursor.y][2]:sub(tty.cursor.x)
            tty[tty.cursor.y][3] = tty.colors.bg:rep(tty.cursor.x) .. tty[tty.cursor.y][3]:sub(tty.cursor.x)
            tty.dirtyLines[tty.cursor.y] = true
            for y = tty.cursor.y - 1, 1, -1 do
                tty[y][1] = (" "):rep(tty.size.width)
                tty[y][2] = tty.colors.fg:rep(tty.size.width)
                tty[y][3] = tty.colors.bg:rep(tty.size.width)
                tty.dirtyLines[y] = true
            end
        elseif n == 2 then
            for y = 1, tty.size.height do
                tty[y][1] = (" "):rep(tty.size.width)
                tty[y][2] = tty.colors.fg:rep(tty.size.width)
                tty[y][3] = tty.colors.bg:rep(tty.size.width)
                tty.dirtyLines[y] = true
            end
        -- NOTE: if we ever want scroll support in the console, add n == 3 to clear the scrollback buffer
        --       this will probably never happen, but who knows?
        end
    end, -- ED
    K = function(tty, params)
        local n = params[1] or 0
        if n == 0 then
            tty[tty.cursor.y][1] = tty[tty.cursor.y][1]:sub(1, tty.cursor.x - 1) .. (" "):rep(tty.size.width - tty.cursor.x)
            tty[tty.cursor.y][2] = tty[tty.cursor.y][2]:sub(1, tty.cursor.x - 1) .. tty.colors.fg:rep(tty.size.width - tty.cursor.x)
            tty[tty.cursor.y][3] = tty[tty.cursor.y][3]:sub(1, tty.cursor.x - 1) .. tty.colors.bg:rep(tty.size.width - tty.cursor.x)
            tty.dirtyLines[tty.cursor.y] = true
        elseif n == 1 then
            tty[tty.cursor.y][1] = (" "):rep(tty.cursor.x) .. tty[tty.cursor.y][1]:sub(tty.cursor.x)
            tty[tty.cursor.y][2] = tty.colors.fg:rep(tty.cursor.x) .. tty[tty.cursor.y][2]:sub(tty.cursor.x)
            tty[tty.cursor.y][3] = tty.colors.bg:rep(tty.cursor.x) .. tty[tty.cursor.y][3]:sub(tty.cursor.x)
            tty.dirtyLines[tty.cursor.y] = true
        elseif n == 2 then
            tty[tty.cursor.y][1] = (" "):rep(tty.size.width)
            tty[tty.cursor.y][2] = tty.colors.fg:rep(tty.size.width)
            tty[tty.cursor.y][3] = tty.colors.bg:rep(tty.size.width)
            tty.dirtyLines[tty.cursor.y] = true
        end
    end, -- EL
    L = function(tty, params) end, -- IL
    M = function(tty, params) end, -- DL
    N = function(tty, params) end, -- EF
    O = function(tty, params) end, -- EA
    P = function(tty, params) end, -- DCH
    Q = function(tty, params) end, -- SSE
    R = function(tty, params) end, -- CPR
    S = function(tty, params)
        local n = params[1] or 0
        if n == 0 then n = 1 end
        -- TODO: possibly optimize this?
        for _ = 1, n do
            table.insert(tty, 1, {(' '):rep(tty.size.width), tty.colors.fg:rep(tty.size.width), tty.colors.bg:rep(tty.size.width)})
            tty[tty.size.height + 1] = nil
        end
    end, -- SU
    T = function(tty, params)
        local n = params[1] or 0
        if n == 0 then n = 1 end
        -- TODO: possibly optimize this?
        for _ = 1, n do
            table.remove(tty, 1)
            tty[tty.size.height] = {(' '):rep(tty.size.width), tty.colors.fg:rep(tty.size.width), tty.colors.bg:rep(tty.size.width)}
        end
    end, -- SD
    U = function(tty, params) end, -- NP
    V = function(tty, params) end, -- PP
    W = function(tty, params) end, -- CTC
    X = function(tty, params) end, -- ECH
    Y = function(tty, params) end, -- CVT
    Z = function(tty, params) end, -- CBT
    ['['] = function(tty, params) end, -- SRS
    ['\\'] = function(tty, params) end, -- PTX
    [']'] = function(tty, params) end, -- SDS
    ['^'] = function(tty, params) end, -- SIMD
    ['_'] = function(tty, params) end, -- N/A
    ['`'] = function(tty, params) end, -- HPA
    a = function(tty, params) end, -- HPR
    b = function(tty, params) end, -- REP
    c = function(tty, params) end, -- DA
    d = function(tty, params) end, -- VPA
    e = function(tty, params) end, -- VPR
    f = function(tty, params) end, -- HVP
    g = function(tty, params) end, -- TBC
    h = function(tty, params)
        if params[1] == 25 then tty.cursorBlink = true end
    end, -- SM
    i = function(tty, params) end, -- MC
    j = function(tty, params) end, -- HPB
    k = function(tty, params) end, -- VPB
    l = function(tty, params)
        if params[1] == 25 then tty.cursorBlink = false end
    end, -- RM
    m = function(tty, params)
        local n, m = params[1] or 0, params[2]

        if n == 0 then tty.colors.fg, tty.colors.bg = '0', 'f'
        elseif n == 1 then tty.colors.bold = true
        elseif n == 7 or n == 27 then tty.colors.fg, tty.colors.bg = tty.colors.bg, tty.colors.fg
        elseif n == 22 then tty.colors.bold = false
        elseif n >= 30 and n <= 37 then tty.colors.fg = ("%x"):format(15 - (n - 30) - (tty.colors.bold and 8 or 0))
        elseif n == 39 then tty.colors.fg = '0'
        elseif n >= 40 and n <= 47 then tty.colors.bg = ("%x"):format(15 - (n - 40) - (tty.colors.bold and 8 or 0))
        elseif n == 49 then tty.colors.bg = 'f'
        elseif n >= 90 and n <= 97 then tty.colors.fg = ("%x"):format(15 - (n - 90) - 8)
        elseif n >= 100 and n <= 107 then tty.colors.bg = ("%x"):format(15 - (n - 100) - 8) end
        if m ~= nil then
            if m == 0 then tty.colors.fg, tty.colors.bg = '0', 'f'
            elseif m == 1 then tty.colors.bold = true
            elseif m == 7 or m == 27 then tty.colors.fg, tty.colors.bg = tty.colors.bg, tty.colors.fg
            elseif m == 22 then tty.colors.bold = false
            elseif m >= 30 and m <= 37 then tty.colors.fg = ("%x"):format(15 - (m - 30) - (tty.colors.bold and 8 or 0))
            elseif m == 39 then tty.colors.fg = '0'
            elseif m >= 40 and m <= 47 then tty.colors.bg = ("%x"):format(15 - (m - 40) - (tty.colors.bold and 8 or 0))
            elseif m == 49 then tty.colors.bg = 'f'
            elseif n >= 90 and n <= 97 then tty.colors.fg = ("%x"):format(15 - (n - 90) - 8)
            elseif n >= 100 and n <= 107 then tty.colors.bg = ("%x"):format(15 - (n - 100) - 8) end
        end
    end, -- SGR
    n = function(tty, params)
        -- TODO: send the cursor position to stdin
    end, -- DSR
    o = function(tty, params) end, -- DAQ
}
for i = 0x70, 0x7F do CSI[string.char(i)] = function(tty, params) end end

function terminal.write(tty, text)
    local start, size = 1, 0
    local function commit(x)
        if size == 0 then
            start, size = x, 0
            return
        end
        while tty.cursor.x + size > tty.size.width do
            tty[tty.cursor.y][1] = tty[tty.cursor.y][1]:sub(1, tty.cursor.x - 1) .. text:sub(start, start + tty.size.width - tty.cursor.x - 1)
            tty[tty.cursor.y][2] = tty[tty.cursor.y][2]:sub(1, tty.cursor.x - 1) .. tty.colors.fg:rep(tty.size.width - tty.cursor.x)
            tty[tty.cursor.y][3] = tty[tty.cursor.y][3]:sub(1, tty.cursor.x - 1) .. tty.colors.bg:rep(tty.size.width - tty.cursor.x)
            tty.dirtyLines[tty.cursor.y] = true
            start = start + tty.size.width - tty.cursor.x
            size = size - (tty.size.width - tty.cursor.x)
            tty.cursor.x = 1
            nextline(tty)
        end
        tty[tty.cursor.y][1] = tty[tty.cursor.y][1]:sub(1, tty.cursor.x - 1) .. text:sub(start, start + size - 1) .. tty[tty.cursor.y][1]:sub(tty.cursor.x + size)
        tty[tty.cursor.y][2] = tty[tty.cursor.y][2]:sub(1, tty.cursor.x - 1) .. tty.colors.fg:rep(size) .. tty[tty.cursor.y][2]:sub(tty.cursor.x + size)
        tty[tty.cursor.y][3] = tty[tty.cursor.y][3]:sub(1, tty.cursor.x - 1) .. tty.colors.bg:rep(size) .. tty[tty.cursor.y][3]:sub(tty.cursor.x + size)
        tty.dirtyLines[tty.cursor.y] = true
        tty.cursor.x = tty.cursor.x + size
        start, size = x, 0
    end
    local state = 0
    local params, nextParam
    for x, c, n in text:gmatch "()(.)()" do
        if state == 0 then
            if c == '\a' then
                commit(n)
                -- TODO: make a sound or something
            elseif c == '\b' then
                commit(n)
                if tty.cursor.x == 1 then
                    if tty.cursor.y > 1 then tty.cursor.x, tty.cursor.y = tty.size.width, tty.cursor.y - 1 end
                else tty.cursor.x = tty.cursor.x - 1 end
            elseif c == '\t' then
                commit(n)
                tty.cursor.x = math.floor(tty.cursor.x / 8) * 8 + 8
                if tty.cursor.x > tty.size.width then
                    tty.cursor.x = 1
                    nextline(tty)
                end
            elseif c == '\n' then
                commit(n)
                nextline(tty)
                if tty.flags.nlcr then tty.cursor.x = 1 end
            elseif c == '\f' then
                commit(n)
                nextline(tty)
            elseif c == '\r' then
                commit(n)
                tty.cursor.x = 1
            elseif c == '\27' then
                state = 1
            else
                size = size + 1
            end
        elseif state == 1 then
            -- TODO: Implement whatever of these are applicable
            if false then
            --[[ elseif c == 'B' then -- BPH
            elseif c == 'C' then -- NBH
            elseif c == 'E' then -- NEL
            elseif c == 'F' then -- SSA
            elseif c == 'G' then -- ESA
            elseif c == 'H' then -- HTS
            elseif c == 'I' then -- HTJ
            elseif c == 'J' then -- VTS
            elseif c == 'K' then -- PLD
            elseif c == 'L' then -- PLU
            elseif c == 'M' then -- RI
            elseif c == 'N' then -- SS2
            elseif c == 'O' then -- SS3
            elseif c == 'P' then -- DCS
            elseif c == 'Q' then -- PU1
            elseif c == 'R' then -- PU2
            elseif c == 'S' then -- STS
            elseif c == 'T' then -- CCH
            elseif c == 'U' then -- MW
            elseif c == 'V' then -- SPA
            elseif c == 'W' then -- EPA
            elseif c == 'X' then -- SOS
            elseif c == 'Z' then -- SCI ]]
            elseif c == '[' then -- CSI
                state = 2
                params, nextParam = {}, 0
            --[[ elseif c == '\\' then -- ST ]]
            elseif c == ']' then -- OSC
                if text:byte(n) == 0x50 then
                    state = 4
                    params = {}
                else
                    state = 3
                    params, nextParam = {}, 0
                end
            --[[ elseif c == '^' then -- PM
            elseif c == '_' then -- APC ]]
            else
                commit(n)
                state = 0
            end
        elseif state == 2 then
            if c >= '@' and c <= '\127' then
                commit(n)
                params[#params+1] = nextParam
                CSI[c](tty, params)
                state = 0
            elseif c >= '0' and c <= '?' then
                if c <= '9' then
                    nextParam = nextParam * 10 + tonumber(c)
                elseif c == ';' then
                    params[#params+1], nextParam = nextParam, 0
                end
            else
                commit(n)
                state = 0
            end
        elseif state == 3 then
            -- TODO: properly handle this
            if c == '\\' and text:byte(x - 1) == '\27' then
                commit(n)
                state = 0
            end
        elseif state == 4 then
            if #params == 0 then
                params[1] = tonumber(c, 16) or 0
            elseif #params == 1 and not nextParam then
                nextParam = (tonumber(c, 16) or 0) * 16
            elseif #params == 1 then
                params[2], nextParam = nextParam + (tonumber(c, 16) or 0), nil
            elseif #params == 2 and not nextParam then
                nextParam = (tonumber(c, 16) or 0) * 16
            elseif #params == 2 then
                params[3], nextParam = nextParam + (tonumber(c, 16) or 0), nil
            elseif #params == 3 and not nextParam then
                nextParam = (tonumber(c, 16) or 0) * 16
            elseif #params == 3 then
                commit(n)
                params[4], nextParam = nextParam + (tonumber(c, 16) or 0), nil
                tty.palette[params[1]] = {params[2] / 255, params[3] / 255, params[4] / 255}
                tty.dirtyPalette[params[1]] = true
                state = 0
            end
        end
    end
    commit()
end

function syscalls.write(process, thread, ...)
    if not process.stdout then return end
    local function write(t)
        if process.stdout.isTTY then terminal.write(process.stdout, t)
        else end
    end
    for i, v in ipairs{...} do
        if i > 1 then write("\t") end
        write(tostring(v))
    end
    if process.stdout.isTTY then terminal.redraw(process.stdout) end
end

function syscalls.writeerr(process, thread, ...)
    if not process.stderr then return end
    local function write(t)
        if process.stderr.isTTY then terminal.write(process.stderr, t)
        else end
    end
    for i, v in ipairs{...} do
        if i > 1 then write("\t") end
        write(tostring(v))
    end
    if process.stderr.isTTY then terminal.redraw(process.stderr) end
end

function syscalls.read(process, thread, n)

end

function syscalls.readline(process, thread)

end

function syscalls.termctl(process, thread, flags)

end

function syscalls.openterm(process, thread)

end

function syscalls.opengfx(process, thread)

end

function syscalls.mktty(process, thread, width, height)

end