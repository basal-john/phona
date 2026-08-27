-- phona. Hold Option to dictate, release to insert grammar-corrected text.
--
-- Option is observed, never remapped, so Option+click, Option+e and every other Option
-- shortcut keep working. A hold only counts once Option has been down alone for
-- HOLD_DELAY seconds with no other key pressed.
--
-- The HUD follows Apple's fluid-interface rules. Motion is driven by springs rather than
-- fixed-duration curves, so every state change starts from the value currently on screen
-- and can be interrupted at any frame. Enter and exit travel the same path. The waveform
-- shows the real microphone level rather than a decorative loop, so the feedback is
-- continuous during the interaction instead of only at the end.

require("hs.ipc")

local HOME = os.getenv("HOME")
local BASE = HOME .. "/.local/share/phona"
local PYTHON = BASE .. "/venv/bin/python"
local CLIENT = BASE .. "/client.py"
local RECORDING = BASE .. "/recording.wav"

local HOLD_DELAY = 0.25
local FPS = 1 / 60

-- Geometry. Every value here is deliberate rather than eyeballed: the pill is a capsule
-- (radius is exactly half the height), the bars are a 4pt stem on a 7pt rhythm, and the
-- canvas is oversized so a spring can overshoot without being clipped.
local PILL_W, PILL_H = 124, 40
local BAR_COUNT, BAR_W, BAR_GAP = 5, 4, 7
local BAR_MIN, BAR_MAX = 4, 22
local CANVAS_W, CANVAS_H = 260, 120
local BOTTOM_MARGIN = 120

-- Apple's two spring parameters, damping ratio and response, rather than mass, stiffness
-- and damping. Critically damped by default: overshoot on something that merely appeared
-- reads as noise. See the quick reference in the apple-design notes.
local SPRING_UI = {damping = 1.0, response = 0.34}
local SPRING_BAR = {damping = 0.72, response = 0.16}

-- Accessibility. Reduced motion swaps springs for a plain cross fade, reduced
-- transparency makes the surface solid. Both are read once at load.
local function defaultsFlag(key)
    local out = hs.execute("defaults read com.apple.universalaccess " .. key .. " 2>/dev/null")
    return (out or ""):gsub("%s+", "") == "1"
end

local reduceMotion = defaultsFlag("reduceMotion")
local reduceTransparency = defaultsFlag("reduceTransparency")

-- ---------------------------------------------------------------------------
-- Spring
-- ---------------------------------------------------------------------------

local Spring = {}
Spring.__index = Spring

function Spring.new(value, cfg)
    return setmetatable({
        x = value, v = 0, target = value,
        damping = cfg.damping, response = cfg.response,
    }, Spring)
end

function Spring:setTarget(t)
    self.target = t
end

-- Snap without motion, used to seed a fresh presentation and for reduced motion.
function Spring:reset(value)
    self.x, self.v, self.target = value, 0, value
end

function Spring:step(dt)
    if reduceMotion then
        self.x = self.target
        return self.x
    end
    local omega = 2 * math.pi / self.response
    local accel = -omega * omega * (self.x - self.target) - 2 * self.damping * omega * self.v
    self.v = self.v + accel * dt
    self.x = self.x + self.v * dt
    return self.x
end

function Spring:settled(epsilon)
    epsilon = epsilon or 0.001
    return math.abs(self.x - self.target) < epsilon and math.abs(self.v) < epsilon
end

-- ---------------------------------------------------------------------------
-- Microphone level
-- ---------------------------------------------------------------------------

-- Read the tail of the wav ffmpeg is still writing and return a 0..1 loudness. The file
-- is 16 kHz mono signed 16 bit, so the last 3200 bytes are the most recent 100 ms.
local WINDOW_BYTES = 3200
local FLOOR_DB, CEIL_DB = -52, -12

