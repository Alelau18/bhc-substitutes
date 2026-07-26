--[[
This is a beta version of a connector script that will allow mGBA to
communicate with Archipelago's BizHawk Client (yes, the name, I know).

Requires mGBA version 0.10.0 or newer.

Place it in the same directory as the normal BizHawk connector
(`Archipelago/data/lua/`). Open your ROM in mGBA, and open
`Tools > Scripting...` in the menus. Then `File > Load script...` in the new
Scripting window and select this file.

Everything should now work just as it does with BizHawk with one exception:

You can only have one instance of mGBA running this script at a time.

Multiple instances of mGBA won't detect each other and will attempt to
communicate over the same port. So you won't be able to have more than one
game connected at a time through mGBA. Still looking for a solution.
]]

local SCRIPT_VERSION = 1
local DEBUG = false

--[[
Copyright (c) 2023-2024 Zunawe

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local base64 = require("base64")
local json = require("json")

local SOCKET_PORT_FIRST = 43055
local SOCKET_PORT_RANGE_SIZE = 5
local SOCKET_PORT_LAST = SOCKET_PORT_FIRST + SOCKET_PORT_RANGE_SIZE

local STATE_NOT_CONNECTED = 0
local STATE_CONNECTED = 1

local current_state = STATE_NOT_CONNECTED

local message_buffer = console:createBuffer("Archipelago Connector")

local server = nil
local client = nil

local last_activity

local locked = false

-- `error` is redefined further down as this script's socket error handler, which
-- shadows Lua's builtin for every call made after that point. Keep the real one.
local raise = error

-- BizHawk domain name -> mGBA `emu.memory` key.
--
-- Looked up per request rather than cached: mGBA destroys the core when a ROM is
-- loaded, so a domain handle held across that boundary refers to a core that no
-- longer exists.
local GB_DOMAINS = {
    ["ROM"] = "cart0",
    ["VRAM"] = "vram",
    ["SRAM"] = "sram",
    ["CartRAM"] = "sram",
    ["WRAM"] = "wram",
    ["OAM"] = "oam",
    ["IO"] = "io",
    ["HRAM"] = "hram",
}

local GBA_DOMAINS = {
    ["BIOS"] = "bios",
    ["ROM"] = "cart0",
    ["EWRAM"] = "wram",
    ["IWRAM"] = "iwram",
    ["VRAM"] = "vram",
    ["OAM"] = "oam",
    ["Combined WRAM"] = "wram",
}

-- Game Boy header byte 0x148 encodes the cartridge ROM size as 32 KiB << n.
-- Read through the ordinary memory path, so it still answers in the moments
-- where emu:romSize() does not. Values above 8 are not defined by the hardware.
function rom_size_from_gb_header()
    local success, code = pcall(function()
        return get_memory_domain("ROM"):read8(0x148)
    end)

    if not success or type(code) ~= "number" or code > 8 then
        return nil
    end

    return 32768 << code
end

-- mGBA snapshots each memory block's descriptor when the scripting context
-- attaches, which happens before the reset that fills in the real ROM size
-- (mgba-emu/mgba#3640, fixed for 0.11.0). So cart0:size() reports the 0x800000
-- placeholder for every ROM after the first in a session, and clients that
-- identify a game by its ROM size stop recognising it. emu:romSize() reads the
-- loaded ROM's file handle and stays correct.
function get_memory_domain_size(name)
    if name == "ROM" then
        local success, size = pcall(function() return emu:romSize() end)

        if success and type(size) == "number" and size > 0 then
            return size
        end

        if emu:platform() == C.PLATFORM.GB then
            local from_header = rom_size_from_gb_header()

            if from_header then
                return from_header
            end
        end

        -- Deliberately not the descriptor: its 0x800000 placeholder is a
        -- plausible size, so every handler would reject the ROM with nothing to
        -- show why. 0 is a size no real ROM has -- clients compare sizes during
        -- validation and fail it softly, then retry on their next poll, and the
        -- console names the failure. An ERROR response would be worse:
        -- BizHawkClient's watcher task does not catch ConnectorError, so
        -- raising here ends the client's sync for the whole session over what
        -- is usually a transient.
        console:error("Could not determine ROM size; reporting 0")
        return 0
    end

    return get_memory_domain(name):size()
end

-- Works around stale GBC WRAM geometry after a ROM swap.
--
-- Same mGBA defect as the ROM size above: the descriptors are snapshotted before
-- the core's first reset, while the core still holds the init-time DMG table. For
-- WRAM that means 0x2000 and unbanked instead of CGB's 0x8000 across 8 banks, so
-- every address >= 0x1000 lands in the wrong bank. Reads still succeed, which is
-- why this is invisible: a client's guards simply never match again.
--
-- The stale descriptor resolves request R as rawRead8(0xC000 + R % 0x2000,
-- segment = R / 0x2000); a healthy one resolves linear A as
-- rawRead8(0xD000 + A % 0x1000, segment = A / 0x1000). Solving for R gives
-- bank*0x2000 + 0x1000 + offset, so the byte is still reachable, just under a
-- different number. Measured on a swapped session: 0x1CAB read 00 while the real
-- value sat at 0x3CAB; with this proxy 0x1CAB reads 01 again.
--
-- Engages on a CGB-flagged cart whose WRAM descriptor is the DMG size. Besides
-- the stale case, a healthy session can hit that by forcing a DMG or SGB model
-- on a CGB-enhanced cart; the translation stays correct there for the 8 KiB
-- such a session actually banks (bank 1 lives at segment 1 under either
-- descriptor -- GBView8 reads the 0xD000 region as wram[segment * 0x1000 +
-- offset]), so the only misreport in that configuration is size(). For real
-- CGB sessions the stale case disappears once mGBA rebuilds descriptors on
-- reset (fixed for 0.11.0).
function gb_wram_proxy(domain)
    local is_cgb = (emu.memory.cart0:read8(0x143) & 0x80) ~= 0

    if not is_cgb or domain:size() ~= 0x2000 then
        return domain
    end

    local function translate(address)
        local bank = address >> 12

        if bank == 0 then
            return address
        end

        return (bank << 13) + 0x1000 + (address & 0xFFF)
    end

    return {
        size = function(self) return 0x8000 end,
        read8 = function(self, address) return domain:read8(translate(address)) end,
        write8 = function(self, address, value)
            return domain:write8(translate(address), value)
        end,
        -- Addresses stay contiguous under translation within one bank, so read
        -- whole runs and only break at bank boundaries.
        readRange = function(self, address, length)
            local parts = {}

            while length > 0 do
                local chunk = 0x1000 - (address & 0xFFF)
                if chunk > length then chunk = length end

                parts[#parts + 1] = domain:readRange(translate(address), chunk)
                address = address + chunk
                length = length - chunk
            end

            return table.concat(parts)
        end,
    }
end

-- Resolves a domain against whichever core is loaded right now. Raises on an
-- unknown or unavailable domain; process_request turns that into an ERROR.
function get_memory_domain(name)
    if name == "System Bus" then
        return emu
    end

    local domains = GB_DOMAINS
    if emu:platform() ~= C.PLATFORM.GB then
        domains = GBA_DOMAINS
    end

    local key = domains[name]
    if key == nil then
        raise("Unknown memory domain: "..tostring(name))
    end

    local domain = emu.memory[key]
    if domain == nil then
        raise("Memory domain unavailable: "..tostring(name))
    end

    if key == "wram" and emu:platform() == C.PLATFORM.GB then
        return gb_wram_proxy(domain)
    end

    return domain
end

function lock()
    locked = true
end

function unlock()
    locked = false
end

request_handlers = {
    ["PING"] = function (req)
        return {
            ["type"] = "PONG",
        }
    end,

    ["SYSTEM"] = function (req)
        local res = {
            ["type"] = "SYSTEM_RESPONSE",
        }

        if emu:platform() == C.PLATFORM.GB then
            if emu.memory.cart0:read8(0x143) == 0xC0 then
                res["value"] = "GBC"
            else
                res["value"] = "GB"
            end
        elseif emu:platform() == C.PLATFORM.GBA then
            res["value"] = "GBA"
        end

        return res
    end,

    ["PREFERRED_CORES"] = function (req)
        return {
            ["type"] = "PREFERRED_CORES_RESPONSE",
            ["value"] = {},
        }
    end,

    ["HASH"] = function (req)
        local checksum = 0
        for i, v in ipairs({emu:checksum(C.CHECKSUM.CRC32):byte(1, 4)}) do
            checksum = checksum * 256 + v
        end

        return {
            ["type"] = "HASH_RESPONSE",
            ["value"] = string.format("%x", checksum),
        }
    end,

    ["MEMORY_SIZE"] = function (req)
        local res = {}

        res["type"] = "MEMORY_SIZE_RESPONSE"
        res["value"] = get_memory_domain_size(req["domain"])
        return res
    end,

    ["GUARD"] = function (req)
        local expected_data = base64.decode(req["expected_data"])

        local s = get_memory_domain(req["domain"]):readRange(req["address"], #expected_data)
        local actual_data = {}
        for i = 1, #s do
            actual_data[i] = s:byte(i)
        end

        local data_is_validated = true
        for i, byte in ipairs(actual_data) do
            if byte ~= expected_data[i] then
                data_is_validated = false
                break
            end
        end

        return {
            ["type"] = "GUARD_RESPONSE",
            ["address"] = req["address"],
            ["value"] = data_is_validated,
        }
    end,

    ["LOCK"] = function (req)
        lock()

        return {
            ["type"] = "LOCKED",
        }
    end,

    ["UNLOCK"] = function (req)
        unlock()

        return {
            ["type"] = "UNLOCKED",
        }
    end,

    ["READ"] = function (req)
        local s = get_memory_domain(req["domain"]):readRange(req["address"], req["size"])
        local d = {}
        for i = 1, #s do
            d[i] = s:byte(i)
        end

        return {
            ["type"] = "READ_RESPONSE",
            ["value"] = base64.encode(d),
        }
    end,

    ["WRITE"] = function (req)
        local domain = get_memory_domain(req["domain"])
        for i, byte in ipairs(base64.decode(req["value"])) do
            domain:write8(req["address"] + (i - 1), byte)
        end

        return {
            ["type"] = "WRITE_RESPONSE",
        }
    end,

    ["DISPLAY_MESSAGE"] = function (req)
        message_buffer:print(req["message"].."\n")

        return {
            ["type"] = "DISPLAY_MESSAGE_RESPONSE",
        }
    end,

    ["default"] = function (req)
        return {
            ["type"] = "ERROR",
            ["err"] = "Unknown command: "..req["type"],
        }
    end,
}

function process_request (req)
    if request_handlers[req["type"]] then
        local success, res = pcall(request_handlers[req["type"]], req)

        if not success then
            res = {
                ["type"] = "ERROR",
                ["err"] = res
            }
        end

        return res
    else
        return request_handlers["default"](req)
    end
end

function received()
    local buffer = ""

    if not client then return end

    while true do
        local piece, err = client:receive(1024)
        if piece then
            buffer = buffer..piece
        else
            if err ~= socket.ERRORS.AGAIN then
                client:close()
            end

            break
        end
    end

    last_activity = os.time()

    for line in string.gmatch(buffer, "[^\n]+") do
        if DEBUG then
            console:log("Received: "..line)
        end

        if line == "VERSION" then
            if DEBUG then
                console:log("Response: "..tostring(SCRIPT_VERSION))
            end

            client:send(tostring(SCRIPT_VERSION).."\n")
        else
            local res = {}
            local data = json.decode(line)
            local failed_guard_response = nil
            for i, req in ipairs(data) do
                if failed_guard_response ~= nil then
                    res[i] = failed_guard_response
                else
                    res[i] = process_request(req)
                    if res[i]["type"] == "GUARD_RESPONSE" and not res[i]["value"] then
                        failed_guard_response = res[i]
                    end
                end
            end

            if DEBUG then
                console:log("Response: "..json.encode(res))
            end

            client:send(json.encode(res).."\n")
        end
    end
end

function error()
    client = nil
    console:log("Client disconnected")
end

function accept()
    console:log("")  -- Black Magic: Printing something here allows recovery from a timeout due to last_activity.
                     -- Removing this causes a timeout to be unrecoverable. The client never appears to connect.

    local err = nil
    local data = nil

    if client == nil then
        client, err = server:accept()
        if err then
            console:error(err)
            return
        end
        console:log("Connected")

        client:add("received", received)
        client:add("error", function() error() end)

        server:close()
        server = nil
    end
end

function tick()
    if client == nil then
        if server == nil then
            create_server()
        end
    else
        if last_activity ~= nil and os.time() - last_activity > 5 then
            console:log("Client timed out")
            client:close()
            client = nil
            last_activity = nil
        else
            while locked do
                client:poll()
            end
        end
    end
end

function create_server()
    local result, err

    server, err = socket.tcp()
    if err then
        console:log(err)
    end

    local port = SOCKET_PORT_FIRST

    while result == nil and port <= SOCKET_PORT_LAST do
        result, err = server:bind("127.0.0.1", port)

        if result == nil then  -- Two instances of mGBA don't conflict in this way. Unsure how to solve.
            port = port + 1
        end
    end

    result, err = server:listen(0)
    if err then
        console:log(err)
    end

    console:log("Waiting for client to connect...")

    server:add("received", accept)
end

callbacks:add("frame", tick)
