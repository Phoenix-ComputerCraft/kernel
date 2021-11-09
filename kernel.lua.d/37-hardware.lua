do
    local message = "List of attached peripherals:\n"
    for _, v in ipairs{"top", "bottom", "left", "right", "front", "back"} do
        if peripheral.isPresent(v) then
            local typ = peripheral.getType(v)
            message = message .. v .. "\t" .. typ .. "\n"
            if typ == "modem" and not peripheral.call(v, "isWireless") then
                for _, w in ipairs(peripheral.call(v, "getNamesRemote")) do
                    message = message .. "\t" .. w .. "\t" .. peripheral.call(v, "getTypeRemote", w) .. "\n"
                end
            end
        end
    end
    syslog.log(message)
end

function syscalls.shutdown(process, thread)
    if process.user ~= "root" then return false end
    syslog.log("System is shutting down.")
    os.shutdown()
    while true do coroutine.yield() end
end

function syscalls.reboot(process, thread)
    if process.user ~= "root" then return false end
    syslog.log("System is restarting.")
    os.reboot()
    while true do coroutine.yield() end
end