local f = assert(io.open(arg[1] or "NaowhUI_SmartReminders.lua", "rb"))
local source = f:read("*a"):gsub("\r\n", "\n"); f:close()
local first = assert(source:find("local DEFAULTS = {", 1, true))
local last = assert(source:find("\nlocal function IsSpellDisabled(", first, true))
local root
local env = setmetatable({ ns = { SettingsRoot = function() return root end } }, { __index = _G })
local chunk = assert(loadstring(source:sub(first, last) .. "\nreturn TRDB"))
setfenv(chunk, env)
local TRDB = chunk()
local count = 0
local function Case(name, fn) fn(); count = count + 1; print("PASS " .. name) end
Case("a fresh profile starts with Skip When Already Covered on", function()
    root = {}
    assert(TRDB().coveredSkip == true)
end)
Case("a profile saved with the old default is switched on once", function()
    root = { tankReminder = { coveredSkip = false } }
    assert(TRDB().coveredSkip == true and root.tankReminder.coveredSkipDefaultOn == true)
end)
Case("switching it off after the flip stays off", function()
    root = { tankReminder = { coveredSkip = false, coveredSkipDefaultOn = true } }
    assert(TRDB().coveredSkip == false)
end)
Case("a pack's settings carry the marker, so an imported off stays off", function()
    root = {}
    local exported = {}
    for k in pairs(TRDB()) do exported[k] = true end
    assert(exported.coveredSkipDefaultOn, "the pack exporter walks DEFAULTS")
    root = { tankReminder = { coveredSkip = false, coveredSkipDefaultOn = true } }
    assert(TRDB().coveredSkip == false)
end)
Case("an old pack cannot switch it back off, a new one can", function()
    local path = (arg[1] or "NaowhUI_SmartReminders.lua"):gsub("%.lua$", "_Packs.lua")
    local pf = assert(io.open(path, "rb"))
    local packs = pf:read("*a"):gsub("\r\n", "\n"); pf:close()
    local a = assert(packs:find("local function ApplySettings(", 1, true))
    local b = assert(packs:find("\nend\n", a, true))
    local penv = setmetatable({ ns = { SettingDefault = function(k)
        return ({ coveredSkip = true, coveredSkipDefaultOn = true })[k]
    end } }, { __index = _G })
    local pchunk = assert(loadstring(packs:sub(a, b + 4) .. "\nreturn ApplySettings"))
    setfenv(pchunk, penv)
    local ApplySettings = pchunk()
    local tr = { coveredSkip = true, coveredSkipDefaultOn = true }
    ApplySettings(tr, { coveredSkip = false })
    assert(tr.coveredSkip == true)
    ApplySettings(tr, { coveredSkip = false, coveredSkipDefaultOn = true })
    assert(tr.coveredSkip == false)
end)
print(count .. " covered-skip default regressions passed")