local function micLevel()
    local file = io.open(RECORDING, "rb")
    if not file then return 0 end
    local size = file:seek("end")
    if size < 44 + WINDOW_BYTES then
        file:close()
        return 0
    end
    file:seek("set", size - WINDOW_BYTES)
    local data = file:read(WINDOW_BYTES)
    file:close()
    if not data or #data < 2 then return 0 end

    local sum, count = 0, 0
    -- Every 4th sample is plenty for a level meter and keeps this off the hot path.
    for i = 1, #data - 1, 8 do
        local sample = string.unpack("<i2", data, i)
        sum = sum + sample * sample
        count = count + 1
    end
    if count == 0 then return 0 end

    local rms = math.sqrt(sum / count) / 32768
    if rms <= 0 then return 0 end
    local db = 20 * math.log(rms, 10)
    local level = (db - FLOOR_DB) / (CEIL_DB - FLOOR_DB)
    return math.max(0, math.min(1, level))
end

-- ---------------------------------------------------------------------------
-- HUD
-- ---------------------------------------------------------------------------

-- Global rather than local so the state can be inspected and driven from `hs -c`.
hud = {
    canvas = nil,
    timer = nil,
    state = "hidden",
    bars = {},
    presence = nil,   -- 0 hidden, 1 shown. Drives lift, scale and opacity together.
    check = nil,
    holdUntil = 0,
}

local function activeScreen()
    -- Put the HUD where the user actually is. With several displays, the main screen is
    -- often not the one being worked on.
    local win = hs.window.focusedWindow()
    if win and win:screen() then return win:screen() end
    return hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
end

local function buildCanvas()
    local canvas = hs.canvas.new({x = 0, y = 0, w = CANVAS_W, h = CANVAS_H})
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:clickActivating(false)

    canvas:appendElements({
        type = "rectangle",
        action = "fill",
        roundedRectRadii = {xRadius = PILL_H / 2, yRadius = PILL_H / 2},
        fillColor = {red = 0.07, green = 0.07, blue = 0.08,
                     alpha = reduceTransparency and 0.98 or 0.82},
        frame = {x = 0, y = 0, w = PILL_W, h = PILL_H},
    })

    -- A brighter hairline along the edge. On a real material this is light catching the
    -- top of the surface, and it is what stops a dark panel reading as a flat hole.
    canvas:appendElements({
        type = "rectangle",
        action = "stroke",
        strokeWidth = 1,
        roundedRectRadii = {xRadius = PILL_H / 2, yRadius = PILL_H / 2},
        strokeColor = {white = 1, alpha = reduceTransparency and 0.10 or 0.16},
        frame = {x = 0, y = 0, w = PILL_W, h = PILL_H},
    })

    for _ = 1, BAR_COUNT do
        canvas:appendElements({
            type = "rectangle",
            action = "fill",
            roundedRectRadii = {xRadius = BAR_W / 2, yRadius = BAR_W / 2},
            fillColor = {white = 1, alpha = 0.92},
            frame = {x = 0, y = 0, w = BAR_W, h = BAR_MIN},
        })
    end

    canvas:appendElements({
        type = "segments",
        action = "stroke",
        strokeWidth = 2.5,
        strokeColor = {red = 0.20, green = 0.84, blue = 0.45, alpha = 1},
        strokeCapStyle = "round",
        strokeJoinStyle = "round",
        coordinates = {{x = 0, y = 0}, {x = 0, y = 0}, {x = 0, y = 0}},
    })

    return canvas
end

