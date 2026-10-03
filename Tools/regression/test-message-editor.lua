local f = assert(io.open("NaowhUI_SmartReminders_Bosses.lua", "rb"))
local s = f:read("*a"):gsub("\r\n", "\n"); f:close()
local a = assert(s:find("local TRIGGER_CHOICES =", 1, true))
local b = assert(s:find("-- Profiles tab: profile management", a, true))
local labels, buttons, boxes, rows, records = {}, {}, {}, {}, {}
local function Widget()
    local w = { value = "", height = 26, shown = true }
    setmetatable(w, { __index = function(_, k)
        if k == "GetText" then return function(self) return self.value end end
        if k == "SetText" then return function(self,v) self.value = v; labels[v] = true end end
        if k == "GetHeight" then return function(self) return self.height end end
        if k == "SetHeight" then return function(self,v) self.height = v end end
        if k == "GetStringWidth" then return function() return 90 end end
        if k == "GetStringHeight" then return function() return 14 end end
        if k == "CreateTexture" then return Widget end
        return function() end
    end })
    return w
end
local ui = { Widgets = { DualRow = function(_,parent,y,left,right)
    assert(right); rows[left.text] = left; rows[right.text] = right; return Widget(), 44
end }, RefreshPage = function() end }
local ns = { UI = ui, THEME = {},
    MakeModal = function() return Widget(),Widget() end,
    Font = Widget, Solid = Widget, Border = function() end,
    Button = function(_,name,_,_,fn) buttons[name] = fn; return Widget() end,
    CustomRemindersTable = function() return records end,
    CurrentSpec = function() return 250 end,
    ListPresets = function() return { { key = "p", name = "Mobility" } } end,
    ActivePresetKey = function() return "p" end,
    BossModCatalogueTable = function() return {} end,
    RefreshRuntime = function() end, Print = function(text) error(text) end,
}
local env = { ns = ns, GetTime = function() return 1 end,
    CreateFrame = function(kind)
        local w = Widget(); if kind == "EditBox" then boxes[#boxes+1] = w end; return w
    end }
setmetatable(env,{ __index = _G })
local chunk = assert(loadstring(s:sub(a,b-1))); setfenv(chunk,env); chunk()
ns.ShowCustomReminderEditor(3202)
assert(rows.Trigger.getValue() == "bwmsg")
assert(#rows.Trigger.order == 3 and not rows.Trigger.values.combat and not rows.Trigger.values.bwtimer)
assert(not buttons.Preview and not labels.Message and not labels["Icon Spell ID (optional)"])
assert(not rows["Text Color"] and not rows.Sound)
assert(labels["Show seconds after the message"] and rows["Preset Group"])
-- Name, linger, message key, occurrence counter, delay.
assert(#boxes == 5)
boxes[1]:SetText("Stomp mobility"); boxes[2]:SetText("6")
boxes[3]:SetText("123"); boxes[5]:SetText("2.5")
assert(rows["Healer Reminder"].getValue() == false)
rows["Healer Reminder"].setValue(true)
buttons.Save()
for _, r in pairs(records) do assert(r.healerReminder == true) end
local _,r = next(records)
assert(r.defensive and r.specID == 250 and r.preset == "p" and r.dur == 6)
assert(r.trigger.type == "bwmsg" and r.trigger.spellID == 123 and r.trigger.delay == "2.5")
assert(not r.iconSpellID and not r.color and not r.sound)
print("PASS single-page editor saves a message defensive without presentation overrides")

ns.ScrapeBosses = function() return { instances = { { mapID = 1, bosses = {
    { encounterID = 3202, abilities = {
        { spellID = 101, title = "One" }, { spellID = 102, title = "Two" },
        { spellID = 103, title = "Three" }, { spellID = 104, title = "Four" },
        { spellID = 105, title = "Five" }, { spellID = 106, title = "Six" },
    } }, { encounterID = 999, abilities = { { spellID = 999, title = "Wrong boss" } } },
} } } } end
env.BigWigsAbilities = function(_, journal)
    assert(journal == nil)
    return { { spellID = 101, title = "One" }, { spellID = 107, title = "Seven" },
        { spellID = 109, title = "Nine" }, { spellID = 110, title = "Ten" } }
end
ns.BossModCatalogueTable = function() return { [108] = { text = "Eight", mod = "DBM" },
    [101] = { text = "One", mod = "BW" } } end
local choices = ns.ReminderAbilityChoices(3202)
assert(#choices == 4)
for _, item in ipairs(choices) do assert(item.key ~= 999) end
ns.ShowCustomReminderEditor(3202)
assert(labels.One and labels.Seven and labels.Nine and labels.Ten)
assert(not labels.Eight and not labels.Six and not labels.Five and not labels.Four)
print("PASS only BigWigs abilities listed, including rows beyond the old cap")
