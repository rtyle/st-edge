-- vim: ts=4:sw=4:expandtab

--[[
Command Line Interpreter to interact with LC7001 controllers.

With no command line arguments,
interaction is directed only to the LC7001 controller identified as LCM1.local.
Otherwise, each command line argument should identify a controller
in the form of "password@host" or just "host" (no password).

This code serves as a demonstration of expected lc7001.lua usage.

We use lc7001.Controller which acts as an lc7001.Authenticator
and then an lc7001.Emitter for each connection/session with the controller.
With LUALOG=DEBUG in the environment, the LC7001 messages passed in (>) to us
and out (<) from us are logged.
This is a great way to demonstrate the LC7001 behavior.

We offer an interpreter service on an ephemeral port that one
can interact indirectly with using a command like "socat".
Such a command line is suggested on STDOUT when we are started.
Each interpreter service takes lines from its client,
composes messages from them and sends them to the currently targeted controller.

Commands are:

            a blank line sends a REPORT_SYSTEM_PROPERTIES message

a #         send a SET_SYSTEM_PROPERTIES message with ADD_A_LIGHT True|False

d #         send a DELETE_ZONE message for ZID #

c           target the next controller in rotation (start with first one)

s           send a LIST_SCENES message
s *         send a LIST_SCENES then a REPORT_SCENE_PROPERTIES for each
s SID       send a REPORT_SCENE_PROPERTIES message for SID (0-99)

z           send a LIST_ZONES message
z *         send a LIST_ZONES then a REPORT_ZONE_PROPERTIES for each
z ZID       send a REPORT_ZONE_PROPERTIES message for ZID (0-99)
z ZID #     send a SET_ZONE_PROPERTIES message with POWER as False|True
z ZID #%    send a SET_ZONE_PROPERTIES message with POWER_LEVEL as #
z ZID #/    send a SET_ZONE_PROPERTIES message with RAMP_RATE as #
--]]

local cosock = require "cosock"

local lc7001 = require "lc7001"

local socket = cosock.socket    -- layer over require("socket")

local authentication = {}
local inventory = lc7001.Inventory(authentication)

-- cross reference lc7001 inventory chronologically
local controllers = {}
inventory:on(inventory.EVENT_ADD, function(controller)
    table.insert(controllers, controller)
end)
inventory:on(inventory.EVENT_REMOVE, function(controller)
    for i, _controller in ipairs(controllers) do
        if _controller == controller then
            table.remove(controllers, i)
            return
        end
    end
end)

cosock.spawn(function()
    local discover = true
    for _, _arg in ipairs{"0026ec02ff14=........"} do
        if _arg:match("=") then
            for controller_id, password in _arg:gmatch("(%x+)=(.+)") do
                authentication[controller_id] = lc7001.hash_password(password)
            end
        else
            inventory:ask(lc7001.Controller(_arg))
            discover = false
        end
    end
    if discover then
        inventory:discover()
    end
end, "inventory")

local function starts_with(whole, part)
    return part == whole:sub(1, #part)
end

local function tokens(line)
    return coroutine.wrap(function()
        for token in line:gmatch("%S+") do
            coroutine.yield(token)
        end
    end)
end

local function command_scene(controller, token)
    local sid = token()
    if sid then
        if "*" == sid then
            controller:converse(controller:compose_list_scenes(), function(_, list)
                controller.Status(list):error_if()
                for _, item in pairs(list[controller.SCENE_LIST]) do
                    controller:send(controller:compose_report_scene_properties(item[controller.SID]))
                end
            end)
        else
            controller:send(controller:compose_report_scene_properties(tonumber(sid)))
        end
    else
        controller:send(controller:compose_list_scenes())
    end
end

local function command_zone(controller, token)
    local zid = token()
    if zid then
        if "*" == zid then
            controller:converse(controller:compose_list_zones(), function(_, list)
                controller.Status(list):error_if()
                for _, item in pairs(list[controller.ZONE_LIST]) do
                    controller:send(controller:compose_report_zone_properties(item[controller.ZID]))
                end
            end)
        else
            zid = tonumber(zid)
            local property_list = {}
            for property in token do
                local value, qualifier = property:match("^(%d+)([%%/])$")
                if qualifier then
                    local number = tonumber(value)
                    if "%" == qualifier then
                        property_list[controller.POWER_LEVEL] = number
                    else
                        property_list[controller.RAMP_RATE] = number
                    end
                else
                    property_list[controller.POWER] = "0" ~= property
                end
            end
            if nil == next(property_list) then
                controller:send(controller:compose_report_zone_properties(zid))
            else
                controller:send(controller:compose_set_zone_properties(zid, property_list))
            end
        end
    else
        controller:send(controller:compose_list_zones())
    end
end

local function command(controller, line)
    local token = tokens(line)
    local operation = token()
    if operation then
        if starts_with(operation, "a") then
            local enable = token()
            if enable then
                enable = 0 ~= tonumber(enable)
            else
                enable = true
            end
            controller:send(controller:compose_set_system_properties({[controller.ADD_A_LIGHT] = enable}))
        elseif starts_with(operation, "d") then
            local zid = token()
            if zid then
                controller:send(controller:compose_delete_zone(tonumber(zid)))
            end
        elseif starts_with(operation, "c") then
            return true
        elseif starts_with(operation, "s") then
            command_scene(controller, token)
        elseif starts_with(operation, "z") then
            command_zone(controller, token)
        end
    else
        controller:send(controller:compose_report_system_properties())
    end
end

-- we would have liked to read commands from stdin
-- but there does not seem to be a cosock-friendly way to do this.
-- instead, we listen and provide this service to TCP clients.
cosock.spawn(function()
    local listener, bind_error = socket.bind("localhost", 0)
    if bind_error then error(bind_error) end
    local listener_address, listener_port, _, getsockname_error = listener:getsockname()
    if getsockname_error then error(getsockname_error) end
    print("socat - TCP:" .. listener_address .. ":" .. listener_port)
    while true do
        local _, _, listener_select_error = socket.select({listener})
        if listener_select_error then error(listener_select_error) end
        local server, accept_error = listener:accept()
        if accept_error then error(accept_error) end
        local client_address, client_port, _, getpeername_error = server:getpeername()
        if getpeername_error then error(getpeername_error) end
        cosock.spawn(function()
            local index = 1
            local last_controller
            while true do
                local _, _, server_select_error = socket.select({server})
                if server_select_error then error(server_select_error) end
                local line, receive_error = server:receive()
                if receive_error then
                    if "closed" == receive_error then
                        return
                    end
                    error(receive_error)
                end
                local controller = controllers[index]
                if nil == controller then
                    index = 1
                    controller = controllers[index]
                end
                if last_controller ~= controller then
                    if controller then
                        print(controller:address())
                    end
                    last_controller = controller
                end
                if controller then
                    if command(controller, line) then
                        index = index + 1
                    end
                end
            end
        end, client_address .. ":" .. client_port)
    end
end, "listener")

cosock.run()