local function render()
    local canvas = hud.canvas
    if not canvas then return end

    local presence = hud.presence.x
    -- One value drives lift, scale and opacity, so the pill arrives as a single object
    -- rather than three properties finishing at slightly different times.
    local scale = reduceMotion and 1 or (0.94 + 0.06 * presence)
    local lift = reduceMotion and 0 or (14 * (1 - presence))

    local cx, cy = CANVAS_W / 2, CANVAS_H / 2 + lift
    local w, h = PILL_W * scale, PILL_H * scale

    -- Each element gets its own freshly built table. A frame read back off a canvas
    -- element cannot be assigned to another element, and reusing one table for two
    -- elements is not safe either.
    local px, py = cx - w / 2, cy - h / 2
    canvas[1].frame = {x = px, y = py, w = w, h = h}
    canvas[1].roundedRectRadii = {xRadius = h / 2, yRadius = h / 2}
    canvas[2].frame = {x = px, y = py, w = w, h = h}
    canvas[2].roundedRectRadii = {xRadius = h / 2, yRadius = h / 2}

    local span = BAR_COUNT * BAR_W + (BAR_COUNT - 1) * BAR_GAP
    local startX = cx - (span * scale) / 2

    for i = 1, BAR_COUNT do
        local bar = hud.bars[i]
        -- No floor here. The listening targets already keep a minimum, and clamping at
        -- render time would leave five dots stranded behind the success checkmark.
        local barH = math.max(0, bar.x) * scale
        local barW = BAR_W * scale
        local x = startX + (i - 1) * (BAR_W + BAR_GAP) * scale
        canvas[2 + i].frame = {x = x, y = cy - barH / 2, w = barW, h = barH}
        canvas[2 + i].roundedRectRadii = {xRadius = barW / 2, yRadius = barW / 2}
        canvas[2 + i].fillColor = {white = 1, alpha = 0.92 * presence}
    end

    local checkAlpha = hud.check.x
    local element = canvas[3 + BAR_COUNT]
    element.strokeColor = {red = 0.20, green = 0.84, blue = 0.45, alpha = checkAlpha * presence}
    local s = scale
    element.coordinates = {
        {x = cx - 8 * s, y = cy + 0 * s},
        {x = cx - 2 * s, y = cy + 6 * s},
        {x = cx + 9 * s, y = cy - 7 * s},
    }

    canvas:alpha(presence)
end

local function positionCanvas()
    local frame = activeScreen():fullFrame()
    hud.canvas:frame({
        x = frame.x + (frame.w - CANVAS_W) / 2,
        y = frame.y + frame.h - BOTTOM_MARGIN - CANVAS_H,
        w = CANVAS_W,
        h = CANVAS_H,
    })
end

-- A throw inside the render loop used to stop the frame silently halfway through, which
-- showed up as a pill with no waveform in it. Surface it instead.
local renderErrorLogged = false
local function safeRender()
    local ok, err = pcall(render)
    if not ok and not renderErrorLogged then
        renderErrorLogged = true
        print("phona hud render error: " .. tostring(err))
    end
end

local function tick()
    local dt = FPS

    if hud.state == "listening" then
        local level = micLevel()
        -- The centre bar leads, the outer bars trail. A flat profile reads as a bar
        -- chart, this reads as a voice.
        local profile = {0.55, 0.82, 1.0, 0.82, 0.55}
        for i = 1, BAR_COUNT do
            local jitter = 0.85 + 0.3 * math.abs(math.sin(hs.timer.absoluteTime() / 1e9 * (2.1 + i * 0.7)))
            local target = BAR_MIN + (BAR_MAX - BAR_MIN) * level * profile[i] * jitter
            hud.bars[i]:setTarget(math.min(BAR_MAX, target))
        end
    elseif hud.state == "processing" then
        -- Bars collapse toward a calm, even idle. Motion continues, so the interface
        -- reads as working rather than frozen, but it no longer claims to be listening.
        local t = hs.timer.absoluteTime() / 1e9
        for i = 1, BAR_COUNT do
            local phase = math.sin(t * 5.2 - i * 0.55)
            hud.bars[i]:setTarget(BAR_MIN + 3.5 + 2.5 * phase)
        end
    elseif hud.state == "done" then
        for i = 1, BAR_COUNT do
            hud.bars[i]:setTarget(0)
        end
    end

    for i = 1, BAR_COUNT do
        hud.bars[i]:step(dt)
    end
    hud.presence:step(dt)
    hud.check:step(dt)

    safeRender()

    if hud.state == "done" and hs.timer.absoluteTime() / 1e9 > hud.holdUntil then
        hud.state = "leaving"
        hud.presence:setTarget(0)
        hud.check:setTarget(0)
    end

    if hud.state == "leaving" and hud.presence.x < 0.02 then
        hud.state = "hidden"
        if hud.timer then hud.timer:stop() hud.timer = nil end
        if hud.canvas then hud.canvas:hide() end
    end
end

local function ensureRunning()
    if not hud.canvas then
        hud.canvas = buildCanvas()
        hud.presence = Spring.new(0, SPRING_UI)
        hud.check = Spring.new(0, SPRING_UI)
        for i = 1, BAR_COUNT do
            hud.bars[i] = Spring.new(BAR_MIN, SPRING_BAR)
        end
    end
    if not hud.timer then
        hud.timer = hs.timer.doEvery(FPS, tick)
    end
