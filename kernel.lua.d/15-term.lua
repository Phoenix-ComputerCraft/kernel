--- terminal
-- @section terminal

--- Returns a new TTY object.
---@param term table The CraftOS terminal object to render on
---@param width number The width of the TTY
---@param height number The height of the TTY
---@return TTY tty The new TTY object
function terminal.makeTTY(term, width, height)
    ---@class TTY
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
        dirtyPalette = {},
        buffer = "",
        preBuffer = "",
        isLocked = false,
        isGraphics = false,
        textBuffer = {},
        graphicsBuffer = {},
        frontmostProcess = nil,
        processList = {},
        eof = false,
        term = term,
    }
    for y = 1, height do
        retval[y] = {(' '):rep(width), ('0'):rep(width), ('f'):rep(width)}
        retval.dirtyLines[y] = true
    end
    for i = 0, 15 do
        retval.palette[i] = {_G.term.nativePaletteColor(2^i)}
        retval.dirtyPalette[i] = true
    end
    return retval
end

do
    local term_width, term_height = term.getSize()
    --- Stores all virtual TTYs for the main screen.
    TTY = {
        terminal.makeTTY(term, term_width, term_height),
        terminal.makeTTY(term, term_width, term_height),
        terminal.makeTTY(term, term_width, term_height),
        terminal.makeTTY(term, term_width, term_height),
        terminal.makeTTY(term, term_width, term_height),
        terminal.makeTTY(term, term_width, term_height),
        terminal.makeTTY(term, term_width, term_height),
        terminal.makeTTY(term, term_width, term_height)
    }
end
--- Stores the TTY that is currently shown on screen.
currentTTY = TTY[1]
--- Stores all TTYs that have been created in user mode.
terminal.userTTYs = {}

do
    local n = args.console:match "^tty(%d+)$"
    if n then KERNEL.stdout, KERNEL.stderr, KERNEL.stdin = TTY[tonumber(n)], TTY[tonumber(n)], TTY[tonumber(n)] end
end

--- Stores what modifier keys are currently being held.
keysHeld = {ctrl = false, alt = false, shift = false}

