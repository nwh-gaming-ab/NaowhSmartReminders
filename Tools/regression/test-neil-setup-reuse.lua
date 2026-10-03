-- Exercises the actual page builders and widget factories. The frame model checks
-- allocation/rebinding, not WoW rendering, protected execution or keyboard input.
local root = arg[1] or "."
local function Read(suffix)
    local f = assert(io.open(root .. "/NaowhUI_SmartReminders" .. suffix .. ".lua", "rb"))
    local s = f:read("*a"):gsub("\r\n", "\n"); f:close(); return s
end
local count, methods = 0, {}
local function Object(parent)
    count = count + 1
    local o = { parent = parent, children = {}, scripts = {}, shown = true, width = 960, height = 20, level = 1 }
    if parent then parent.children[#parent.children + 1] = o end
    return setmetatable(o, { __index = methods })
end
for name in ("SetFont SetFontObject SetTextColor SetColorTexture SetTexture SetAllPoints SetPoint "
    .. "ClearAllPoints SetDrawLayer SetVertexColor SetTexelSnappingBias SetSnapToPixelGrid "
    .. "SetJustifyH SetJustifyV SetWordWrap SetAlpha EnableMouse SetAutoFocus SetTextInsets "
    .. "SetCursorPosition ClearFocus SetFrameStrata SetClampedToScreen SetSpacing"):gmatch("%S+") do
    methods[name] = function() end
end
function methods:SetScript(name, fn) self.scripts[name] = fn end
function methods:SetSize(w, h) self.width, self.height = w, h end
function methods:SetWidth(w) self.width = w end
function methods:SetHeight(h) self.height = h end
function methods:GetWidth() return self.width end
function methods:GetHeight() return self.height end
function methods:SetFrameLevel(v) self.level = v end
function methods:GetFrameLevel() return self.level end
function methods:Show() self.shown = true end
function methods:Hide()
    self.shown = false
    if self.focus and self.scripts.OnEditFocusLost then
        self.focus = false; self.scripts.OnEditFocusLost(self)
    end
    if self.scripts.OnHide then self.scripts.OnHide(self) end
    for _, child in ipairs(self.children) do child:Hide() end
end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:SetText(t) self.text = t end
function methods:GetText() return self.text end
function methods:CreateFontString() return Object(self) end
function methods:CreateTexture() return Object(self) end

local env = { STANDARD_TEXT_FONT = "font", LibStub = false,
    CreateFrame = function(_, _, parent) return Object(parent) end }
env._G = env
setmetatable(env, { __index = _G })
local function Eval(s) local f = assert(loadstring(s)); setfenv(f, env); return f() end
Eval(Read("_Core")); Eval(Read("_Widgets"))
local ns = env.NaowhUITankReminder
ns.TTSVoiceChoices = function() return { [""] = "Default" }, { "" } end
ns.WindowScalePercent = function() return 100 end
ns.UI.RefreshPage = function() end
local main = Read("")
local defaults = assert(main:find("local DEFAULTS =", 1, true))
local defaultsEnd = assert(main:find("-- Which profile tables", defaults, true))
local first = assert(main:find("function ns.BuildCoreSettings(", 1, true))
local last = assert(main:find("-- Defensive Presets tab:", first, true))
env.current = {}
env.ns = ns
env.TRDB = function() return env.current end
env.RefreshSpec = function() end
env.CombatWarningsOff = function() return false end
env.DefensiveTextColor = function() return 1, 1, 1, 1 end
env.CustomTextColor = env.DefensiveTextColor
env.previewPin = true
env.canSound = true
Eval(main:sub(defaults, defaultsEnd - 1) .. main:sub(first, last - 1))
local page = Object()
local function Build(on)
    env.current = { enabled = on, soundOn = on, voiceOn = on,
        defensiveTextColorOn = on, customTextColorOn = on }
    ns.UI.BeginReusableRows(page)
    ns.BuildSetupPage(page, -6)
end
Build(false); Build(true)
local warm = count
for i = 1, 100 do Build(i % 2 == 0) end
assert(count == warm, "Setup allocated after both layouts were warmed: " .. (count - warm))
print("PASS 100 actual Setup rebuilds create zero additional frame/texture/font objects after warmup (" .. warm .. ")")
for key, rows in pairs(page._rowCache) do
    if key:find("Warn This Many Seconds Early", 1, true) then
        for _, child in ipairs(rows[1]._rightRegion.children) do
            if child.scripts.OnEditFocusLost then child.focus = true; child.text = "4" end
        end
    end
end
Build(true)
assert(env.current.leadTime == nil, "old slider text was committed to the new profile")
print("PASS page rebinding does not commit old focused slider text")

-- A reused control must call the current profile's setter, not the original closure.
local target, old = { value = false }, { value = false }
local function ToggleCfg(t)
    return { type = "toggle", text = "Rebind test", getValue = function() return t.value end,
        setValue = function(v) t.value = v end }
end
ns.UI.BeginReusableRows(page)
local row = ns.UI.Widgets:DualRow(page, 0, ToggleCfg(old))
ns.UI.BeginReusableRows(page)
local reused = ns.UI.Widgets:DualRow(page, -50, ToggleCfg(target))
assert(row == reused)
reused._leftRegion._control.scripts.OnClick()
assert(target.value and not old.value)
print("PASS reused toggle writes current profile only")

local newValue
local function DropdownCfg(label, value)
    return { type = "dropdown", text = "Dropdown test", values = { [value] = label }, order = { value },
        getValue = function() return value end, setValue = function(v) newValue = v end }
end
ns.UI.BeginReusableRows(page)
local dd = ns.UI.Widgets:DualRow(page, 0, DropdownCfg("Old", 1))
local cfg = dd._leftRegion._cfg
local values, order = cfg.values, cfg.order
ns.UI.BeginReusableRows(page)
assert(ns.UI.Widgets:DualRow(page, 0, DropdownCfg("New", 2)) == dd)
assert(cfg.values == values and cfg.order == order)
assert(values[1] == nil and values[2] == "New" and order[1] == 2)
cfg.setValue(2); assert(newValue == 2)
print("PASS reused dropdown replaces choices while retaining callback table identities")
