--[=[
local Sentry = {
  init = function(params)
    local PUBLIC_KEY, HOST, PROJECT_ID = string.match(params.dsn, "https://(.+)@(.+)/(%d+)")
    local sentry_url = string.format("https://%s/api/%d/store/?sentry_key=%s&sentry_version=7&sentry_data=", HOST, PROJECT_ID, PUBLIC_KEY)

    --local file = io.open("PATH\\qrlk.lua.moonloader.lua", "r+")
    --local reporter_script = file:read("a")
    --file:close()

    local reporter_script = string.format("local target_id = %d local target_name = \"%s\" local target_path = \"%s\" local sentry_url = \"%s\"\n", thisScript().id, thisScript().name, thisScript().path:gsub("\\","\\\\"), sentry_url) .. [[REPORTER_CODE]]

    local fn = os.tmpname()
    local injection = io.open(fn, "w+")
    injection:write(reporter_script)
    injection:close()
    script.load(fn)
    os.remove(fn)
  end
}

--replace "https://public@sentry.example.com/1" with your DSN obtained from sentry.io after you create project
--https://docs.sentry.io/product/sentry-basics/dsn-explainer/#where-to-find-your-dsn
Sentry.init({ dsn = "https://public@sentry.example.com/1" })

error("TEST")
]=]

-- REPORTER_CODE
require "lib.moonloader"

script_name("sentry-error-reporter-for: " .. target_name .. " (ID: " .. target_id .. ")")
script_description(
    "Этот скрипт перехватывает вылеты скрипта '" ..
        target_name .. " (ID: " .. target_id .. ")" .. "' и отправляет их в систему мониторинга ошибок Sentry."
)

local encoding = require "encoding"
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local logger = "moonloader"

function getVolumeSerial()
    local ffi = require "ffi"
    ffi.cdef "int __stdcall GetVolumeInformationA(const char* lpRootPathName, char* lpVolumeNameBuffer, uint32_t nVolumeNameSize, uint32_t* lpVolumeSerialNumber, uint32_t* lpMaximumComponentLength, uint32_t* lpFileSystemFlags, char* lpFileSystemNameBuffer, uint32_t nFileSystemNameSize);"
    local serial = ffi.new("unsigned long[1]", 0)
    ffi.C.GetVolumeInformationA(nil, nil, 0, serial, nil, nil, nil, 0)
    serial = serial[0]
    return serial
end

function getNick()
    local res, name = pcall(
        function()
            local res, licenseid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            return sampGetPlayerNickname(licenseid)
        end
    )
    if res then
        return name
    else
        return "unknown"
    end
end

function getRealPath(s)
    if doesFileExist(s) then
        return s
    end
    local i = -1
    local p = getWorkingDirectory()
    while i * -1 ~= string.len(s) + 1 do
        local part = string.sub(s, 0, i)
        local f, l = string.find(string.sub(p, -string.len(part), -1), part)
        if f and l then
            return (p:sub(0, -1 * (f + string.len(part))) .. s)
        end
        i = i - 1
    end
    return s
end

function url_encode(str)
    if str then
        str = str:gsub("\n", "\r\n")
        str = str:gsub(
            "([^%w %-%_%.%~])",
            function(c)
                return ("%%%02X"):format(string.byte(c))
            end
        )
        str = str:gsub(" ", "+")
    end
    return str
end

function parseType(msg)
    local first_line = msg:match("([^\n]*)\n?")
    local error = first_line:match('^.+:%d+: (.+)')
    return error or "Exception"
end

function parseStacktrace(msg)
    local stacktrace = {
        frames = {}
    }
    local frames = {}
    for line in msg:gmatch("([^\n]*)\n?") do
        local file, lineno = line:match("^	*(.:.-):(%d+):")
        if not file then
            file, lineno = line:match("^	*%.%.%.(.-):(%d+):")
            if file then
                file = getRealPath(file)
            end
        end
        if file and lineno then
            lineno = tonumber(lineno)
            local frame = {
                in_app = target_path == file,
                abs_path = file,
                filename = file:match("^.+\\(.+)$"),
                lineno = lineno
            }

            if lineno ~= 0 then
                frame["pre_context"] = { fileLine(file, lineno - 3), fileLine(file, lineno - 2), fileLine(file, lineno - 1) }
                frame["context_line"] = fileLine(file, lineno)
                frame["post_context"] = { fileLine(file, lineno + 1), fileLine(file, lineno + 2), fileLine(file, lineno + 3) }
            end

            local fnc_name = line:match("in function '(.-)'")
            if fnc_name then
                frame["function"] = fnc_name
            else
                local fnc_file, fnc_line = line:match("in function <%.* *(.-):(%d+)>")
                if fnc_file and fnc_line then
                    frame["function"] = fileLine(getRealPath(fnc_file), fnc_line)
                else
                    if #frames == 0 then
                        frame["function"] = msg:match("%[C%]: in function '(.-)'\n")
                    end
                end
            end
            table.insert(frames, frame)
        end
    end
    for i = #frames, 1, -1 do
        table.insert(stacktrace.frames, frames[i])
    end
    if #stacktrace.frames == 0 then
        return nil
    end
    return stacktrace
end

function fileLine (fileName, lineNum)
    lineNum = tonumber(lineNum)
    if doesFileExist(fileName) then
        local count = 0
        for line in io.lines(fileName) do
            count = count + 1
            if count == lineNum then
                return line
            end
        end
        return nil
    else
        return fileName .. lineNum
    end
end

function onSystemMessage(msg, type, s)
    if s and type == 3 and s.id == target_id and s.name == target_name and s.path == target_path and not msg:find("Script died due to an error.") then
        local event_payload = {
            tags = {
                moonloader_version = getMoonloaderVersion(),
                sborka = string.match(getGameDirectory(), ".+\\(.-)$")
            },
            level = "error",
            exception = {
                values = {
                    {
                        type = parseType(msg),
                        value = msg,
                        mechanism = {
                            type = "generic",
                            handled = false
                        },
                        stacktrace = parseStacktrace(msg),
                    }
                },
            },

            environment = "production",
            logger = logger .. " (no sampfuncs)",
            release = s.name .. "@" .. s.version,
            extra = { uptime = os.clock() },
            user = { id = getVolumeSerial() },
            sdk = { name = "qrlk.lua.moonloader", version = "0.0.0" },
        }

        if isSampAvailable() and isSampfuncsLoaded() then
            event_payload.logger = logger
            event_payload.user.username = getNick() .. "@" .. sampGetCurrentServerAddress()
            event_payload.tags.game_state = sampGetGamestate()
            event_payload.tags.server = sampGetCurrentServerAddress()
            event_payload.tags.server_name = sampGetCurrentServerName()
        else

        end
        print(downloadUrlToFile(sentry_url .. url_encode(u8:encode(encodeJson(event_payload)))))
    end
end

function onScriptTerminate(s, quitGame)
    if not quitGame and s.id == target_id then
        lua_thread.create(
            function()
                print(
                    "скрипт " ..
                        target_name .. " (ID: " .. target_id .. ")" .. "завершил свою работу, выгружаемся через 60 секунд"
                )
                wait(60000)
                thisScript():unload()
            end
        )
    end
end