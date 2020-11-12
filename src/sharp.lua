local threader = require("threader")

-- These must be named channels so that new threads requiring sharp can use them.
local channelQueue = love.thread.getChannel("sharpQueue")
local channelReturn = love.thread.getChannel("sharpReturn")
local channelDebug = love.thread.getChannel("sharpDebug")

-- Thread-local ID.
local tuid = 0

-- The command queue thread.
local function sharpthread()
    local debuggingFlags = channelDebug:peek()
    local debugging, debuggingSharp = debuggingFlags[1], debuggingFlags[2]

    if debugging then
        print("[sharp init]", "starting thread")
    end

    local threader = require("threader")
    local fs = require("fs")
    local subprocess = require("subprocess")
    local ffi = require("ffi")
    local utils = require("utils")
    local socket = require("socket")

    -- Olympus.Sharp is stored in the sharp subdir.
    -- Running love src/ sets the cwd to the src folder.
    local cwd = fs.getcwd()
    if fs.filename(cwd) == "src" then
        cwd = fs.joinpath(fs.dirname(cwd), "love")
    end
    cwd = fs.joinpath(cwd, "sharp")

    -- The current process ID is used by Olympus.Sharp so that
    -- it dies when this process dies, without becoming a zombie.
    local pid = nil
    if ffi.os == "Windows" then
        ffi.cdef[[
            int GetCurrentProcessId();
        ]]
        pid = tostring(ffi.C.GetCurrentProcessId())

    else
        ffi.cdef[[
            int getpid();
        ]]
        pid = tostring(ffi.C.getpid())
    end

    local exename = nil
    if ffi.os == "Windows" then
        exename = "Olympus.Sharp.exe"

    elseif ffi.os == "Linux" then
        if ffi.arch == "x86" then
            -- Note: MonoKickstart no longer ships with x86 prebuilts.
            exename = "Olympus.Sharp.bin.x86"
        elseif ffi.arch == "x64" then
            exename = "Olympus.Sharp.bin.x86_64"
        end

    elseif ffi.os == "OSX" then
        exename = "Olympus.Sharp.bin.osx"
    end

    local exe = fs.joinpath(cwd, exename)

    local logpath = os.getenv("OLYMPUS_SHARP_LOGPATH") or nil
    if logpath and #logpath == 0 then
        logpath = nil
    end

    if not logpath and not debugging then
        logpath = fs.joinpath(fs.getStorageDir(), "log-sharp.txt")
        fs.mkdir(fs.dirname(logpath))
    end

    if debugging then
        print("[sharp init]", "starting subprocess", exe, pid, debuggingSharp and "--debug" or nil)
        print("[sharp init]", "logging to", logpath)
    end

    local process = assert(subprocess.popen({
        exe,
        pid,

        debuggingSharp and "--debug" or nil,

        stdin = subprocess.PIPE,
        stdout = subprocess.PIPE,
        stderr = logpath,
        cwd = cwd
    }))
    local stdout = process.stdout
    local stdin = process.stdin

    local read, write, flush

    read = function()
        return assert(stdout:read("*l"))
    end

    write = function(data)
        return assert(stdin:write(data))
    end

    flush = function()
        return assert(stdin:flush())
    end

    local function readBlob()
        return {
            uid = utils.fromJSON(read()),
            value = utils.fromJSON(read()),
            status = utils.fromJSON(read())
        }
    end

    local function checkTimeoutFilter(err)
        if type(err) == "string" and (err:match("timeout") or err:match("closed")) then
            return "timeout"
        end
        if type(err) == "userdata" or type(err) == "table" then
            return err
        end
        return debug.traceback(tostring(err), 1)
    end

    local function checkTimeout(fun, ...)
        local status, rv = xpcall(fun, checkTimeoutFilter, ...)
        if rv == "timeout" then
            return "timeout"
        end
        if not status then
            error(rv, 2)
        end
        return rv
    end

    local function run(uid, cid, argsLua)
        write(utils.toJSON(uid, { indent = false }) .. "\n")

        write(utils.toJSON(cid, { indent = false }) .. "\n")

        local argsSharp = {}
        -- Olympus.Sharp expects C# Tuples, which aren't lists.
        for i = 1, #argsLua do
            argsSharp["Item" .. i] = argsLua[i]
        end
        write(utils.toJSON(argsSharp, { indent = false }) .. "\n")

        flush()

        local data = readBlob()
        assert(uid == data.uid)
        return data
    end

    local uid = "?"

    local function dprint(...)
        if debugging then
            print("[sharp #" .. uid .. " queue]", ...)
        end
    end

    local unpack = table.unpack or _G.unpack

    -- The child process immediately sends a status message.
    if debugging then
        print("[sharp init]", "reading init")
    end
    local initStatus = readBlob()
    if debugging then
        print("[sharp init]", "read init", initStatus)
    end

    -- The status message contains the TCP port we're actually supposed to listen to.
    -- Switch from STDIN / STDOUT to sockets.
    local port = initStatus.uid -- initStatus gets modified later
    local function connect()
        local try = 1
        ::retry::
        local clientOrStatus, clientError = socket.connect("127.0.0.1", port)
        if not clientOrStatus then
            try = try + 1
            if try >= 3 then
                error(clientError, 2)
            end
            if debugging then
                print("[sharp init]", "failed to connect, retrying in 2s", clientError)
            end
            threader.sleep(2)
            goto retry
        end
        clientOrStatus:settimeout(1)
        return clientOrStatus
    end

    local client = connect()

    read = function()
        return assert(client:receive("*l"))
    end

    write = function(data)
        return assert(client:send(data))
    end

    flush = function()
    end

    local timeoutping = {
        uid = "_timeoutping",
        cid = "echo",
        args = { "timeout ping" }
    }

    while true do
        if debugging then
            print("[sharp queue]", "awaiting next cmd")
        end
        local cmd = channelQueue:demand(0.4)
        if not cmd then
            if debugging then
                print("[sharp queue]", "timeoutping")
            end
            cmd = timeoutping
        end
        uid = cmd.uid
        local cid = cmd.cid
        local args = cmd.args

        if cid == "_init" then
            dprint("returning init", initStatus)
            initStatus.uid = uid
            channelReturn:push(initStatus)

        elseif cid == "_die" then
            dprint("dying")
            channelReturn:push({ value = "ok" })
            break

        else
            ::rerun::
            dprint("running", cid, unpack(args))
            local rv = checkTimeout(run, uid, cid, args)
            if rv == "timeout" then
                dprint("timeout reconnecting", rv.value, rv.status, rv.status and rv.status.error)
                client:close()
                client = connect()
                goto rerun
            end
            if uid == "_timeoutping" then
                dprint("timeoutping returning", rv.value, rv.status, rv.status and rv.status.error)
            else
                dprint("returning", rv.value, rv.status, rv.status and rv.status.error)
                channelReturn:push(rv)
            end
        end
    end

    client:close()
