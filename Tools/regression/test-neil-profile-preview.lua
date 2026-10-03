local root = arg[1] or "."
local function Read(suffix)
    local f = assert(io.open(root .. "/NaowhUI_SmartReminders" .. suffix .. ".lua", "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n"); f:close(); return s
end
local function Slice(s, a, b)
    local first = assert(s:find(a, 1, true))
    return s:sub(first, assert(s:find(b, first, true)) - 1)
end
local function Object()
    local o = { shown = false }
    function o:Show() self.shown = true end
    function o:Hide() self.shown = false end
    function o:SetShown(v) self.shown = v end
    function o:SetAlpha(v) self.alpha = v end
    for _, k in ipairs({ "EnableMouse", "SetScript", "SetMovable", "SetClampedToScreen",
        "RegisterForDrag", "SetText", "SetTexture" }) do o[k] = function() end end
    return o
end
local main, core = Read(""), Read("_Core")
local env = { ns = {}, previewing = true, activeSlots = 1, queued = {} }
setmetatable(env, { __index = _G })
local function Eval(s) local f = assert(loadstring(s)); setfenv(f, env); return f() end
env.frame, env.textFrame, env.customFrame = Object(), Object(), Object()
env.customFrame.text = Object()
local slot = Object(); slot.icon, slot.label = Object(), Object(); slot.spellID = 123
env.slots = { slot }
env.TRDB = function() return env.settings end
env.Reminder = { Create = function() end }
env.CreateCustomFrame = function() end
env.RebuildSlots = function() slot:SetAlpha(0); env.activeSlots = 1 end
env.HideReminder = function() env.frame:Hide(); env.textFrame:Hide(); env.shownForEvent = nil end
env.UpdateEventRegistration = function() env.frame:Hide(); env.textFrame:Hide() end
env.ResolveSoundFile = function() return "sound" end
env.CalloutFor = function() return "Defensive" end
for _, name in ipairs({ "RefreshSpec", "ProbeCapabilities", "ApplyPosition", "ApplySize",
    "ApplyDefensiveTextColor", "ApplyCustomTextColor", "RebuildCastMap", "ResyncModel",
    "WarnIfMuted", "RegisterEventSounds" }) do env[name] = function() end end
for _, name in ipairs({ "PruneCustomReminderTimers", "PrunePendingBWFires", "ClearEventSounds",
    "WarnIfNoBossMod" }) do env.ns[name] = function() end end
env.ns.BossSource = function() return "timeline" end
env.ns.HealerRemindersEnabled = function() return true end
env.ns.soundFile = "sound"
env.C_Timer = { After = function(_, fn) env.queued[#env.queued + 1] = fn end }
Eval(Slice(main, "function ns.Apply()", "--  Preview"))
Eval(Slice(main, "local previewPin = true", "-- The anchor-config half")
    .. "\nfunction ns.TestPreviewPin(v) previewPin = v end\n"
    .. Slice(main, "function ns.RefreshDefensivePreview()", "-- Re-seat the alert"))
Eval(core:sub((assert(core:find("local reapplyPending", 1, true)))))
local function Switch(settings)
    env.settings = settings
    env.ns.QueueReapply()
    local pending = env.queued; env.queued = {}
    for _, fn in ipairs(pending) do fn() end
end
local visible = { enabled = true, showIcon = true, soundOn = true }
local hidden = { enabled = true, showIcon = false, soundOn = true }
Switch(visible)
assert(env.frame.shown and slot.icon.shown and slot.alpha == 1, "first profile preview missing")
Switch(hidden)
assert(not slot.icon.shown, "hidden profile's icon was shown")
Switch(visible)
assert(env.frame.shown and slot.icon.shown and slot.alpha == 1, "switching back did not restore icon")
Switch({ enabled = false, showIcon = false })
Switch(visible)
assert(env.frame.shown and slot.icon.shown and slot.alpha == 1, "disabled profile stranded the preview")
print("PASS icon restores after icon-off and master-disabled profiles")
env.ns.TestPreviewPin(false)
Switch(visible); assert(not env.frame.shown, "preview toggle was ignored")
env.ns.TestPreviewPin(true); env.previewing = false
Switch(visible); assert(not env.frame.shown, "profile switch showed preview with settings closed")
print("PASS preview stays hidden when unpinned or settings are closed")
