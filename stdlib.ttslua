--[[
    Tabletop Simulator Standard Library (tts-stdlib).
    Created by Red Mushroom.
    Profile: https://steamcommunity.com/id/Red_Mush
    Github: https://github.com/raeon/tts-stdlib
    License:
        Copyright (c) 2018 Joris Klein Tijssink

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
do

    --[[
        Exports

        We want to keep track of the variables we define in the global scope so we can prevent
        'environment pollution'. This is used in particular during the evaluation of arbitrary code,
        at which point almost all global functions defined
    ]]
    local _exportKeys = {}
    local _exportVals = {}
    local _exported = true

    local function _export(name, func, always)
        if always then
            _G[name] = func
            return
        end

        _exportKeys[name] = true

        if _exported then
            _exportVals[name] = _G[name]
            _G[name] = func
        else
            _exportVals[name] = func
        end
    end

    local function _swapEnv()
        for k in pairs(_exportKeys) do
            local cur = _G[k]
            _G[k] = _exportVals[k]
            _exportVals[k] = cur
        end
        _exported = not _exported
    end

    local function _clearEnv() if not _exported then return end _swapEnv() end
    local function _applyEnv() if _exported then return end _swapEnv() end

    --[[
        Miscellaneous
    ]]

    local _assigner = 0
    local function assign()
        _assigner = _assigner + 1
        return _assigner
    end

    -- Creates an accessor method for a property.
    local function _accessor(t, k)
        return function(v)
            if v ~= nil then t[k] = v end
            return t[k]
        end
    end

    local function any(t)
        for k in pairs(t) do
            return true
        end
        return false
    end

    local function count(t)
        local c = 0
        for k in pairs(t) do
            c = c + 1
        end
        return c
    end

    local function filter(t, p)
        local r = {}
        for k, v in pairs(t) do
            if p(k, v) then
                r[k] = v
            end
        end
        return r
    end

    -- Invokes a function in this object. Typically called from invoke().
    local function __invoke(tbl)
        return { _G[tbl.func](table.unpack(tbl.args)) }
    end

    -- Invokes global function [name] on object [obj] with arguments [...].
    local function invoke(obj, name, ...)
        return table.unpack(obj.call('__invoke', { func = name, args = {...} }))
    end

    _export('assign', assign)
    _export('__invoke', __invoke, true)
    _export('invoke', invoke)
    _export('any', any)
    _export('count', count)
    _export('filter', filter)

    --[[
        Metadata
    ]]

    local _CURRENT = {
        name = 'Unnamed',
        description = '',
        version = 1,
        author = '',
        profile = '',
        license = '',
        tracing = false,
        debugging = false,
    }

    -- Generate functions in global namespace to manipulate the above table.
    for k,v in pairs(_CURRENT) do
        _export(k, _accessor(_CURRENT, k))
    end

    -- Once the accessor methods have been created, we add any immutable fields.
    -- These fields are used only internally.
    _CURRENT.stdlib = 3

    --[[
        Logging
    ]]

    local _tostring = tostring
    local tostring
    tostring = function(obj)
        if type(obj) == 'table' then
            if obj.___mock then
                return tostring(obj)
            end
            local str = '{'
            local any = false
            for k,v in pairs(obj) do
                str = str .. (any and ', ' or '') .. '"' .. tostring(k) .. '": ' .. tostring(v)
                any = true
            end
            return str .. '}'
        end
        return _tostring(obj)
    end

    local function _format(...)
        local str = '[' .. name() .. ' v' .. tostring(version()) .. '] '
        for k,v in pairs({...}) do str = str .. tostring(v) end
        return str
    end

    local function _logger(name, color, cond)
        -- Export 3 logger functions and return the 'to chat' one.
        cond = cond or function() return true end
        local chat = function(...)
            if cond() then printToAll(_format(...), color) end
        end
        local broadcast = function(...)
            if cond() then broadcastToAll(_format(...), color) end
        end
        local silent = function(player, ...)
            if cond() then printToColor(_format(...), player, color) end
        end
        _export(name, chat)
        _export(name .. 'Broadcast', broadcast)
        _export(name .. 'Silent', silent)
        return chat, broadcast, silent
    end

    local trace, traceBroadcast, traceSilent = _logger('trace', { 255, 0, 255 }, tracing)
    local debug, debugBroadcast, debugSilent = _logger('debug', { 0, 255, 255 }, debugging)
    local info, infoBroadcast, infoSilent = _logger('info', { 0, 255, 0 })
    local warn, warnBroadcast, warnSilent = _logger('warn', { 255, 255, 0 })
    local fatal, fatalBroacast, fatalSilent = _logger('fatal', { 255, 0, 0 })

    --[[
        Scheduler

        All code runs in coroutines now (except the scheduler itself!). Within the coroutine,
        several methods will yield an object. These methods are sleep(ms) and interval(ms)
        which use pollables, or await(key) and resume(key) which use callbacks.

        By default, async functions run synchronously until they are moved to the async coroutine.
        This happens when a blocking operation occurs, such as waiting for an event (e.g. await()).
        In the case of callbacks however, they run in the context in which resume(key) was invoked.
    ]]

    -- Cached yield function.
    local _yield = coroutine.yield

    -- Coroutines that are to be resumed when a condition becomes true.
    local _pollables = {}
    local _polling = false -- whether the async poller is running or not

    -- Coroutines that are to be resumed when notified.
    local _callbacks = {}

    -- Prewaiting makes sure that we don't miss the callback if the callback is invoked instantly.
    local _prewaiting = {} -- (pending keys) key => { coroutines }
    local _prewaited = {} -- (the captured values) key => (coroutine => value)

    -- Different action handlers that are invoked through coroutine yields.
    local _actions = {}

    --[[
        Scheduler: Core
    ]]

    -- The cycle function resumes the coroutine with the given arguments. The coroutine yields an
    -- instruction object (or finishes and returns nothing), which is used to determine the next
    -- action. We can either cycle again or schedule execution after a callback or pollable.
    local function _cycle(id, co, args)
        local results, success, alive, resumable, offset, command, action
        resumable = true
        while resumable do

            -- Resume the coroutine.
            results = { coroutine.resume(co, table.unpack(args or {})) }
            success = results[1]
            command = results[2]
            alive = coroutine.status(co) ~= 'dead'
            resumable = success and alive
            offset = (success and alive) and 2 or 1

            -- Truncate the lowest 'offset' items.
            for i=1,offset,1 do
                results[i] = results[i + offset]
                results[i + offset] = nil
            end

            -- Break the loop if an error occurred.
            if not success then
                fatal('coroutine #', id, ' errored: ', command)
                return
            end

            -- Also break the loop if it can no longer be resumed.
            if not resumable then
                return table.unpack(results)
            end

            -- If the coroutine has not died yet, we interpret the yielded value as an action.
            action = _actions[command.action]
            if not action then
                fatal('coroutine #', id, ' tried to invoke unknown action: ', command.action)
                return
            end

            -- Invoke the action using the arguments given. The result of an internal action
            -- handler are two values: a boolean 'resumable', and an argument list to use
            -- as input arguments on the next resume.
            resumable, args = action(id, co, table.unpack(command.args))
        end

        -- Cycle does not really return a value.
        return table.unpack(args)
    end

    local function __poller()
        local any = true
        while any and _polling do
            -- Keep polling until there are zero items to poll.
            any = false
            _async = true -- we are running async
            for pid, pa in pairs(_pollables) do
                any = true

                -- Poll this pollable. If a call function is specified, we invoke that function.
                -- Otherwise we just cycle the coroutine.
                if pa.poll() then
                    if pa.call then
                        pa.call()
                    else
                        _cycle(pa.id, pa.co)
                    end
                    _pollables[pid] = nil
                end
            end
            _async = false -- we are no longer running async
            coroutine.yield(0)
        end
        _polling = false
        return 1
    end

    local function _runPoller()
        if _polling then return end
        _polling = true
        startLuaCoroutine(self, '__poller')
    end

    -- The "lua coroutine" must be a globally defined function.
    _export('__poller', __poller, true)

    --[[
        Scheduler: Helper functions
    ]]

    local _async = false -- are we running async or not? (used in _cycle())

    local function _await(id, co, key, call)
        local cid = assign()
        _callbacks[key] = _callbacks[key] or {}
        _callbacks[key][cid] = { id = id, co = co, call = call }
        return cid
    end

    local function _pollable(id, co, poll, call)
        local pid = assign()
        _pollables[pid] = { id = id, co = co, poll = poll, call = call }
        _runPoller() -- make sure pollables actually run
        return pid
    end

    --[[
        Scheduler: Interrupting actions

        These functions all interrupt the currently running coroutine to inform the scheduler
        of something that needs to happen.
    ]]

    local function _action(name, func)
        _actions[name] = func
        _export(name, function(...)
            return _yield({ action = name, args = {...} })
        end)
    end

    _action('halt', function(id, co)
        return false, {} -- not resumable, no results
    end)

    _action('identify', function(id, co)
        return true, { id } -- resumable, returns identifier
    end)

    _action('sleep', function(id, co, ms)
        local time = os.clock() + (ms / 1000)
        _pollable(id, co, function() return os.clock() >= time end)
        return false, {} -- not resumable
    end)

    _action('await', function(id, co, key, ms)
        -- Check if any coroutine has prewaited this key.
        if _prewaited[key] then

            -- Grab any result that was cached for this coroutine.
            local result = _prewaited[key][co]
            _prewaited[key][co] = nil

            -- Forget about the key if there are none left.
            if not any(_prewaited[key]) then
                _prewaited[key] = nil
            end

            -- If there was any, return it.
            if result then
                return true, result
            end
        elseif _prewaiting[key] and _prewaiting[key][co] then
            -- If we were prewaiting this key but it hasn't been resumed yet, stop prewaiting.
            _prewaiting[key][co] = nil

            -- Forget about the key if there are none left.
            if not any(_prewaiting[key]) then
                _prewaiting[key] = nil
            end
        end

        -- Without timeout.
        if not ms then
            _await(id, co, key)
            return false, {}
        end

        -- With timeout.
        local time = os.clock() + (ms / 1000)
        local cid, pid
        -- Pollable is defined FIRST, because if we have prewaited for [act.key] and it memorized
        -- the result, then the _await would instantly yield and set _pollables[nil] = nil.
        -- Only after that would it define the pollable! We don't want that to happen.
        pid = _pollable(id, co, function() return os.clock() >= time end, function()
            -- if the timer runs out, delete the callback.
            _callbacks[key][cid] = nil

            -- then, resume the coroutine with 'false' as result.
            _cycle(id, co, { false })
        end)
        cid = _await(id, co, key, function(args)
            -- if the callback is invoked, delete the timeout.
            _pollables[pid] = nil

            -- then, resume the coroutine with 'true' and the args as the result.
            _cycle(id, co, { true, table.unpack(args) })
        end)
        return false, {} -- not resumable
    end)

    _action('cycle', function(id, co, cycles)
        local count = 0
        local req = 1 + (_async and 1 or 0) + (cycles or 0)
        _pollable(id, co, function()
            count = count + 1
            return count > req
        end)
        return false, {} -- not resumable, no results
    end)

    _action('yield', function(id, co, ...)
        -- The yield operation stopts the current execution of the current coroutine in order to
        -- let the coroutine itself control what the returned value is before it engages in any
        -- asynchronous operations (which would cause a return). It reschedules the coroutine for
        -- the next execution, all whilst returning the values the user wants to return.
        _pollable(id, co, function() return true end) -- reschedule
        return false, {...} -- return the desired return value
    end)

    --[[
        Scheduler: API
    ]]

    -- We're telling the scheduler to remember a result in case we're not awaiting it yet.
    local function prewait(key)
        _prewaiting[key] = _prewaiting[key] or {}
        _prewaiting[key][coroutine.running()] = true -- current coroutine
    end

    -- Resume callbacks that are waiting for the given key.
    local function resume(key, ...)
        local count = 0
        local args = { ... }

        -- Invoke any callbacks that are defined for this key.
        for cid, cb in pairs(_callbacks[key] or {}) do
            if cb.call then
                cb.call(args)
            else
                _cycle(cb.id, cb.co, args)
            end
            _callbacks[key][cid] = nil
            count = count + 1
        end

        -- Update the list of coroutines waiting for this key. If there are none, stop here.
        if not _prewaiting[key] then return end

        -- Move all waiting coroutines to _prewaited with the result.
        _prewaited[key] = _prewaited[key] or {}
        for co in pairs(_prewaiting[key]) do
            -- Ignore dead coroutines to prevent unnecessary memory usage.
            if coroutine.status(co) ~= 'dead' then
                _prewaited[key][co] = args
            end
        end
        _prewaiting[key] = nil
    end

    -- Wrap a function to run it asynchronously.
    local function async(func, name)
        if not func then return nil end
        return function(...)
            local id = name and (name .. assign()) or assign()
            local co = coroutine.create(func)
            -- _cycle does not actuall return a value if it gets suspended unless yield() is used
            -- before the first asynchronous operation.
            local results = { _cycle(id, co, { ... }) }
            return table.unpack(results)
        end
    end

    -- Thread starter
    local function thread(func, timestep)
        -- Schedule the thread. We use a pollable here; we
        local id = 'thread' .. assign()
        local co = coroutine.create(function()
            local continue = true
            while continue do
                local time = os.clock()

                -- Call the thread body, catching errors.
                local ok, result = pcall(func)
                if not ok then
                    fatal('thread error: ', result)
                    return
                end
                if not result then break end
                continue = result

                -- Sleep for the remainder of the time.
                sleep(timestep)
            end
        end)

        -- Schedule the thread to run ASAP. Pollables are removed once they are called,
        -- but the sleep() method will keep rescheduling the coroutine until a non-truthy value
        -- is returned by the thread body 'func'.
        _pollable(id, co, function() return true end)
    end

    _export('prewait', prewait)
    _export('__resume', resume, true) -- resume is exported twice, since it is frequently invoked
    _export('resume', resume) -- from another object during inter-object communication.
    _export('async', async)
    _export('thread', thread)

    --[[
        Desynchronization

        This part of stdlib is used to desynchronize previously synchronous functions, making them
        asynchronous instead.
    ]]

    -- Wrap a function to accept a GUID as the first argument, which will immediately yield an
    -- unique identifier once it is invoked. Once the function finishes, the return value is
    -- returned normally, but the object with the GUID is notified with the given key.
    -- NOTE that functions created using desyncFunc require desyncInvoke to work properly!
    local function desyncFunc(func)
        return async(function(guid, ...)
            local obj = getObjectFromGUID(guid)
            local uid = 'desyncInvoke' .. tostring(assign())
            local args = {...}
            yield(uid)
            cycle() -- Needed because invoker may not yet be awaiting the key.
            local results = nil
            local ok, err = pcall(function()
                results = { func(table.unpack(args)) }
            end)
            invoke(obj, '__resume', uid, ok, results)
            return ok, results or err
        end, 'desyncFunc')
    end

    -- Call function [name] on object [obj] with args [...], but inserting our own GUID as the
    -- first argument. We expect the invocation to return a key, which we then await. The remote
    -- function returns this key immediately (provided it uses desyncFunc). Once the body of the
    -- remote function finishes running, our resume() is invoked with the key and the result.
    -- When this happens, this function at last returns the result of the remote call.
    local function desyncInvoke(obj, name, ...)
        local key = invoke(obj, name, self.getGUID(), ...)
        local ok, result = await(key)
        if not ok then error(result) end -- Errors are propagated cleanly.
        return table.unpack(result)
    end

    _export('desyncFunc', desyncFunc)
    _export('desyncInvoke', desyncInvoke)

    --[[
        Mocking
    ]]

    -- Returns a function that invokes a function on the remote object.
    local function _mockFunc(name)
       return function(tbl, ...)
           -- We use a desyncInvoke since the __real... functions are all desyncFuncs.
           local results = invoke(tbl.___object, name, tbl, ...)
           local ok = results[1]

           for i, result in ipairs(results) do
               results[i] = results[i + 1]
               results[i + 1] = nil
           end

           if not ok then
               error(results[1])
           end

           return table.unpack(results)
       end
    end

    -- Metatable used for mocked values.
    local _mockMetaTable = {
        __index = _mockFunc('__realIndex'),
        __newindex = _mockFunc('__realNewIndex'),
        __call = _mockFunc('__realCall'),
        __tostring = _mockFunc('__realToString'),
        __unm = _mockFunc('__realUnm'),
        __add = _mockFunc('__realAdd'),
        __sub = _mockFunc('__realSub'),
        __mul = _mockFunc('__realMul'),
        __div = _mockFunc('__realDiv'),
        __mod = _mockFunc('__realMod'),
        __pow = _mockFunc('__realPow'),
        __concat = _mockFunc('__realConcat'),
        __eq = _mockFunc('__realEq'),
        __lt = _mockFunc('__realLt'),
        __gt = _mockFunc('__realGt'),
    }

    -- Sets the metatable for a mocked object.
    local function _remock(t)
        -- Fix the object reference.
        if not t.___object then
            local o = getObjectFromGUID(t.___guid)
            t.___object = o
            if not o then
                error('failed to resolve mocked object: ' .. t.___guid)
            end
        end

        -- Fix the metatable.
        return setmetatable(t, _mockMetaTable)
    end

    -- Wrap a variable in the given scope.
    local function mock(o, k)
        return _remock({
            ___mock = true,
            ___object = o,
            ___guid = o.getGUID(),
            ___key = k,
        })
    end

    -- Unwrap a variable in the local scope. Unwrapping only works if we are are the object to
    -- whom this value belongs, so we check if we are the owner of the value before proceeding.
    local function resolve(t)
        if type(t) ~= 'table' then return t end -- literal values
        if not t.___mock then return t end -- tables
        if t.___guid == self.getGUID() then return _G[t.___key] end -- local variables
        return _remock(t) -- remote variables
    end

    -- Helper method to quickly declare local functions with partially identical behaviour.
    local function _realFunc(func)
        -- All 'realFunc' handlers are desynchronized functions, meaning they will instantly return
        -- an unique key that the invoker will await(). Once execution finishes, the invoker will
        -- be resume()d with the result. If an error occurs, the invoker will also error.
        return function(...)
            -- Resolve all arguments in the current scope. If the mock table does not belong to
            -- our scope, then the metatable for the mock object is restored.
            local args = { ... }
            for k, v in pairs(args) do
               args[k] = resolve(v)
            end

            -- Invoke the body function with the (almost all) non-mocked arguments.
            return { pcall(func, table.unpack(args)) }
        end
    end

    _export('mock', mock)
    _export('resolve', resolve)

    -- Define all real metamethods handlers.
    _export('__realIndex', _realFunc(function(t, k) return t[k] end), true)
    _export('__realNewIndex', _realFunc(function(t, k, v) t[k] = v end), true)
    _export('__realCall', _realFunc(function(t, ...) return t(...) end), true)
    _export('__realToString', _realFunc(function(t) return _tostring(t) end), true)
    _export('__realUnm', _realFunc(function(t) return -t end), true)
    _export('__realAdd', _realFunc(function(a, b) return a + b end), true)
    _export('__realSub', _realFunc(function(a, b) return a - b end), true)
    _export('__realMul', _realFunc(function(a, b) return a * b end), true)
    _export('__realDiv', _realFunc(function(a, b) return a / b end), true)
    _export('__realMod', _realFunc(function(a, b) return a % b end), true)
    _export('__realPow', _realFunc(function(a, b) return a ^ b end), true)
    _export('__realConcat', _realFunc(function(a, b) return a .. b end), true)
    _export('__realEq', _realFunc(function(a, b) return a == b end), true)
    _export('__realLt', _realFunc(function(a, b) return a < b end), true)
    _export('__realGt', _realFunc(function(a, b) return a > b end), true)

    --[[
        Evaluation
    ]]

    -- Helper function to extract our current stdlib.
    local function _getStdlib()
        local script = self.getLuaScript()
        -- We extract stdlib from the current script by finding the last line of stdlib, which is
        -- the export of the upgrade() function. We use it as an 'anchor' to detect the end of the
        -- part of the script that contains stdlib.
        local _, last = script:find('%(\'upgrade\',%s*%w-%)%s*end')

        -- Once we found our anchor, we just grab all code until that point and use it.
        return script:sub(1, last)
    end

    -- Get or create an object to use as proxy.
    local _proxy = nil
    local function _getProxy()
        if _proxy then
            _proxy.destruct()
            _proxy = nil
        end

        -- Spawn the proxy object.
        _proxy = spawnObject({
            type = 'BlockTriangle',
            position = { 0, 220, 0 },
            scale = { 0, 0, 0 },
            sound = false,
        })
        _proxy.setLock(true)
        _proxy.interactable = false
        return _proxy
    end

    local __eval = desyncFunc(function(guid)
        -- Localise any variables and functions we need before evaluating arbitrary code.
        local pcall = _G.pcall
        local body = _G.body
        local debug = _G.debug
        local ipairs = _G.ipairs
        local setmetatable = _G.setmetatable

        -- Fetch the remote object we will use for mocking.
        local remote = getObjectFromGUID(guid)
        if not remote then
            debug('__eval: no such object: ', guid)
            return nil, 'evaluating arbitrary code but original object does not exist'
        end

        -- Delete variables and functions currently defined in the global scope temporarily
        -- so that the mocked remote version is used instead.
        _clearEnv()

        -- Mock everything that is not currently defined in the environment.
        setmetatable(_G, {
            __index = function(_, k)
                -- Reference a variable in the remote environment.
                return mock(remote, k)
            end,
            __newindex = function(_, k, v)
                -- Mock the global environment table and set a key in it.
                mock(remote, '_G')[k] = v
            end,
        })

        -- Call the arbitrary code.
        local results = { pcall(body) }
        local ok = results[1] or false
        -- local ok, results = desyncInvoke(self, 'body')

        -- Truncate the 'ok' field from the results.
        for i, v in ipairs(results) do
            results[i] = results[i + 1]
        end

        -- Restore the environment.
        setmetatable(_G, nil)
        _applyEnv()

        -- On error, there is only one result: the error string.
        if not ok then
            results = results[1]
        end

        return ok, results
    end)

    -- Evaluate an arbitrary string of Lua code.
    local function eval(code)
        -- Get our proxy object.
        local proxy = _getProxy()

        -- Map the script parameters.
        local values = {
            tracing = tostring(tracing()),
            debugging = tostring(debugging()),
            code = ' ' .. code .. ' ', -- prevent syntax errors with surrounding keywords
            guid = self.getGUID(),
        }

        -- Prepare the proxy script. It requires stdlib to function. The only independent
        -- behaviour it should have is that it should destroy itself once it goes through a
        -- save-load cycle, as the Lua state will not persist. Note the {{placeholders}}.
        local script = [[
            name('Proxy for {{guid}}')
            description('Object used to evaluate arbitrary code.')
            version(1)
            tracing({{tracing}})
            debugging({{debugging}})
            function body() {{code}} end
            on('Load', function()
                if self.script_state:len() > 0 then trace('Destroying') self.destruct() return end
                local obj = getObjectFromGUID('{{guid}}')
                if not obj then self.destruct() return end
                trace('Notifying')
                invoke(obj, '__resume', 'proxy')
            end)
            on('Save', function()
                self.script_state = JSON.encode({ true })
            end)
        ]]
        -- Minified: name('Proxy for {{guid}}')description('Object used to evaluate arbitrary code.')version(1)tracing({{tracing}})debugging({{debugging}})function body(){{code}}end;on('Load',function()if self.script_state:len()>0 then trace('Destroying')self.destruct()return end;local a=getObjectFromGUID('{{guid}}')if not a then self.destruct()return end;trace('Notifying')invoke(a,'__resume','proxy')end)on('Save',function()self.script_state=JSON.encode({true})end)

        -- Replace all placeholders in the template with the actual values.
        script = script:gsub('{{(%a-)}}', function(match) return values[match] end)

        -- After the placeholders have been replaced, we can prepend stdlib.
        script = _getStdlib() .. '\n\n' .. script

        -- Load the script.
        prewait('proxy')
        proxy.setLuaScript(script)

        -- Make sure the script has loaded correctly.
        local ok = await('proxy', 200)
        if not ok then
            proxy.destruct()
            _proxy = nil
            return false, 'syntax error'
        end

        cycle()

        -- Evaluate the code!
        local ok, results = desyncInvoke(proxy, '__eval', self.getGUID())

        -- Make sure all variables are as resolved as possible.
        if type(results) == 'table' then
            for i, result in ipairs(results) do
                results[i] = resolve(results[i])
            end
        end
        return ok, results
    end

    _export('__eval', __eval)
    _export('eval', eval)

    --[[
        Events: Core
    ]]

    local _eventListeners = {}

    local function fire(event, ...)
        local funcs = _eventListeners[event] or {}
        local result = nil
        for i=1,#funcs,1 do
            local func = funcs[i]
            -- If an event handler returns a truthy value, we remove it.
            local curResult = { func(...) }
            if #curResult > 0 then
                result = result or curResult
            end
        end
        return table.unpack(result or {})
    end

    local function listen(event, func)
        local funcs = _eventListeners[event]
        if not funcs then
            -- Specify the global event listener
            _G[event] = function(...)
                -- The global event listener literally just calls the 'fire event' function.
                return fire(event, ...)
            end

            -- Create the list of event listeners
            funcs = {}
            _eventListeners[event] = funcs
        end

        -- Async-ify the event handler and add it to the listeners.
        table.insert(funcs, async(func, event))
    end

    local function on(event, func)
        listen('on' .. event, func)
    end

    _export('fire', fire)
    _export('listen', listen)
    _export('on', on)

    --[[
        Events extension: onStackDisband
    ]]

    local _stackDisband = {}

    on('ObjectLeaveContainer', function(stack, obj)
        -- Determine if we're dealing with a stack or a deck (there's a difference!).
        if stack.getQuantity() == 0 then
            -- A deck is being disbanded.
            _stackDisband.type = 'deck'
            _stackDisband.stack = stack.getGUID()

            -- For decks, this event is fired twice. Once for the bottom card,
            -- and once for the top card, IN THAT ORDER.
            _stackDisband.bottom = _stackDisband.top
            _stackDisband.top = obj.getGUID()

            -- If both the bottom and top objects have spawned, we fire the event.
            if _stackDisband.bottom then
                local args = _stackDisband
                _stackDisband = {}
                fire('onStackDisband', args.stack, args.bottom, args.top)
            end
        elseif stack.getQuantity() == 1 then
            -- A stack is being disbanded.
            _stackDisband.type = 'stack'
            _stackDisband.stack = stack.getGUID()

            -- For stacks, this event is fired once! However, we have a problem.
            -- The event is fired with both 'stack' and 'obj' having the same GUID.
            -- This isn't the end of the world though; we listen to two onObjectSpawn events.
            -- The two spawned objects are the bottom and top items repsectively.
        end
    end)

    on('ObjectSpawn', function(obj)
        if _stackDisband.type ~= 'stack' then return end
        _stackDisband.bottom = _stackDisband.top
        _stackDisband.top = obj.getGUID()

        -- If both the bottom and top objects have spawned, we fire the event.
        if _stackDisband.bottom then
            local args = _stackDisband
            _stackDisband = {}
            fire('onStackDisband', args.stack, args.bottom, args.top)
        end
    end)

    --[[
        Events extension: onStackForm
    ]]

    local _stackForm = {}

    on('ObjectSpawn', function(obj)
        if obj.getQuantity() < 2 then return end

        -- If we're dealing with a deck, check the contents.
        if obj.tag == 'Deck' then
            -- Verify that this deck contains the expected cards.
            local objs = obj.getObjects()
            if objs[1].guid ~= _stackForm.top
            or objs[2].guid ~= _stackForm.bottom then
                return
            end

            -- Fire the event.
            local args = _stackForm
            _stackForm = {}
            fire('onStackForm', obj.getGUID(), args.bottom, args.top)
            return
        end

        -- If we're not dealing with a deck, that means we're dealing with a stack.
        -- We can't check the contents of stacks, but we ARE sure that the stack GUID
        -- will match the GUID of the bottom item in the stack.
        if obj.getGUID() ~= _stackForm.bottom then return end

        -- At this point we're (pretty) sure it's our stack. Fire the event.
        local args = _stackForm
        _stackForm = {}
        fire('onStackForm', obj.getGUID(), args.bottom, args.top)
    end)

    on('ObjectDestroy', function(obj)
        _stackForm.bottom = _stackForm.top
        _stackForm.top = obj.getGUID()
    end)

    --[[
        Web requests
    ]]

    local function _webRequest(type, url, data)
        local args = { url }
        if data then table.insert(args, data) end
        table.insert(args, self)
        table.insert(args, '__resumeWeb')
        local req = await(WebRequest[type](table.unpack(args)))

        -- Return errors cleanly
        if req.is_error then
            return nil, req.error
        end

        -- Return a regular table. Otherwise we get "UnityWebRequest has already been destroyed"
        -- errors when we try to read fields after a callback.
        return {
            download_progress = req.download_progress,
            error = req.error,
            is_error = req.is_error,
            is_done = req.is_done,
            text = req.text,
            upload_progress = req.upload_progress,
            url = req.url
        }, nil
    end

    -- Callback receiver
    _export('__resumeWeb', function(req) return resume(req, req) end)

    -- API functions
    _export('webGet', function(url) return _webRequest('get', url) end)
    _export('webPost', function(url, data) return _webRequest('post', url, data) end)
    _export('webPut', function(url, data) return _webRequest('get', url, data) end)

    --[[
        API overrides
    ]]

    local _self = self

    local function _wrap(name, func)
        local orig = _G[name]
        _export(name, function(...)
            return func(orig, ...)
        end)
    end

    _wrap('spawnObject', function(func, tbl)
        local id = identify()
        tbl.callback = '__resumeSpawn'
        tbl.callback_owner = _self
        tbl.params = { id = id }
        local obj = func(tbl)
        local _, obj = await(id)
        return await(id)
    end)

    _wrap('takeObject', function(func, container, tbl)
        tbl = tbl or {}
        local id = identify()
        tbl.callback = '__resumeTake'
        tbl.callback_owner = _self
        tbl.params = { id = id }
        prewait(id) -- make sure we don't miss the event!
        container.takeObject(tbl)
        return await(id)
    end)

    -- Callbacks for the above functions.
    _export('__resumeSpawn', function(obj, args) return resume(args.id, obj) end)
    _export('__resumeTake', function(obj, args) return resume(args.id, obj) end)

    --[[
        Updater
    ]]

    local function upgrade(url)

        -- If we are the new object, we will report back our result.
        if _PREVIOUS then
            local prev = _PREVIOUS

            -- Fill any potentially missing variables (v1 => v2).
            prev.stdlib = prev.stdlib or 1
            if prev.interact == nil then prev.interact = true end

            local prevObj = getObjectFromGUID(prev.guid)
            local success = version() > prev.version

            trace('upgrade: success: ', success)

            -- Handle failure.
            if not success then
                trace('upgrade: no increase in version')

                -- v2 needs to know we failed so it can continue running its onLoad coroutine.
                if prev.stdlib == 2 then
                    -- stdlib v2 used '_invoke' instead of '__invoke'.
                    trace('upgrade: previous was stdlib v2, using _invoke instead of __invoke')
                    prevObj.call('_invoke', { func = 'resume', args = { 'upgrade', false } })
                elseif prev.stdlib >= 3 then
                    -- We use __resume since that is always available in _G.
                    invoke(prevObj, '__resume', 'upgrade', false)
                end

                -- All versions expect us to delete ourself.
                trace('upgrade: destroying self, halting')
                self.destruct()
                halt()
            end

            -- From here onward we're handling success.

            -- Notify the original that we are the new version. This will invoke halt() so it stops
            -- running it's onLoad coroutine, letting us destroy the object.
            if prev.stdlib == 2 then
                trace('upgrade: previous was stdlib v2, using _invoke instead of __invoke')
                prevObj.call('_invoke', { func = 'resume', args = { 'upgrade', true } })
            elseif prev.stdlib >= 3 then
                invoke(prevObj, '__resume', 'upgrade', true)
            end

            -- Delete the original.
            trace('upgrade: moving away original')
            prevObj.setScale({ 0, 0, 0 })
            prevObj.setPosition({ 0, -200, 0 })
            prevObj.setLock(true)
            trace('upgrade: destroying original')
            prevObj.destruct()

            -- Assume the previous objects position.
            trace('upgrade: assuming original position')
            self.setPosition(prev.position)
            self.setRotation(prev.rotation)
            self.setVelocity(prev.velocity)
            self.interactable = prev.interact
            self.setLock(prev.lock)
            return
        end

        -- If we are the old object, we first request the script.
        local req, err = webGet(url)
        if err then
            trace('upgrade: web error: ', err)
            return
        end

        -- If the script is identical we don't really need to do anything.
        if req.text == self.getLuaScript() then
            trace('upgrade: identical script')
            return
        end

        -- Fill in our information in _CURRENT.
        _CURRENT.guid = self.getGUID()
        _CURRENT.position = self.getPosition()
        _CURRENT.rotation = self.getRotation()
        _CURRENT.velocity = self.getVelocity()
        _CURRENT.lock = self.getLock()
        _CURRENT.interact = self.interactable

        -- Spawn the new object and make sure it is completely inert.
        local new = self.clone({ position = { 0, 200, 0 }})
        new.setLock(true)
        new.interactable = false
        new.setTable('_PREVIOUS', _CURRENT)

        -- Load in the new script.
        prewait('upgrade')
        new.setLuaScript(req.text)

        -- Wait for the new object to tell us it succeeded or not.
        trace('upgrade: waiting for callback')
        local onTime, success = await('upgrade', 200)

        -- If the script fails to load completely, we are responsible for cleaning up the mess.
        if not onTime then
            trace('upgrade: callback timed out')
            new.destruct()
            return
        end

        trace('upgrade: callback replied with success: ', success)

        -- If it succeeds, halt execution. (The new object deletes the old object.)
        if success then halt() end
    end

    -- WARNING: Modifying any code beyond this points warrants the modification of _getStdlib()!
    _export('upgrade', upgrade)
end