end

local sounds = {}
local function cue(name)
    if not sounds[name] then
        sounds[name] = hs.sound.getByFile("/System/Library/Sounds/" .. name .. ".aiff")
    end
    if sounds[name] then sounds[name]:play() end
end

function hudListening()
    ensureRunning()
    positionCanvas()
    if hud.state == "hidden" then
        hud.presence:reset(0)
        hud.check:reset(0)
        for i = 1, BAR_COUNT do hud.bars[i]:reset(BAR_MIN) end
    end
    hud.state = "listening"
    hud.check:setTarget(0)
    hud.presence:setTarget(1)
    hud.canvas:show()
    safeRender()
    cue("Tink")
end

function hudProcessing()
    if hud.state == "hidden" then return end
    ensureRunning()
    hud.state = "processing"
    cue("Pop")
end

function hudDone(success)
    if hud.state == "hidden" then return end
    ensureRunning()
    if success then
        hud.state = "done"
        hud.check:setTarget(1)
        hud.holdUntil = hs.timer.absoluteTime() / 1e9 + 0.42
        cue("Glass")
    else
        hud.state = "leaving"
        hud.presence:setTarget(0)
        cue("Basso")
    end
end

function hudAbort()
    if hud.state == "hidden" then return end
    hud.state = "leaving"
    hud.presence:setTarget(0)
    hud.check:setTarget(0)
end

-- ---------------------------------------------------------------------------
-- phona plumbing
-- ---------------------------------------------------------------------------

local function phona(...)
    local args = {CLIENT, ...}
    hs.task.new(PYTHON, nil, args):start()
end

local function phonaRead(...)
    local args = {CLIENT, ...}
    local out = hs.execute(PYTHON .. " " .. table.concat(
        hs.fnutils.imap(args, function(a) return "'" .. a .. "'" end), " "))
    return out or ""
end

local optionDown, recording, dirty = false, false, false
local startTimer = nil

-- Each hold gets an id. The result of a dictation arrives asynchronously, so without
-- this a slow result from the previous hold would land while the next hold is already
-- listening and dismiss it.
local session = 0

local function clearTimer()
    if startTimer then
        startTimer:stop()
        startTimer = nil
    end
end

local function beginHold()
    startTimer = nil
    if dirty or not optionDown or recording then return end
    recording = true
    session = session + 1
    hudListening()
    phona("start", "--quiet", "--no-sound")
end

local function endHold()
    clearTimer()
    if not recording then return end
    recording = false
    local mine = session
    hudProcessing()
    hs.task.new(PYTHON, function(code)
        -- Drop the result if another hold has started in the meantime, otherwise this
        -- would tear down a HUD that now belongs to a different dictation.
        if mine ~= session then return end
        hudDone(code == 0)
    end, {CLIENT, "stop", "--paste", "--quiet", "--no-sound"}):start()
end

local function abortHold()
    clearTimer()
    if not recording then return end
    recording = false
    session = session + 1
    hudAbort()
    phona("cancel", "--no-sound")
end

flagWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    local flags = event:getFlags()
    local altAlone = flags.alt and not (flags.cmd or flags.ctrl or flags.shift or flags.fn)

    if altAlone and not optionDown then
        optionDown = true
        dirty = false
        clearTimer()
        startTimer = hs.timer.doAfter(HOLD_DELAY, beginHold)
    elseif optionDown and not flags.alt then
        optionDown = false
        endHold()
    elseif optionDown and not altAlone then
        -- Another modifier joined, so this is a real shortcut rather than a dictation
        dirty = true
        abortHold()
    end
    return false
end)
flagWatcher:start()

keyWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function()
    if optionDown then
        dirty = true
        abortHold()
    end
    return false
end)
keyWatcher:start()

-- ---------------------------------------------------------------------------
-- Menu bar
-- ---------------------------------------------------------------------------

local function truncate(text, width)
    text = (text or ""):gsub("%s+", " ")
    if #text <= width then return text end
    return text:sub(1, width - 1) .. "…"