eventHooks.term_resize = eventHooks.term_resize or {}
eventHooks.char = eventHooks.char or {}
eventHooks.paste = eventHooks.paste or {}
eventHooks.key = eventHooks.key or {}
eventHooks.key_up = eventHooks.key_up or {}
eventHooks.term_resize[#eventHooks.term_resize+1] = function()
    local w, h = term.getSize()
    for i = 1, 8 do terminal.resize(TTY[i], w, h) end
end
eventHooks.char[#eventHooks.char+1] = function(ev)
    if not currentTTY.isLocked then
        if currentTTY.flags.cbreak then currentTTY.buffer = currentTTY.buffer .. ev[2]
        else currentTTY.preBuffer = currentTTY.preBuffer .. ev[2] end
        if currentTTY.flags.echo then terminal.write(currentTTY, ev[2]) terminal.redraw(currentTTY) end
    end
end
eventHooks.paste[#eventHooks.paste+1] = function(ev)
    if not currentTTY.isLocked then
        if currentTTY.flags.cbreak then currentTTY.buffer = currentTTY.buffer .. ev[2]
        else currentTTY.preBuffer = currentTTY.preBuffer .. ev[2] end
        if currentTTY.flags.echo then terminal.write(currentTTY, ev[2]) terminal.redraw(currentTTY) end
    end
end
eventHooks.key[#eventHooks.key+1] = function(ev)
    if not currentTTY.isLocked then
        if ev[2] == keys.enter then
            if currentTTY.flags.cbreak then
                currentTTY.buffer = currentTTY.buffer .. "\n"
            else
                currentTTY.buffer = currentTTY.buffer .. currentTTY.preBuffer .. "\n"
                currentTTY.preBuffer = ""
            end
            if currentTTY.flags.echo then terminal.write(currentTTY, "\n") terminal.redraw(currentTTY) end
        elseif ev[2] == keys.backspace then
            if currentTTY.flags.cbreak then
                -- TODO: uh, what is this supposed to be?
            elseif #currentTTY.preBuffer > 0 then
                currentTTY.preBuffer = currentTTY.preBuffer:sub(1, -2)
                if currentTTY.flags.echo then terminal.write(currentTTY, "\b \b") terminal.redraw(currentTTY) end
            end
        end
    end
    if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then keysHeld.ctrl = true
    elseif ev[2] == keys.leftAlt or ev[2] == keys.rightAlt then keysHeld.alt = true
    elseif ev[2] == keys.leftShift or ev[2] == keys.rightShift then keysHeld.shift = true end
    if not currentTTY.flags.raw and currentTTY.frontmostProcess and keysHeld.ctrl and not keysHeld.alt and not keysHeld.shift then
        if ev[2] == keys.c then killProcess(currentTTY.frontmostProcess.id, 2) terminal.write(currentTTY, "^C")
        elseif ev[2] == keys.backslash then killProcess(currentTTY.frontmostProcess.id, 3) terminal.write(currentTTY, "^\\")
        elseif ev[2] == keys.z then killProcess(currentTTY.frontmostProcess.id, 19) terminal.write(currentTTY, "^Z")
        elseif ev[2] == keys.d then currentTTY.eof = true terminal.write(currentTTY, "^D")
        elseif ev[2] == keys.l and currentTTY.cursor.y > 1 then
            local y = currentTTY.cursor.y - 1 -- minifier error
            terminal.write(currentTTY, "\x1b[" .. y .. "T\x1b[1;" .. currentTTY.cursor.x .. "H")
        -- TODO: fill in other cool keys
        end
    end
    if keysHeld.ctrl and not keysHeld.alt and keysHeld.shift then
        local changed = true
        if ev[2] == keys.f1 then currentTTY = TTY[1]
        elseif ev[2] == keys.f2 then currentTTY = TTY[2]
        elseif ev[2] == keys.f3 then currentTTY = TTY[3]
        elseif ev[2] == keys.f4 then currentTTY = TTY[4]
        elseif ev[2] == keys.f5 then currentTTY = TTY[5]
        elseif ev[2] == keys.f6 then currentTTY = TTY[6]
        elseif ev[2] == keys.f7 then currentTTY = TTY[7]
        elseif ev[2] == keys.f8 then currentTTY = TTY[8]
        elseif ev[2] == keys.left then for i = 1, 8 do if currentTTY == TTY[i] then currentTTY = TTY[(i+7)%8] break end end
        elseif ev[2] == keys.right then for i = 1, 8 do if currentTTY == TTY[i] then currentTTY = TTY[(i+1)%8] break end end
        else changed = false end
        if changed then terminal.redraw(currentTTY, true) end
    end
end
eventHooks.key_up[#eventHooks.key_up+1] = function(ev)
    if ev[2] == keys.leftCtrl or ev[2] == keys.rightCtrl then keysHeld.ctrl = false
    elseif ev[2] == keys.leftAlt or ev[2] == keys.rightAlt then keysHeld.alt = false
    elseif ev[2] == keys.leftShift or ev[2] == keys.rightShift then keysHeld.shift = false end
end

--- Redraws the specified TTY if on-screen.
-- @tparam TTY tty The TTY to redraw
-- @tparam boolean full Whether to draw the full screen, or just the changed regions
function terminal.redraw(tty, full)
    if tty.process then tty.process.eventQueue[#tty.process.eventQueue+1] = {"tty_redraw", {id = tty.id}} return
    elseif currentTTY ~= tty and not tty.isMonitor then return end
    local term = tty.term
    local buffer = tty
    if tty.isLocked then
        if tty.isGraphics then
            term.setGraphicsMode(2)
            if term.setFrozen then term.setFrozen(true) end
            if full then
                term.clear()
                term.drawPixels(0, 0, tty.graphicsBuffer)
                for i = 0, 255 do term.setPaletteColor(i, tty.graphicsBuffer.palette[i][1], tty.graphicsBuffer.palette[i][2], tty.graphicsBuffer.palette[i][3]) end
            else
                if tty.graphicsBuffer.frozen then
                    if term.setFrozen then term.setFrozen(false) end
                    return
                end
                for _, v in ipairs(tty.graphicsBuffer.dirtyRects) do
                    if v.color then term.setPixel(v.x, v.y, v.color, v.width, v.height)
                    else term.drawPixels(v.x, v.y, v) end
                end
                for i in pairs(tty.graphicsBuffer.dirtyPalette) do term.setPaletteColor(i, tty.graphicsBuffer.palette[i][1], tty.graphicsBuffer.palette[i][2],tty.graphicsBuffer.palette[i][3]) end
            end
            if term.setFrozen then term.setFrozen(false) end
            buffer.dirtyRects, buffer.dirtyPalette = {}, {}
            return
        end
        if term.setGraphicsMode then term.setGraphicsMode(false) end
        buffer = tty.textBuffer
    elseif tty.isGraphics then
        term.setGraphicsMode(false)
        tty.isGraphics = false
    end
    term.setCursorBlink(false)
    if full then
        term.clear()
        for y = 1, tty.size.height do
            term.setCursorPos(1, y)
            term.blit(buffer[y][1], buffer[y][2], buffer[y][3])
        end
        for i = 0, 15 do term.setPaletteColor(2^i, buffer.palette[i][1], buffer.palette[i][2], buffer.palette[i][3]) end
    else
        for y in pairs(buffer.dirtyLines) do
            if not buffer[y] then error(debug.traceback(y)) end
            term.setCursorPos(1, y)
            if #buffer[y][1] ~= #buffer[y][2] or #buffer[y][2] ~= #buffer[y][3] then
                syslog.log({level = "critical"}, "Bug in text writer! Inequal lengths: " .. #buffer[y][1] .. ", " .. #buffer[y][2] .. ", " .. #buffer[y][3])
                error("Invalid lengths")
            end
            term.blit(buffer[y][1], buffer[y][2], buffer[y][3])
        end
        for i in pairs(buffer.dirtyPalette) do term.setPaletteColor(2^i, buffer.palette[i][1], buffer.palette[i][2], buffer.palette[i][3]) end
    end
    term.setCursorPos(buffer.cursor.x, buffer.cursor.y)
    term.setCursorBlink(buffer.cursorBlink)
    term.setTextColor(2^tonumber(buffer.colors.fg, 16))
    buffer.dirtyLines, buffer.dirtyPalette = {}, {}
end

--- Resizes the TTY.
-- @tparam TTY tty The TTY to resize
-- @tparam number width The new width
-- @tparam number height The new height
function terminal.resize(tty, width, height)
    if width > tty.size.width then
        for y = 1, tty.size.height do
            tty[y][1] = tty[y][1] .. (' '):rep(width - tty.size.width)
            tty[y][2] = tty[y][2] .. tty.colors.fg:rep(width - tty.size.width)
            tty[y][3] = tty[y][3] .. tty.colors.bg:rep(width - tty.size.width)
            tty.dirtyLines[y] = true
        end
        if tty.isLocked then
            if tty.isGraphics then
                for y = 1, tty.size.height * 9 do
                    tty.graphicsBuffer[y] = tty.graphicsBuffer[y] .. ('\15'):rep((width - tty.size.width) * 6)
                end
                tty.graphicsBuffer.dirtyRects[#tty.graphicsBuffer.dirtyRects+1] = {
                    x = tty.size.width * 6 + 1, y = 1,
                    width = (width - tty.size.width) * 6, height = tty.size.height * 9
                }
            else
                for y = 1, tty.size.height do
                    tty.textBuffer[y][1] = tty.textBuffer[y][1] .. (' '):rep(width - tty.size.width)
                    tty.textBuffer[y][2] = tty.textBuffer[y][2] .. tty.textBuffer.colors.fg:rep(width - tty.size.width)
                    tty.textBuffer[y][3] = tty.textBuffer[y][3] .. tty.textBuffer.colors.bg:rep(width - tty.size.width)
                    tty.textBuffer.dirtyLines[y] = true
                end
            end
        end
    elseif width < tty.size.width then
        for y = 1, tty.size.height do
            tty[y][1] = tty[y][1]:sub(1, width)
            tty[y][2] = tty[y][2]:sub(1, width)
            tty[y][3] = tty[y][3]:sub(1, width)
            tty.dirtyLines[y] = true
        end
        if tty.isLocked then
            if tty.isGraphics then
                for y = 1, tty.size.height * 9 do
                    tty.graphicsBuffer[y] = tty.graphicsBuffer[y]:sub(1, width * 6)
                end
            else
                for y = 1, tty.size.height do
                    tty.textBuffer[y][1] = tty.textBuffer[y][1]:sub(1, width)
                    tty.textBuffer[y][2] = tty.textBuffer[y][2]:sub(1, width)
                    tty.textBuffer[y][3] = tty.textBuffer[y][3]:sub(1, width)
                end
            end
        end
    end
    tty.size.width = width

    if height > tty.size.height then
        for y = tty.size.height + 1, height do
            tty[y] = {(' '):rep(width), tty.colors.fg:rep(width), tty.colors.bg:rep(width)}
            tty.dirtyLines[y] = true
        end
        if tty.isLocked then
            if tty.isGraphics then
                for y = tty.size.height * 9 + 1, height * 9 do
                    tty.graphicsBuffer[y] = ('\15'):rep(width * 6)
                end
                tty.graphicsBuffer.dirtyRects[#tty.graphicsBuffer.dirtyRects+1] = {
                    x = 1, y = tty.size.height * 9 + 1,
                    width = tty.size.width * 6, height = (height - tty.size.height) * 9
                }
            else
                for y = tty.size.height + 1, height do
                    tty.textBuffer[y] = {(' '):rep(width), tty.textBuffer.colors.fg:rep(width), tty.textBuffer.colors.bg:rep(width)}
                    tty.textBuffer.dirtyLines[y] = true
                end
            end
        end
    elseif height < tty.size.height then
        for y = height + 1, tty.size.height do
            tty[y] = nil
            tty.dirtyLines[y] = nil
        end
        if tty.isLocked then
            if tty.isGraphics then
                for y = height * 9 + 1, tty.size.height * 9 do
                    tty.graphicsBuffer[y] = nil
                end
            else
                for y = height + 1, tty.size.height do
                    tty.textBuffer[y] = nil
                    tty.textBuffer.dirtyLines[y] = nil
                end
            end
        end
    end
    tty.size.height = height
end

local function nextline(tty)
    local cursor = tty.cursor
    local y = cursor.y + 1
    cursor.y = y
    local size = tty.size
    local height = size.height
    if y > height then
        --table.remove(tty, 1)
        local dirtyLines = tty.dirtyLines
        for i = 1, height - 1 do
            tty[i] = tty[i+1]
            dirtyLines[i] = true
        end
        local width = size.width
        local colors = tty.colors
        tty[height] = {(' '):rep(width), colors.fg:rep(width), colors.bg:rep(width)}
        dirtyLines[height] = true
        cursor.y = height
    end
end

-- TODO: We could probably optimize a lot of the table indexes here to speed things up.
--       This will become important as things start needing to write quickly.
--       The biggest improvement will likely come from caching `tty.cursor.<x|y>`.

local CSI = {
    ['@'] = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        local xp, yp = p % tty.size.width, math.floor(p / tty.size.width)
        local n = {
            tty[tty.cursor.y][1]:sub(tty.size.width - xp + 1),
            tty[tty.cursor.y][2]:sub(tty.size.width - xp + 1),
            tty[tty.cursor.y][3]:sub(tty.size.width - xp + 1)
        }
        tty[tty.cursor.y][1] = tty[tty.cursor.y][1]:sub(1, tty.cursor.x - 1) .. (" "):rep(p) .. tty[tty.cursor.y+yp][1]:sub(tty.cursor.x, tty.size.width - xp)
        tty[tty.cursor.y][2] = tty[tty.cursor.y][2]:sub(1, tty.cursor.x - 1) .. tty.colors.fg:rep(p) .. tty[tty.cursor.y+yp][2]:sub(tty.cursor.x, tty.size.width - xp)
        tty[tty.cursor.y][3] = tty[tty.cursor.y][3]:sub(1, tty.cursor.x - 1) .. tty.colors.bg:rep(p) .. tty[tty.cursor.y+yp][3]:sub(tty.cursor.x, tty.size.width - xp)
        tty.dirtyLines[tty.cursor.y] = true
        for y = tty.cursor.y + yp + 1, tty.size.height do
            local nn = {
                tty[y-yp][1]:sub(tty.size.width - p + 1),
                tty[y-yp][2]:sub(tty.size.width - p + 1),
                tty[y-yp][3]:sub(tty.size.width - p + 1)
            }
            tty[y][1] = n[1] .. tty[y-yp][1]:sub(1, tty.size.width - xp)
            tty[y][2] = n[2] .. tty[y-yp][2]:sub(1, tty.size.width - xp)
            tty[y][3] = n[3] .. tty[y-yp][3]:sub(1, tty.size.width - xp)
            tty.dirtyLines[y] = true
            n = nn
        end
        for y = tty.cursor.y + 1, tty.cursor.y + yp do
            tty[y][1] = (" "):rep(tty.size.width)
            tty[y][2] = tty.colors.fg:rep(tty.size.width)
            tty[y][3] = tty.colors.bg:rep(tty.size.width)
            tty.dirtyLines[y] = true
        end
    end, -- ICH
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
        tty.cursor.y = tty.cursor.y + math.floor((tty.cursor.x - 1 + p) / tty.size.width)
        tty.cursor.x = (tty.cursor.x - 1 + p) % tty.size.width + 1
    end, -- CUF
    D = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        tty.cursor.y = tty.cursor.y + math.floor((tty.cursor.x - 1 - p) / tty.size.width)
        tty.cursor.x = (tty.cursor.x - 1 - p) % tty.size.width + 1
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
    P = function(tty, params)
        local p = params[1] or 1
        if p == 0 then p = 1 end
        local xp, yp = p % tty.size.width, math.floor(p / tty.size.width)
        local n = {
            (" "):rep(xp),
            tty.colors.fg:rep(xp),
            tty.colors.bg:rep(xp)
        }
        for y = tty.size.height - yp, tty.cursor.y + 1, -1 do
            local nn = {
                tty[y+yp][1]:sub(1, xp),
                tty[y+yp][2]:sub(1, xp),
                tty[y+yp][3]:sub(1, xp)
            }
            tty[y][1] = tty[y+yp][1]:sub(xp + 1) .. n[1]
            tty[y][2] = tty[y+yp][2]:sub(xp + 1) .. n[2]
            tty[y][3] = tty[y+yp][3]:sub(xp + 1) .. n[3]
            tty.dirtyLines[y] = true
            n = nn
        end
        for y = tty.size.height - yp + 1, tty.size.height do
            tty[y][1] = (" "):rep(tty.size.width)
            tty[y][2] = tty.colors.fg:rep(tty.size.width)
            tty[y][3] = tty.colors.bg:rep(tty.size.width)
            tty.dirtyLines[y] = true
        end
        tty[tty.cursor.y][1] = tty[tty.cursor.y][1]:sub(1, tty.cursor.x - 1) .. tty[tty.cursor.y+yp][1]:sub(tty.cursor.x + xp, tty.size.width) .. n[1]
        tty[tty.cursor.y][2] = tty[tty.cursor.y][2]:sub(1, tty.cursor.x - 1) .. tty[tty.cursor.y+yp][2]:sub(tty.cursor.x + xp, tty.size.width) .. n[2]
        tty[tty.cursor.y][3] = tty[tty.cursor.y][3]:sub(1, tty.cursor.x - 1) .. tty[tty.cursor.y+yp][3]:sub(tty.cursor.x + xp, tty.size.width) .. n[3]
        tty.dirtyLines[tty.cursor.y] = true
    end, -- DCH
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
        for y = 1, tty.size.height do tty.dirtyLines[y] = true end
    end, -- SU
    T = function(tty, params)
        local n = params[1] or 0
        if n == 0 then n = 1 end
        -- TODO: possibly optimize this?
        for _ = 1, n do
            table.remove(tty, 1)
            tty[tty.size.height] = {(' '):rep(tty.size.width), tty.colors.fg:rep(tty.size.width), tty.colors.bg:rep(tty.size.width)}
        end
        for y = 1, tty.size.height do tty.dirtyLines[y] = true end
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

        if n == 0 then tty.colors.fg, tty.colors.bg, tty.colors.bold = '0', 'f', false
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
            elseif m >= 90 and m <= 97 then tty.colors.fg = ("%x"):format(15 - (m - 90) - 8)
            elseif m >= 100 and m <= 107 then tty.colors.bg = ("%x"):format(15 - (m - 100) - 8) end
        end
    end, -- SGR
    n = function(tty, params)
        -- TODO: send the cursor position to stdin
    end, -- DSR
    o = function(tty, params) end, -- DAQ
}
for i = 0x70, 0x7F do CSI[string.char(i)] = function(tty, params) end end

--- Writes some text to a TTY's text buffer, allowing ANSI escapes.
-- @tparam TTY tty The TTY to write to
-- @tparam string text The text to write
function terminal.write(tty, text)
    local start, size = 1, 0
    local function commit(x)
        if size == 0 then
            start, size = x, 0
            return
        end
        while tty.cursor.x + size > tty.size.width do
            tty[tty.cursor.y][1] = tty[tty.cursor.y][1]:sub(1, tty.cursor.x - 1) .. text:sub(start, start + tty.size.width - tty.cursor.x)
            tty[tty.cursor.y][2] = tty[tty.cursor.y][2]:sub(1, tty.cursor.x - 1) .. tty.colors.fg:rep(tty.size.width - tty.cursor.x + 1)
            tty[tty.cursor.y][3] = tty[tty.cursor.y][3]:sub(1, tty.cursor.x - 1) .. tty.colors.bg:rep(tty.size.width - tty.cursor.x + 1)
            tty.dirtyLines[tty.cursor.y] = true
            start = start + tty.size.width - tty.cursor.x + 1
            size = size - (tty.size.width - tty.cursor.x + 1)
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
                tty.cursor.x = math.floor((tty.cursor.x - 1) / 8) * 8 + 9
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
    --[[if process.stdout.isTTY and process ~= process.stdout.frontmostProcess then
        syscalls.kill(KERNEL, nil, process.id, 22)
        if process.paused then return kSyscallYield, "write" end
    end]]
    local function write(t)
        if process.stdout.isTTY then terminal.write(process.stdout, t)
        else process.stdout.write(t) end
    end
    local args = table.pack(...)
    for i = 1, args.n do
        if i > 1 then write("\t") end
        write(tostring(args[i]))
    end
    if process.stdout.isTTY then terminal.redraw(process.stdout) end
end

function syscalls.writeerr(process, thread, ...)
    if not process.stderr then return end
    --[[if process.stderr.isTTY and process ~= process.stderr.frontmostProcess then
        syscalls.kill(KERNEL, nil, process.id, 22)
        if process.paused then return kSyscallYield, "writeerr" end
    end]]
    local function write(t)
        if process.stderr.isTTY then terminal.write(process.stderr, t)
        else process.stderr.write(t) end
    end
    local args = table.pack(...)
    for i = 1, args.n do
        if i > 1 then write("\t") end
        write(tostring(args[i]))
    end
    if process.stderr.isTTY then terminal.redraw(process.stderr) end
end

function syscalls.read(process, thread, n)
    expect(1, n, "number")
    if process.stdin then
        --[[if process.stdin.isTTY and process ~= process.stdin.frontmostProcess then
            syscalls.kill(KERNEL, nil, process.id, 21)
            if process.paused then return kSyscallYield, "readline" end
        end]]
        if process.stdin.eof then
            process.stdin.eof = false
            return nil
        end
        while #process.stdin.buffer < n do
            if process.stdin.eof then
                process.stdin.eof = false
                return nil
            end
            if process.stdin.isTTY and not process.stdin.flags.delay then return nil end
            if process.stdin.read then
                local s = process.stdin.read(n - #process.stdin.buffer)
                if not s then return nil end
                process.stdin.buffer = process.stdin.buffer .. s
            else return kSyscallYield, "read", n end
        end
        local s = process.stdin.buffer:sub(1, n - 1)
        process.stdin.buffer = process.stdin.buffer:sub(n)
        return s
    else return nil end
end

function syscalls.readline(process, thread)
    if process.stdin then
        --[[if process.stdin.isTTY and process ~= process.stdin.frontmostProcess then
            syscalls.kill(KERNEL, nil, process.id, 21)
            if process.paused then return kSyscallYield, "readline" end
        end]]
        if process.stdin.eof then
            process.stdin.eof = false
            return nil
        end
        while not process.stdin.buffer:find("\n") do
            if process.stdin.eof then
                process.stdin.eof = false
                return nil
            end
            if process.stdin.isTTY and not process.stdin.flags.delay then return nil end
            if process.stdin.read then
                local s = process.stdin.read()
                if not s then return nil end
                process.stdin.buffer = process.stdin.buffer .. s
            else return kSyscallYield, "readline" end
        end
        local n = process.stdin.buffer:find("\n")
        local s = process.stdin.buffer:sub(1, n - 1)
        process.stdin.buffer = process.stdin.buffer:sub(n + 1)
        return s
    else return nil end
end

function syscalls.termctl(process, thread, flags)
    expect(1, flags, "table", "nil")
    if not process.stdout or not process.stdout.isTTY then return nil end
    --[[if process ~= process.stdout.frontmostProcess then
        syscalls.kill(KERNEL, nil, process.id, 22)
        if process.paused then return kSyscallYield, "termctl", flags end
    end]]
    if flags then
        expect.field(flags, "cbreak", "boolean", "nil")
        expect.field(flags, "delay", "boolean", "nil")
        expect.field(flags, "echo", "boolean", "nil")
        expect.field(flags, "keypad", "boolean", "nil")
        expect.field(flags, "nlcr", "boolean", "nil")
        expect.field(flags, "raw", "boolean", "nil")
        for k, v in pairs(flags) do if process.stdout.flags[k] ~= nil then process.stdout.flags[k] = v end end
    end
    local t = deepcopy(process.stdout.flags)
    t.hasgfx = term.getGraphicsMode ~= nil
    return t
end

function terminal.openterm(tty, process)
    if tty.isLocked then
        if not tty.isGraphics and tty.frontmostProcess == process then return tty.screenHandle end
        return nil, "Terminal already in use"
    end
    local size = tty.size
    local buffer = {
        cursor = {x = 1, y = 1},
        cursorBlink = false,
        colors = {fg = '0', bg = 'f'},
        palette = {},
        dirtyLines = {},
        dirtyPalette = {},
    }
    tty.textBuffer = buffer
    tty.isLocked = true
    tty.isGraphics = false
    for y = 1, size.height do
        buffer[y] = {(' '):rep(size.width), ('0'):rep(size.width), ('f'):rep(size.width)}
        buffer.dirtyLines[y] = true
    end
    for i = 0, 15 do
        buffer.palette[i] = {term.nativePaletteColor(2^i)}
        buffer.dirtyPalette[i] = true
    end

    tty.processList[#tty.processList+1] = tty.frontmostProcess
    tty.frontmostProcess = process

    local win = setmetatable({}, {__name = "Terminal"})
    local redraw = terminal.redraw
    local expect = expect
    tty.screenHandle = win

    function win.close()
        if not win then error("terminal is already closed", 2) end
        win = nil
        tty.isLocked = false
        tty.frontmostProcess = table.remove(tty.processList)
        tty.screenHandle = nil
        redraw(tty, true)
    end

    function win.write(text)
        if not win then error("terminal is already closed", 2) end
        text = tostring(text)
        expect(1, text, "string")
        if buffer.cursor.y < 1 or buffer.cursor.y > size.height then return
        elseif buffer.cursor.x > size.width or buffer.cursor.x + #text < 1 then
            buffer.cursor.x = buffer.cursor.x + #text
            return
        elseif buffer.cursor.x < 1 then
            text = text:sub(-buffer.cursor.x + 2)
            buffer.cursor.x = 1
        end
        local ntext = #text
        if buffer.cursor.x + #text > size.width then text = text:sub(1, size.width - buffer.cursor.x + 1) end
        buffer[buffer.cursor.y][1] = buffer[buffer.cursor.y][1]:sub(1, buffer.cursor.x - 1) .. text .. buffer[buffer.cursor.y][1]:sub(buffer.cursor.x + #text)
        buffer[buffer.cursor.y][2] = buffer[buffer.cursor.y][2]:sub(1, buffer.cursor.x - 1) .. buffer.colors.fg:rep(#text) .. buffer[buffer.cursor.y][2]:sub(buffer.cursor.x + #text)
        buffer[buffer.cursor.y][3] = buffer[buffer.cursor.y][3]:sub(1, buffer.cursor.x - 1) .. buffer.colors.bg:rep(#text) .. buffer[buffer.cursor.y][3]:sub(buffer.cursor.x + #text)
        buffer.cursor.x = buffer.cursor.x + ntext
        buffer.dirtyLines[buffer.cursor.y] = true
        --redraw(tty)
    end

    function win.blit(text, fg, bg)
        if not win then error("terminal is already closed", 2) end
        text = tostring(text)
        expect(1, text, "string")
        expect(2, fg, "string")
        expect(3, bg, "string")
        if #text ~= #fg or #fg ~= #bg then error("Arguments must be the same length", 2) end
        if buffer.cursor.y < 1 or buffer.cursor.y > size.height then return
        elseif buffer.cursor.x > size.width or buffer.cursor.x < 1 - #text then
            buffer.cursor.x = buffer.cursor.x + #text
            redraw(tty)
            return
        elseif buffer.cursor.x < 1 then
            text, fg, bg = text:sub(-buffer.cursor.x + 2), fg:sub(-buffer.cursor.x + 2), bg:sub(-buffer.cursor.x + 2)
            buffer.cursor.x = 1
        end
        local ntext = #text
        if buffer.cursor.x + #text > size.width then text, fg, bg = text:sub(1, size.width - buffer.cursor.x + 1), fg:sub(1, size.width - buffer.cursor.x + 1), bg:sub(1, size.width - buffer.cursor.x + 1) end
        buffer[buffer.cursor.y][1] = buffer[buffer.cursor.y][1]:sub(1, buffer.cursor.x - 1) .. text .. buffer[buffer.cursor.y][1]:sub(buffer.cursor.x + #text)
        buffer[buffer.cursor.y][2] = buffer[buffer.cursor.y][2]:sub(1, buffer.cursor.x - 1) .. fg .. buffer[buffer.cursor.y][2]:sub(buffer.cursor.x + #fg)
        buffer[buffer.cursor.y][3] = buffer[buffer.cursor.y][3]:sub(1, buffer.cursor.x - 1) .. bg .. buffer[buffer.cursor.y][3]:sub(buffer.cursor.x + #bg)
        buffer.cursor.x = buffer.cursor.x + ntext
        buffer.dirtyLines[buffer.cursor.y] = true
        --redraw(tty)
    end

    function win.clear()
        if not win then error("terminal is already closed", 2) end
        for y = 1, size.height do
            buffer[y] = {(' '):rep(size.width), buffer.colors.fg:rep(size.width), buffer.colors.bg:rep(size.width)}
            buffer.dirtyLines[y] = true
        end
        --redraw(tty)
    end

    function win.clearLine()
        if not win then error("terminal is already closed", 2) end
        if buffer.cursor.y >= 1 and buffer.cursor.y <= size.height then
            buffer[buffer.cursor.y] = {(' '):rep(size.width), buffer.colors.fg:rep(size.width), buffer.colors.bg:rep(size.width)}
            buffer.dirtyLines[buffer.cursor.y] = true
            --redraw(tty)
        end
    end

    function win.getCursorPos()
        if not win then error("terminal is already closed", 2) end
        return buffer.cursor.x, buffer.cursor.y
    end

    function win.setCursorPos(cx, cy)
        if not win then error("terminal is already closed", 2) end
        expect(1, cx, "number")
        expect(2, cy, "number")
        if cx == buffer.cursor.x and cy == buffer.cursor.y then return end
        buffer.cursor.x, buffer.cursor.y = math.floor(cx), math.floor(cy)
        --redraw(tty)
    end

    function win.getCursorBlink()
        if not win then error("terminal is already closed", 2) end
        return buffer.cursorBlink
    end

    function win.setCursorBlink(b)
        if not win then error("terminal is already closed", 2) end
        expect(1, b, "boolean")
        buffer.cursorBlink = b
        --redraw(tty)
    end

    function win.isColor()
        if not win then error("terminal is already closed", 2) end
        return true
    end

    function win.getSize()
        if not win then error("terminal is already closed", 2) end
        return size.width, size.height
    end

    function win.scroll(lines)
        if not win then error("terminal is already closed", 2) end
        expect(1, lines, "number")
        if math.abs(lines) >= size.width then
            for y = 1, size.height do buffer[y] = {(' '):rep(size.width), buffer.colors.fg:rep(size.width), buffer.colors.bg:rep(size.width)} end
        elseif lines > 0 then
            for i = lines + 1, size.height do buffer[i - lines] = buffer[i] end
            for i = size.height - lines + 1, size.height do buffer[i] = {(' '):rep(size.width), buffer.colors.fg:rep(size.width), buffer.colors.bg:rep(size.width)} end
        elseif lines < 0 then
            for i = 1, size.height + lines do buffer[i - lines] = buffer[i] end
            for i = 1, -lines do buffer[i] = {(' '):rep(size.width), buffer.colors.fg:rep(size.width), buffer.colors.bg:rep(size.width)} end
        else return end
        for i = 1, size.height do buffer.dirtyLines[i] = true end
        --redraw(tty)
    end

    function win.getTextColor()
        if not win then error("terminal is already closed", 2) end
        return tonumber(buffer.colors.fg, 16)
    end

    function win.setTextColor(color)
        if not win then error("terminal is already closed", 2) end
        expect(1, color, "number")
        expect.range(color, 0, 15)
        buffer.colors.fg = ("%x"):format(color)
    end

    function win.getBackgroundColor()
        if not win then error("terminal is already closed", 2) end
        return tonumber(buffer.colors.bg, 16)
    end

    function win.setBackgroundColor(color)
        if not win then error("terminal is already closed", 2) end
        expect(1, color, "number")
        expect.range(color, 0, 15)
        buffer.colors.bg = ("%x"):format(color)
    end

    function win.getPaletteColor(color)
        if not win then error("terminal is already closed", 2) end
        expect(1, color, "number")
        expect.range(color, 0, 15)
        return table.unpack(buffer.palette[math.floor(color)])
    end

    function win.setPaletteColor(color, r, g, b)
        if not win then error("terminal is already closed", 2) end
        expect(1, color, "number")
        expect(2, r, "number")
        if g == nil and b == nil then r, g, b = bit32.band(bit32.rshift(r, 16), 0xFF) / 255, bit32.band(bit32.rshift(r, 8), 0xFF) / 255, bit32.band(r, 0xFF) / 255 end
        expect(3, g, "number")
        expect(4, b, "number")
        expect.range(color, 0, 15)
        if r < 0 or r > 1 then error("bad argument #2 (value out of range)", 2) end
        if g < 0 or g > 1 then error("bad argument #3 (value out of range)", 2) end
        if b < 0 or b > 1 then error("bad argument #4 (value out of range)", 2) end
        buffer.palette[math.floor(color)] = {r, g, b}
        buffer.dirtyPalette[math.floor(color)] = true
        --redraw(tty)
    end

    function win.getLine(y)
        if not win then error("terminal is already closed", 2) end
        expect(1, y, "number")
        local l = buffer[y]
        if l then return table.unpack(l, 1, 3) end
    end

    local nativePaletteColor = term.nativePaletteColor
    function win.nativePaletteColor(color)
        expect(1, color, "number")
        expect.range(color, 0, 15)
        return nativePaletteColor(2^color)
    end

    for _, v in pairs(win) do setfenv(v, process.env) debug.protect(v) end
    win.isColour = win.isColor
    win.getTextColour = win.getTextColor
    win.setTextColour = win.setTextColor
    win.getBackgroundColour = win.getBackgroundColor
    win.setBackgroundColour = win.setBackgroundColor
    win.getPaletteColour = win.getPaletteColor
    win.setPaletteColour = win.setPaletteColor
    win.nativePaletteColour = win.nativePaletteColor
    process.dependents[#process.dependents+1] = {gc = function() if win then return win.close() end end}
    redraw(tty, true)
    return win
end

function syscalls.openterm(process, thread)
    if not process.stdout or not process.stdout.isTTY then return nil, "No valid TTY attached" end
    if process ~= process.stdout.frontmostProcess then
        syscalls.kill(KERNEL, nil, process.id, 22)
        if process.paused then return kSyscallYield, "openterm" end
    end
    return terminal.openterm(process.stdout, process)
end

-- TODO: make final decision on whether graphics terminals are 0-based or 1-based

function terminal.opengfx(tty, process)
    if not term.drawPixels then return nil, "Graphics mode not supported" end
    if tty.isLocked then
        if tty.isGraphics and tty.frontmostProcess == process then return tty.screenHandle end
        return nil, "Terminal already in use"
    end
    local size = tty.size
    local buffer = {
        palette = {},
        dirtyRects = {},
        dirtyPalette = {},
        frozen = false,
    }
    tty.graphicsBuffer = buffer
    tty.isLocked = true
    tty.isGraphics = true
    for y = 1, size.height * 9 do buffer[y] = ('\15'):rep(size.width * 6) end
    for i = 0, 15 do
        buffer.palette[i] = {term.nativePaletteColor(2^i)}
        buffer.dirtyPalette[i] = true
    end
    for i = 16, 255 do
        buffer.palette[i] = {0, 0, 0}
        buffer.dirtyPalette[i] = true
    end

    tty.processList[#tty.processList+1] = tty.frontmostProcess
    tty.frontmostProcess = process

    local win = setmetatable({}, {__name = "GFXTerminal"})
    local redraw = terminal.redraw
    local expect = expect
    tty.screenHandle = win

    function win.close()
        if not win then error("terminal is already closed", 2) end
        win = nil
        tty.isLocked = false
        tty.frontmostProcess = table.remove(tty.processList)
        tty.screenHandle = nil
        redraw(tty, true)
    end

    function win.getSize()
        return size.width * 6, size.height * 9
    end

    function win.clear()
        if not win then error("terminal is already closed", 2) end
        for y = 1, size.height * 9 do buffer[y] = ('\15'):rep(size.width * 6) end
        redraw(tty, true)
    end

    function win.getPixel(x, y)
        if not win then error("terminal is already closed", 2) end
        expect(1, x, "number")
        expect(2, y, "number")
        expect.range(x, 0, size.width * 6 - 1)
        expect.range(y, 0, size.height * 9 - 1)
        x, y = math.floor(x), math.floor(y)
        return buffer[y+1]:byte(x+1)
    end

    function win.setPixel(x, y, color)
        if not win then error("terminal is already closed", 2) end
        expect(1, x, "number")
        expect(2, y, "number")
        expect(3, color, "number")
        expect.range(x, 0, size.width * 6 - 1)
        expect.range(y, 0, size.height * 9 - 1)
        expect.range(color, 0, 255)
        x, y = math.floor(x), math.floor(y)
        buffer[y+1] = buffer[y+1]:sub(1, x) .. string.char(color) .. buffer[y+1]:sub(x + 2)
        buffer.dirtyRects[#buffer.dirtyRects+1] = {x = x, y = y, color = color}
        --if not buffer.frozen then redraw(tty) end
    end

    function win.getPixels(x, y, width, height, asStr)
        if not win then error("terminal is already closed", 2) end
        expect(1, x, "number")
        expect(2, y, "number")
        expect(3, width, "number")
        expect(4, height, "number")
        expect(5, asStr, "boolean", "nil")
        expect.range(width, 0)
        expect.range(height, 0)
        x, y = math.floor(x), math.floor(y)
        local t = {}
        for py = 1, height do
            if asStr then t[py] = buffer[y+py]:sub(x + 1, x + width)
            else t[py] = {buffer[y+py]:sub(x + 1, x + width):byte(1, -1)} end
        end
        return t
    end

    function win.drawPixels(x, y, data, width, height)
        if not win then error("terminal is already closed", 2) end
        expect(1, x, "number")
        expect(2, y, "number")
        expect(3, data, "table", "number")
        local isn = type(data) == "number"
        expect(4, width, "number", not isn and "nil" or nil)
        expect(5, height, "number", not isn and "nil" or nil)
        expect.range(x, 0, size.width * 6 - 1)
        expect.range(y, 0, size.height * 9 - 1)
        if width then expect.range(width, 0) end
        if height then expect.range(height, 0) end
        if isn then expect.range(data, 0, 255) end
        if width == 0 or height == 0 then return end
        x, y = math.floor(x), math.floor(y)
        if width and x + width >= size.width * 6 then width = size.width * 6 - x end
        height = height or #data
        local rect = {x = x, y = y, width = width, height = height}
        for py = 1, height do
            if y + py > size.height * 9 then break end
            if isn then
                local s = string.char(data):rep(width)
                buffer[y+py] = buffer[y+py]:sub(1, x) .. s .. buffer[y+py]:sub(x + width + 1)
                rect[py] = s
            elseif data[py] ~= nil then
                if type(data[py]) ~= "table" and type(data[py]) ~= "string" then
                    error("bad argument #3 to 'drawPixels' (invalid row " .. py .. ")", 2)
                end
                local width = width or #data[py]
                if x + width >= size.width * 6 then width = size.width * 6 - x end
                local s
                if type(data[py]) == "string" then
                    s = data[py]
                    if #s < width then s = s .. ('\15'):rep(width - #s)
                    elseif #s > width then s = s:sub(1, width) end
                else
                    s = ""
                    for px = 1, width do s = s .. string.char(data[py][px] or buffer[y+py]:byte(x+px)) end
                end
                buffer[y+py] = buffer[y+py]:sub(1, x) .. s .. buffer[y+py]:sub(x + width + 1)
                rect[py] = s
            end
        end
        buffer.dirtyRects[#buffer.dirtyRects+1] = rect
        --if not buffer.frozen then redraw(tty) end
    end

    function win.getFrozen()
        if not win then error("terminal is already closed", 2) end
        return buffer.frozen
    end

    function win.setFrozen(f)
        if not win then error("terminal is already closed", 2) end
        expect(1, f, "boolean")
        buffer.frozen = f
        --if not buffer.frozen then redraw(tty) end
    end

    function win.getPaletteColor(color)
        if not win then error("terminal is already closed", 2) end
        expect(1, color, "number")
        expect.range(color, 0, 255)
        return table.unpack(buffer.palette[color])
    end

    function win.setPaletteColor(color, r, g, b)
        if not win then error("terminal is already closed", 2) end
        expect(1, color, "number")
        expect(2, r, "number")
        if g == nil and b == nil then r, g, b = bit32.band(bit32.rshift(r, 16), 0xFF) / 255, bit32.band(bit32.rshift(r, 8), 0xFF) / 255, bit32.band(r, 0xFF) / 255 end
        expect(3, g, "number")
        expect(4, b, "number")
        expect.range(r, 0, 1)
        expect.range(g, 0, 1)
        expect.range(b, 0, 1)
        expect.range(color, 0, 255)
        buffer.palette[color] = {r, g, b}
        buffer.dirtyPalette[color] = true
        --if not buffer.frozen then redraw(tty) end
    end

    local nativePaletteColor = term.nativePaletteColor
    function win.nativePaletteColor(color)
        expect(1, color, "number")
        expect.range(color, 0, 15)
        return nativePaletteColor(2^color)
    end

    for _, v in pairs(win) do setfenv(v, process.env) debug.protect(v) end
    win.getPaletteColour = win.getPaletteColor
    win.setPaletteColour = win.setPaletteColor
    win.nativePaletteColour = win.nativePaletteColor
    process.dependents[#process.dependents+1] = {gc = function() if win then return win.close() end end}
    redraw(tty, true)
    return win
end

function syscalls.opengfx(process, thread)
    if not process.stdout or not process.stdout.isTTY then return nil, "No valid TTY attached" end
    if process ~= process.stdout.frontmostProcess then
        syscalls.kill(KERNEL, nil, process.id, 22)
        if process.paused then return kSyscallYield, "openterm" end
    end
    return terminal.opengfx(process.stdout, process)
end

function syscalls.mktty(process, thread, width, height)
    expect(1, width, "number")
    expect(2, height, "number")
    expect.range(width, 1)
    expect.range(height, 1)
    local tty = terminal.makeTTY(term, width, height)
    tty.id = math.random(0, 0x7FFFFFFF)
    tty.process = process
    local mt = {__index = tty, __metatable = {__name = "TTY"}}
    local retval = setmetatable({}, mt)
    local do_syscall = do_syscall
    function retval.sendEvent(event, param)
        return do_syscall("__ttyevent", retval, event, param)
    end
    function retval.write(text)
        tty.buffer = tty.buffer .. tostring(text)
        return do_syscall("__ttyevent", retval, "paste", tostring(text))
    end
    debug.protect(retval.sendEvent)
    debug.protect(retval.write)
    mt.__newindex = function() error("cannot modify TTY", 2) end
    terminal.userTTYs[retval] = tty
    process.dependents[#process.dependents+1] = {gc = function() terminal.userTTYs[retval] = nil end}
    return retval
end

function syscalls.__ttyevent(process, thread, usertty, event, param)
    expect(1, usertty, "table")
    expect(2, event, "string")
    expect(3, param, "table")
    local tty = terminal.userTTYs[usertty]
    if not tty then error("Invalid TTY") end
    if tty.process ~= process then error("Invalid TTY") end
    --syslog.debug("TTY event", event, tostring(tty.frontmostProcess))
    if not tty.frontmostProcess then return end
    --syslog.debug(tostring(tty), tostring(tty.frontmostProcess.stdin), tostring(tty.frontmostProcess.stdout), tostring(tty.frontmostProcess.stderr))
    if event == "key" then
        expect.field(param, "keycode", "number")
        expect.field(param, "isRepeat", "boolean")
        -- TODO: fix held keys
        tty.frontmostProcess.eventQueue[#tty.frontmostProcess.eventQueue+1] = {"key", {keycode = param.keycode, isRepeat = param.isRepeat, ctrlHeld = keysHeld.ctrl, altHeld = keysHeld.alt, shiftHeld = keysHeld.shift}}
        if not tty.isLocked then
            if param.keycode == 10 then
                if tty.flags.cbreak then
                    tty.buffer = tty.buffer .. "\n"
                else
                    tty.buffer = tty.buffer .. tty.preBuffer .. "\n"
                    tty.preBuffer = ""
                end
                if tty.flags.echo then terminal.write(tty, "\n") terminal.redraw(tty) end
            elseif param.keycode == 8 then
                if tty.flags.cbreak then
                    -- TODO: uh, what is this supposed to be?
                elseif #tty.preBuffer > 0 then
                    tty.preBuffer = tty.preBuffer:sub(1, -2)
                    if tty.flags.echo then terminal.write(tty, "\b \b") terminal.redraw(tty) end
                end
            end
        end
    elseif event == "key_up" then
        expect.field(param, "keycode", "number")
        tty.frontmostProcess.eventQueue[#tty.frontmostProcess.eventQueue+1] = {"key_up", {keycode = param.keycode, ctrlHeld = keysHeld.ctrl, altHeld = keysHeld.alt, shiftHeld = keysHeld.shift}}
    elseif event == "char" then
        expect.field(param, "character", "string")
        tty.frontmostProcess.eventQueue[#tty.frontmostProcess.eventQueue+1] = {"char", {character = param.character}}
        if not tty.isLocked then
            if tty.flags.cbreak then tty.buffer = tty.buffer .. param.character
            else tty.preBuffer = tty.preBuffer .. param.character end
            if tty.flags.echo then terminal.write(tty, param.character) terminal.redraw(tty) end
        end
    elseif event == "paste" then
        expect.field(param, "text", "string")
        tty.frontmostProcess.eventQueue[#tty.frontmostProcess.eventQueue+1] = {"paste", {text = param.text}}
        if not tty.isLocked then
            if tty.flags.cbreak then tty.buffer = tty.buffer .. param.text
            else tty.preBuffer = tty.preBuffer .. param.text end
            if tty.flags.echo then terminal.write(tty, param.text) terminal.redraw(tty) end
        end
    elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" then
        expect.field(param, "x", "number")
        expect.field(param, "y", "number")
        expect.field(param, "button", "number")
        -- TODO: buttonMask
        tty.frontmostProcess.eventQueue[#tty.frontmostProcess.eventQueue+1] = {event, {x = param.x, y = param.y, button = param.button, buttonMask = 0}}
    elseif event == "mouse_scroll" then
        expect.field(param, "x", "number")
        expect.field(param, "y", "number")
        expect.field(param, "direction", "number")
        -- TODO: buttonMask
        tty.frontmostProcess.eventQueue[#tty.frontmostProcess.eventQueue+1] = {event, {x = param.x, y = param.y, button = param.direction}}
    else error("Invalid event") end
end

function syscalls.stdin(process, thread, handle)
    expect(1, handle, "number", "table", "string", "nil")
    if process.stdin and process.stdin.isTTY and process.stdin.frontmostProcess == process then
        --process.stdin.frontmostProcess = table.remove(process.stdin.processList)
        process.stdin.preBuffer = ""
    end
    if type(handle) == "number" then
        handle = TTY[handle]
        if handle and process.stdin.frontmostProcess == process then
            process.stdin.frontmostProcess = table.remove(process.stdin.processList)
            handle.processList[#handle.processList+1] = handle.frontmostProcess
            handle.frontmostProcess = process
            if discord and process.stdin == currentTTY then discord("Phoenix", "Executing " .. process.name) end
        end
        process.stdin = handle
    elseif type(handle) == "string" then
        local node = hardware.get(handle)
        if not node then error("bad argument #1 (no such device)", 2) end
        if not node.internalState.tty then error("bad argument #1 (no TTY available on device)", 2) end
        handle = node.internalState.tty
        if process.stdin.frontmostProcess == process then
            process.stdin.frontmostProcess = table.remove(process.stdin.processList)
            handle.processList[#handle.processList+1] = handle.frontmostProcess
            handle.frontmostProcess = process
        end
        process.stdin = handle
    elseif handle == nil then
        if process.stdin.frontmostProcess == process then
            process.stdin.frontmostProcess = table.remove(process.stdin.processList)
        end
        process.stdin = nil
    else
        if handle.isTTY then
            handle = terminal.userTTYs[handle]
            if not handle then error("bad argument #1 (invalid TTY)", 2) end
            if process.stdin.frontmostProcess == process then
                process.stdin.frontmostProcess = table.remove(process.stdin.processList)
                handle.processList[#handle.processList+1] = handle.frontmostProcess
                handle.frontmostProcess = process
                handle.preBuffer = ""
            end
        else
            expect.field(handle, "read", "function")
            local read = handle.read
            handle = {
                buffer = "",
                read = function(...)
                    local ok, res = userModeCallback(process, read, ...)
                    if ok then return res else error(res, 2) end
                end
            }
        end
        process.stdin = handle
    end
end

function syscalls.stdout(process, thread, handle)
    expect(1, handle, "number", "table", "string", "nil")
    if process.stdout and process.stdout.isTTY and process.stdout.frontmostProcess == process then
        --process.stdout.frontmostProcess = table.remove(process.stdout.processList)
        if discord and process.stdout == currentTTY then discord("Phoenix", "Executing " .. process.stdout.frontmostProcess.name) end
    end
    if type(handle) == "number" then
        handle = TTY[handle]
        if handle and process.stdout.frontmostProcess == process then
            process.stdout.frontmostProcess = table.remove(process.stdout.processList)
            handle.processList[#handle.processList+1] = handle.frontmostProcess
            handle.frontmostProcess = process
            if discord and process.stdout == currentTTY then discord("Phoenix", "Executing " .. process.name) end
        end
        process.stdout = handle
    elseif type(handle) == "string" then
        local node = hardware.get(handle)
        if not node then error("bad argument #1 (no such device)", 2) end
        if not node.internalState.tty then error("bad argument #1 (no TTY available on device)", 2) end
        handle = node.internalState.tty
        if process.stdout.frontmostProcess == process then
            process.stdout.frontmostProcess = table.remove(process.stdout.processList)
            handle.processList[#handle.processList+1] = handle.frontmostProcess
            handle.frontmostProcess = process
            if discord and process.stdout == currentTTY then discord("Phoenix", "Executing " .. process.name) end
        end
        process.stdout = handle
    elseif handle == nil then
        if process.stdout.frontmostProcess == process then
            process.stdout.frontmostProcess = table.remove(process.stdout.processList)
            if discord and process.stdout == currentTTY then discord("Phoenix", "Executing " .. process.name) end
        end
        process.stdout = nil
    else
        if handle.isTTY then
            handle = terminal.userTTYs[handle]
            if not handle then error("bad argument #1 (invalid TTY)", 2) end
            if process.stdout.frontmostProcess == process then
                process.stdout.frontmostProcess = table.remove(process.stdout.processList)
                handle.processList[#handle.processList+1] = handle.frontmostProcess
                handle.frontmostProcess = process
                if discord and process.stdout == currentTTY then discord("Phoenix", "Executing " .. process.name) end
            end
        else
            expect.field(handle, "write", "function")
            local write = handle.write
            handle = {
                write = function(...)
                    local ok, res = userModeCallback(process, write, ...)
                    if ok then return res else error(res, 2) end
                end
            }
        end
        process.stdout = handle
    end
end

function syscalls.stderr(process, thread, handle)
    expect(1, handle, "number", "table", "string", "nil")
    if process.stderr and process.stderr.isTTY and process.stderr.frontmostProcess == process then
        --process.stderr.frontmostProcess = table.remove(process.stderr.processList)
    end
    if type(handle) == "number" then
        handle = TTY[handle]
        if handle and process.stderr.frontmostProcess == process then
            process.stderr.frontmostProcess = table.remove(process.stderr.processList)
            handle.processList[#handle.processList+1] = handle.frontmostProcess
            handle.frontmostProcess = process
            if discord and process.stderr == currentTTY then discord("Phoenix", "Executing " .. process.name) end
        end
        process.stderr = handle
    elseif type(handle) == "string" then
        local node = hardware.get(handle)
        if not node then error("bad argument #1 (no such device)", 2) end
        if not node.internalState.tty then error("bad argument #1 (no TTY available on device)", 2) end
        handle = node.internalState.tty
        if process.stderr.frontmostProcess == process then
            process.stderr.frontmostProcess = table.remove(process.stderr.processList)
            handle.processList[#handle.processList+1] = handle.frontmostProcess
            handle.frontmostProcess = process
        end
        process.stderr = handle
    elseif handle == nil then
        if process.stderr.frontmostProcess == process then
            process.stderr.frontmostProcess = table.remove(process.stderr.processList)
        end
        process.stderr = nil
    else
        if handle.isTTY then
            handle = terminal.userTTYs[handle]
            if not handle then error("bad argument #1 (invalid TTY)", 2) end
            if process.stderr.frontmostProcess == process then
                process.stderr.frontmostProcess = table.remove(process.stderr.processList)
                handle.processList[#handle.processList+1] = handle.frontmostProcess
                handle.frontmostProcess = process
            end
        else
            expect.field(handle, "write", "function")
            local write = handle.write
            handle = {
                write = function(...)
                    local ok, res = userModeCallback(process, write, ...)
                    if ok then return res else error(res, 2) end
                end
            }
        end
        process.stderr = handle
    end
end

function syscalls.istty(process, thread)
    return process.stdin and process.stdin.isTTY, process.stdout and process.stdout.isTTY
end

function syscalls.termsize(process, thread)
    if not process.stdout or not process.stdout.isTTY then return nil, nil end
    return process.stdout.size.width, process.stdout.size.height
end