end


local mtSharp = {}

-- Automatically generate helpers for all function calls.
function mtSharp:__index(key)
    local rv = rawget(self, key)
    if rv ~= nil then
        return rv
    end

    rv = function(...)
        return self.run(key, ...)
    end
    self[key] = rv
    return rv
end


local sharp = setmetatable({}, mtSharp)

local function _run(cid, ...)
    local debugging = channelDebug:peek()[1]
    local uid = string.format("(%s)#%d", require("threader").id, tuid)
    tuid = tuid + 1

    local function dprint(...)
        if debugging then
            print("[sharp #" .. uid .. " run]", ...)
        end
    end

    dprint("enqueuing", cid, ...)
    channelQueue:push({ uid = uid, cid = cid, args = {...} })

    dprint("awaiting return value")
    ::reget::
    local rv = channelReturn:demand()
    if rv.uid ~= uid then
        channelReturn:push(rv)
        goto reget
    end

    dprint("got", rv.value, rv.status, rv.status and rv.status.error)

    if type(rv.status) == "table" and rv.status.error then
        error(string.format("Failed running %s %s: %s", uid, cid, tostring(rv.status.error)))
    end

    assert(uid == rv.uid)
    return rv.value
end
function sharp.run(id, ...)
    return threader.run(_run, id, ...)
end

sharp.initStatus = false
function sharp.init(debug, debugSharp)
    if sharp.initStatus then
        return sharp.initStatus
    end

    channelDebug:pop()
    channelDebug:push({ debug and true or false, debugSharp and true or false })

    -- Run the command queue on a separate thread.
    local thread = threader.new(sharpthread)
    sharp.thread = thread
    thread:start()

    -- The child process immediately sends a status message.
    sharp.initStatus = sharp.run("_init"):result()

    return sharp.initStatus
end

return sharp