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
        Mod metadata
    ]]
    local _CURRENT = {
        name = 'Unnamed',
        description = '',
        version = 1,
        author = '',
        profile = '',
        license = '',
        debugging = false
    }

    -- Generate functions in global namespace to manipulate the above table.
    for k,v in pairs(_CURRENT) do
        _G[k] = function(val)
            if val ~= nil then _CURRENT[k] = val end
            return _CURRENT[k]
        end
    end

    --[[
        Logging
    ]]

    local _tostring = tostring
    local function tostring(obj)
        if type(obj) == 'table' then
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

    local _prefix = nil
    function prefix(str) _prefix = str end

    local function _logger(color, cond, fn)
        return function(...)
            if cond and not cond() then return end
            local str = _prefix or ('[' .. name() .. ' v' .. tostring(version()) .. '] ')
            for k,v in pairs({...}) do str = str .. tostring(v) end
            fn(str, color)
        end
    end

    local _logLevels = {
        debug = { color = { r = 0, g = 255, b = 255 }, condition = debugging },
        info = { color = { r = 0, g = 255, b = 0 } },
        warn = { color = { r = 255, g = 255, b = 0 } },
        fatal = { color = { r = 255, g = 0, b = 0 } },
    }
    for name, level in pairs(_logLevels) do
        local cond = level.condition
        local exempt = not cond

        _G[name] = _logger(level.color, level.condition, printToAll)
        _G[name .. 'Broadcast'] = _logger(level.color, level.condition, broadcastToAll)
    end

    --[[
        Miscellaneous utilities
    ]]

    local _assigner = 0
    function assign()
        _assigner = _assigner + 1
        return _assigner
    end

    --[[
        Remote Procedure Call interface
    ]]

    -- Receiver for remote function calls. Calls function [tbl.func] with arguments [tbl.args].
    -- Used in proxy objects, among others.
    function _invoke(tbl)
        return { _G[tbl.func](table.unpack(tbl.args)) }
    end

    -- Invokes function [name] with arguments [...] on object [obj].
    function invoke(obj, name, ...)
        return obj.call('_invoke', { func = name, args = {...} })
    end

    --[[
        Scheduler

        All code runs in coroutines now (except the scheduler itself!). Within the coroutine,
        several methods will yield an object. These methods are sleep(ms) and interval(ms)
        which use pollables, or await(key) and resume(key) which use callbacks.

        By default, async functions run synchronously until they are moved to the async coroutine.
        This happens when a blocking operation occurs, such as waiting for an event (e.g. await()).
        In the case of callbacks however, they run in the context in which resume(key) was invoked.
    ]]

    -- A list of suspended coroutines.
    local _pollables = {} -- resume when condition becomes true
    local _callbacks = {} -- resume when notified
    local _prewaiting = {} -- prevent callback race-conditions

    --[[
        Scheduler: Helper functions
    ]]

    local _yield = coroutine.yield
    local _async = false -- are we running async or not? (used when using cycle())

    function prewait(key)
        _prewaiting[key] = false -- nil = nothing, false = prewaiting, otherwise = prewaited value
    end

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

    function resume(key, ...)
        local count = 0
        local args = { ... }
        debug('resume: ', key)
        for cid, cb in pairs(_callbacks[key] or {}) do
            if cb.call then
                cb.call(args)
            else
                _cycle(cb.id, cb.co, args)
            end
            count = count + 1
        end
        if count > 0 then
            _prewaiting[key] = nil
        elseif _prewaiting[key] == false then
            _prewaiting[key] = args
        end
        return count
    end

    --[[
        Scheduler: Internal actions
    ]]

    local function _actionHalt(id, co, act)
        return false, {} -- not resumable
    end
    local function _actionIdentify(id, co, act)
        return true, { id } -- resumable, returns ID
    end
    local function _actionSleep(id, co, act)
        local time = os.clock() + (act.ms / 1000)
        _pollable(id, co, function() return os.clock() >= time end)
        return false, {} -- not resumable
    end
    local function _actionAwait(id, co, act)
        -- Check for prewaiting
        local result = _prewaiting[act.key]
        _prewaiting[act.key] = nil
        if result then
            return true, result
        end

        -- Without timeout
        if not act.ms then
            _await(id, co, act.key)
            return false, {}
        end

        -- With timeout
        local time = os.clock() + (act.ms / 1000)
        local cid, pid
        -- Polable is defined FIRST, because if we have prewaited for [act.key] and it memorized
        -- the result, then the _await would instantly yield and set _pollables[nil] = nil.
        -- Only after that would it define the pollable! We don't want that to happen.
        pid = _pollable(id, co, function() return os.clock() >= time end, function()
            -- if the timer runs out, delete the callback.
            _callbacks[act.key][cid] = nil

            -- then, resume the coroutine with 'false' as result.
            _cycle(id, co, { false })
        end)
        cid = _await(id, co, act.key, function(args)
            -- if the callback is invoked, delete the timeout.
            _pollables[pid] = nil

            -- then, resume the coroutine with 'true' and the args as the result.
            _cycle(id, co, { true, args })
        end)
        debug('awaiting: ', act.key)
        return false, {} -- not resumable
    end
    local function _actionCycle(id, co, act)
        local count = 0
        local req = 1 + (_async and 1 or 0) + act.count
        _pollable(id, co, function()
            count = count + 1
            return count > req
        end)
        return false, {}
    end

    -- Mapping string => internal action.
    local _actions = {
        halt = _actionHalt,
        identify = _actionIdentify,
        sleep = _actionSleep,
        await = _actionAwait,
        resume = _actionResume,
        cycle = _actionCycle,
    }

    --[[
        Scheduler: External actions
    ]]

    function identify() return _yield({ action = 'identify' }) end
    function halt() return _yield({ action = 'halt' }) end
    function sleep(ms) return _yield({ action = 'sleep', ms = ms }) end
    function await(key, ms) return _yield({ action = 'await', key = key, ms = ms }) end
    function cycle(count) return _yield({ action = 'cycle', count = count or 1 }) end

    -- The cycle function resumes the coroutine with the given arguments. The coroutine yields an
    -- instruction object (or finishes and returns nothing), which is used to determine the next
    -- action. We can either cycle again or schedule execution after a callback or pollable.
    function _cycle(id, co, args)
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
            if not resumable then break end

            -- If the coroutine has not died yet, we interpret the yielded value as an action.
            action = _actions[command.action]
            if not action then
                fatal('coroutine #', id, ' tried to invoke unknown action: ', command.action)
                return
            end

            -- Invoke the action using the arguments given. The result of an internal action
            -- handler are two values: a boolean 'resumable', and an argument list to use
            -- as input arguments on the next resume.
            resumable, args = action(id, co, command)
        end

        -- Cycle does not really return a value.
        return table.unpack(results)
    end

    local _polling = false
    function _poller()
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
    function _runPoller()
        if _polling then return end
        _polling = true
        startLuaCoroutine(self, '_poller')
    end

    -- Async function wrapper
    function async(fn, name)
        if not fn then return nil end
        return function(...)
            local id = name and (name .. assign()) or assign()
            local co = coroutine.create(fn)
            -- _cycle does not actuall return a value if it gets suspended.
            return _cycle(id, co, { ... })
        end
    end

    -- Thread starter
    function thread(fn, timestep)
        -- Schedule the thread. We use a pollable here; we
        local id = 'thread' .. assign()
        local co = coroutine.create(function()
            local continue = true
            while continue do
                local time = os.clock()

                -- Call the thread body, catching errors.
                local ok, result = pcall(fn)
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
        -- is returned by the thread body 'fn'.
        _pollable(id, co, function() return true end)
    end

    -- Resumes are global callback handlers that resume coroutines that are blocking until the
    -- asynchronoush operation is completed. Callback arguments are used to identify which
    -- coroutine(s) to resume.
    function _resumeSpawn(obj, args) return resume(args.id, obj) end
    function _resumeDownload(req) return resume(req, req) end
    function _resumeTake(obj, args) return resume(args.id, obj) end

    --[[
        Downloading
    ]]

    local function _webRequest(type, url, data)
        local args = { url }
        if data then table.insert(args, data) end
        table.insert(args, self)
        table.insert(args, '_resumeDownload')
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

    function webGet(url) return _webRequest('get', url) end
    function webPost(url, data) return _webRequest('post', url, data) end
    function webPut(url, data) return _webRequest('put', url, data) end

    --[[
        Events
    ]]

    local _events = {
        'onChat', 'onCollisionEnter', 'onCollisionExit', 'onCollisionStay', 'onDestroy', 'onDrop',
        'onExternalMessage', 'onFixedUpdate', 'onLoad', 'onObjectDestroy', 'onObjectDrop',
        'onObjectEnterScriptingZone', 'onObjectLeaveContainer', 'onObjectLeaveScriptingZone',
        'onObjectLoopingEffect', 'onObjectPickUp', 'onObjectRandomize', 'onObjectSpawn',
        'onObjectTriggerEffect', 'onPickUp', 'onPlayerChangeColor', 'onPlayerTurnEnd',
        'onPlayerTurnStart', 'onSave', 'onScriptingButtonDown', 'onScriptingButtonUp', 'onUpdate'
    }
    local _eventListeners = {}

    function fire(event, ...)
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

    function listen(event, func)
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

    function on(event, func)
        listen('on' .. event, func)
    end

    --[[
        Custom event: onStackDisband
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
        Custom event: onStackForm
    ]]

    local _stackForm = {}

    on('ObjectSpawn', function(obj)
        if obj.getQuantity() ~= 2 then return end

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
        API Overrides
    ]]

    local _self = self
    local function wrap(name, func)
        local orig = _G[name]
        _G[name] = function(...)
            return func(orig, ...)
        end
    end

    wrap('spawnObject', function(fn, tbl)
        local id = identify()
        tbl.callback = '_resumeSpawn'
        tbl.callback_owner = _self
        tbl.params = { id = id }
        local obj = fn(tbl)
        local _, obj = await(id)
        return await(id)
    end)

    wrap('takeObject', function(fn, container, tbl)
        tbl = tbl or {}
        local id = identify()
        tbl.callback = '_resumeTake'
        tbl.callback_owner = _self
        tbl.params = { id = id }
        prewait(id) -- make sure we don't miss the event!
        container.takeObject(tbl)
        return await(id)
    end)

    --[[
        Updater
    ]]

    function upgrade(url)

        -- Handle v1 upgrades.
        if _PREVIOUS then
            debug('upgrade: detected v1, destroying prev: ', _PREVIOUS.guid)
            cycle() -- removing objects during onLoad doesn't work properly, so wait a moment.

            -- Destroy the old object.
            local prev = getObjectFromGUID(_PREVIOUS.guid)
            prev.destruct()

            -- Assume the old objects position.
            debug('ugprade: assuming v1 position')
            self.setLock(false)
            self.setPosition(_PREVIOUS.position)
            self.setRotation(_PREVIOUS.rotation)
            self.setVelocity(_PREVIOUS.velocity)
            self.setLock(_PREVIOUS.lock)
            debug('upgrade: finished')
            return true
        end

        -- Handle v2 upgrades.
        if _ORIGINAL then
            debug('upgrade: detected v2, invoking resume')
            local orig = getObjectFromGUID(_ORIGINAL)
            invoke(orig, 'resume', 'upgrade') -- resume the upgrade script
            debug('upgrade: finished')
            return true
        end

        -- To check for updates, download the script first.
        debug('upgrade: downloading new script')
        local req, err = webGet(url)
        if err then
            debug('upgrade: failed to check for updates: ', err)
            return false, err
        end

        -- Check if the script actually changed.
        if req.text == self.getLuaScript() then
            debug('upgrade: script is identical, aborting')
            return false
        end
        debug('upgrade: old length: ', string.len(self.getLuaScript()))
        debug('upgrade: new length: ', string.len(req.text))

        -- Clone ourselves somewhere we won't be seen.
        debug('upgrade: cloning self')
        local obj = self.clone({ position = { x = 0, y = 200, z = 0 } })
        obj.setLock(true) -- wouldn't want it to fall down
        obj.interactable = false -- make sure nobody selects it by accident (somehow)
        obj.setVar('_ORIGINAL', self.getGUID()) -- tell the new object who to notify

        -- Load the new script and make sure we don't miss the notification!
        debug('upgrade: awaiting callback')
        prewait('upgrade')
        obj.setLuaScript(req.text)

        -- Now, we wait for the new script to notify us. If it doesn't, we know the new script is
        -- malfunctioning, either by containing behavioural or syntax errors.
        if not await('upgrade', 200) then
            debug('upgrade: callback timed out')
            obj.destruct()
            return false, 'upgrade timed out'
        end

        -- If it works, we move ourselves out of the way.
        debug('upgrade: moving self away')
        local pos = self.getPosition()
        self.setPosition({ x = 0, y = 210, z = 0 })

        -- Move the other object to our original position.
        debug('upgrade: moving upgraded version to our original position')
        obj.setPosition(pos, false, true)
        obj.setRotation(self.getRotation())
        obj.setVelocity(self.getVelocity())
        obj.setLock(self.getLock())
        obj.interactable = self.interactable

        -- Delete ourselves and prevent any further code form being run.
        debug('upgrade: finished')
        self.destruct()
        halt()
    end

end
