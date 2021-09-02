local args = {...}
if #args < 2 then error("Usage: compile <kernel.lua> <output.lua>") end

local file, err = fs.open(args[1], "r")
if not file then error("Could not open kernel: " .. err) end
local kernel = file.readAll()
file.close()

local parts = ""
for _, v in ipairs(fs.list(args[1] .. ".d")) do
    file, err = fs.open(fs.combine(args[1] .. ".d", v), "r")
    if not file then error("Could not open component " .. v .. ": " .. err) end
    parts = parts .. "--#region " .. v .. "\n\n" .. file.readAll() .. "\n\n--#endregion\n\n"
    file.close()
end

file, err = fs.open(args[2], "w")
if not file then error("Could not open output: " .. err) end
file.write(kernel:sub(1, kernel:find("-- ==== LOADER ====", 1, true) - 1))
file.write(parts)
file.write(kernel:sub(select(2, kernel:find("-- == END LOADER ==", 1, true)) + 1))
file.close()
print("Wrote compiled kernel to " .. args[2])