end

function buildMenu()
    local items = {}

    local ok, entries = pcall(function()
        return hs.json.decode(phonaRead("history", "12", "--json"))
    end)

    if ok and entries and #entries > 0 then
        table.insert(items, {title = "Recent", disabled = true})
        for i = #entries, 1, -1 do
            local e = entries[i]
            table.insert(items, {
                title = string.format("%s   %s", (e.ts or ""):sub(12, 16), truncate(e.text, 52)),
                fn = function() hs.pasteboard.setContents(e.text or "") end,
                tooltip = "heard: " .. (e.raw or ""),
            })
        end
    else
        table.insert(items, {title = "No dictations yet", disabled = true})
    end

    table.insert(items, {title = "-"})
    table.insert(items, {
        title = "Export log as markdown",
        fn = function()
            local target = HOME .. "/Downloads/phona-dictation-log.md"
            phonaRead("history", "--all", "--export", target)
            hs.execute("/usr/bin/open -R '" .. target .. "'")
        end,
    })
    table.insert(items, {
        title = "Open history file",
        fn = function() hs.execute("/usr/bin/open '" .. BASE .. "/history.jsonl'") end,
    })
    table.insert(items, {
        title = "Open settings",
        fn = function() hs.execute("/usr/bin/open -t '" .. BASE .. "/config.json'") end,
    })
    table.insert(items, {
        title = "Open README",
        fn = function() hs.execute("/usr/bin/open '" .. BASE .. "/README.md'") end,
    })

    table.insert(items, {title = "-"})
    table.insert(items, {title = "Warm microphone", fn = function() phona("warm", "--quiet") end})
    table.insert(items, {title = "Restart daemon", fn = function() phona("restart") end})
    table.insert(items, {title = "Reload phona", fn = function() hs.reload() end})

    return items
end

menubar = hs.menubar.new()
if menubar then
    -- A system template image, so the icon inherits menu bar tinting in light and dark
    -- and in the inverted state, which a literal emoji cannot do.
    local icon = hs.image.imageFromName("NSTouchBarAudioInputTemplate")
        or hs.image.imageFromName("NSAudioInputTemplate")
    if icon then
        menubar:setIcon(icon:setSize({w = 18, h = 18}), true)
    else
        menubar:setTitle("phona")
    end
    menubar:setTooltip("phona, hold Option to dictate")
    menubar:setMenu(buildMenu)
end

-- Stand down while the native app is running, otherwise both would react to the same
-- Option hold and record twice. This keeps Hammerspoon as an automatic fallback for when
-- the app is not running, without either one needing to know about the other.
local function nativeAppRunning()
    local out = hs.execute("/usr/bin/pgrep -x PhonaApp 2>/dev/null")
    return out ~= nil and out:gsub("%s+", "") ~= ""
end

local yielded = false
appCheckTimer = hs.timer.doEvery(5, function()
    local native = nativeAppRunning()
    if native and not yielded then
        yielded = true
        flagWatcher:stop()
        keyWatcher:stop()
        if menubar then menubar:delete() menubar = nil end
        hs.printf("phona.app is running, Hammerspoon fallback disabled")
    elseif not native and yielded then
        yielded = false
        flagWatcher:start()
        keyWatcher:start()
        hs.printf("phona.app stopped, Hammerspoon fallback re-enabled")
    end
end)

if nativeAppRunning() then
    yielded = true
    flagWatcher:stop()
    keyWatcher:stop()
    if menubar then menubar:delete() menubar = nil end
end

-- Clear any session left behind by a reload. Reloading resets the Lua flags but cannot
-- touch the detached ffmpeg, and the release event that would have stopped it is lost,
-- so without this a recording could run on unnoticed until it hits max_seconds.
phona("cancel", "--no-sound")

-- Open the microphone once at load. The first capture after boot takes several seconds
-- to start producing audio, which silently swallowed the opening words of the first
-- dictation. Paying that cost here means the first real hold is already warm.
hs.timer.doAfter(3, function()
    phona("warm", "--quiet")
end)

hs.autoLaunch(true)
hs.hotkey.bind({"ctrl", "alt", "cmd"}, "R", function() hs.reload() end)
