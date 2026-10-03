local root = arg[1] or "."
local function Fixture()
    local e = { buttons = {}, boxes = {}, controls = {}, rowToggles = {}, rawButtons = {}, scrolls = {},
        rules = {}, spec = 250 }
    local function Tab(self, name)
        for _, w in ipairs(self.rawButtons) do
            if w.title == name then return w end
        end
    end
    local function Widget(parent)
        return { parent = parent, SetPoint = function() end, SetSize = function(self, w, h) self.width = w; self.height = h end,
            SetWidth = function(self, w) self.width = w end, SetHeight = function() end,
            SetAllPoints = function() end, SetFontObject = function() end, SetAutoFocus = function() end,
            SetMaxLetters = function() end, SetJustifyH = function() end, SetWordWrap = function() end,
            SetScrollChild = function() end, ClearAllPoints = function() end, GetFrameLevel = function() return 1 end,
            GetHeight = function(self) return self.height or 0 end,
            UpdateScrollChildRect = function() end,
            SetVerticalScroll = function(self, v) self.vscroll = v end,
            HookScript = function(self, kind, fn) self.hooks = self.hooks or {}; self.hooks[kind] = fn end,
            SetText = function(self, v) self.text = v; if self.parent then self.parent.title = v end end,
            GetText = function(self) return self.text end, Hide = function() end, Show = function() end,
            SetShown = function(self, v) self.shown = v end, GetStringWidth = function() return 40 end,
            SetScript = function(self, kind, fn)
                if kind == "OnClick" then self.onClick = fn
                elseif kind == "OnEditFocusLost" then self.onCommit = fn end
            end,
            ClearFocus = function(self) if self.onCommit then self.onCommit() end end,
            SetTexture = function() end, SetTexCoord = function() end, SetTextColor = function() end,
            SetTextInsets = function() end, ClearFocus = function() end,
            Enable = function(self) self.disabled = false end,
            Disable = function(self) self.disabled = true end }
    end
    local I = {
        Spec = function() return e.spec end, Rules = function() return e.rules end,
        Refresh = function() end, ValidRule = function() return true end,
        Preview = function(r) e.preview = r end,
        Save = function(uid, r) e.saved = r; uid = uid or "i1"; e.rules[uid] = r; return true, uid end,
        Catalogue = function() return { { id = 1762, name = "Kings Rest", abilities = {
            { spellID = 123, name = "Slam", mob = "Guard" } } } } end,
    }
    local colour = { r = 1, g = 1, b = 1 }
    local ns = { Integrations = I, UI = { Widgets = {} },
        THEME = { accent = colour, muted = colour, fg = colour, panel = colour,
            bg = colour, line = colour, accentSoft = colour } }
    ns.Font = Widget; ns.Solid = Widget; ns.Border = Widget; ns.Tooltip = function() end
    ns.Button = function(_, text, _, _, callback)
        e.buttons[text] = callback; local w = Widget(); w.label = Widget(); return w
    end
    ns.ListPresets = function() return { { key = "p1", name = "Defensives" } } end
    ns.UI.RefreshPage = function() e.render() end
    ns.UI.BuildAlertSoundTables = function() return {}, { test = "Test" }, { "test" } end
    ns.UI.AppendSharedMediaSounds = function() end
    ns.UI.BuildDropdownControl = function(parent, width, _, values, order, get, set)
        if parent.title then e.controls[parent.title] = { get = get, set = set, width = width,
            values = values, order = order } end
        return Widget()
    end
    -- Keyed by the label above it, and the reminder rows in the list have no label of their
    -- own -- those toggles are collected separately rather than indexed by nil.
    ns.UI.BuildToggleControl = function(parent, _, get, set)
        if parent.title then e.controls[parent.title] = { get = get, set = set }
        else e.rowToggles[#e.rowToggles + 1] = { get = get, set = set } end
        return Widget()
    end
    local env = setmetatable({ NaowhUITankReminder = ns, GameFontHighlight = {},
        CreateFrame = function(kind, _, parent)
            local w = Widget(); w.CreateTexture = Widget
            if kind == "ScrollFrame" then e.scrolls[#e.scrolls + 1] = w end
            if kind == "EditBox" then e.boxes[parent.title] = w end
            -- The editor's own tabs are raw Buttons, not ns.Button, so they are collected
            -- here and looked up by the label that names them.
            if kind == "Button" then e.rawButtons[#e.rawButtons + 1] = w end
            return w
        end,
    }, { __index = _G })
    env._G = env
    local c = assert(loadfile(root .. "/NaowhUI_SmartReminders_IntegrationOptions.lua")); setfenv(c, env); c()
    e.tab = Tab
    -- There is no Save button any more. Committing every text box is what leaving the
    -- editor does, and every other control writes through the moment it changes.
    function e.commitAll()
        for _, box in pairs(e.boxes) do
            if box.onCommit then box.onCommit() end
        end
    end
    e.renders = 0
    function e.render()
        e.renders = e.renders + 1
        e.buttons = {}; e.boxes = {}; e.controls = {}; e.rowToggles = {}; e.rawButtons = {}
        e.scrolls = {}
        if e.page == "debuffs" then ns.BuildDebuffsPage(Widget(), 0)
        else ns.BuildIntegrationsPage(Widget(), 0) end
    end
    function e.debuffs() e.page = "debuffs"; e.render(); return e end
    e.render()
    return e
end
local function SelectTrash(e)
    e.controls.Dungeon.set(1762); e.buttons.Slam()
end
local e = Fixture(); SelectTrash(e)
assert(e.controls["Defensive preset"].width >= 260)
e.controls["Defensive preset"].set("p1")
e.controls["Healer Reminder"].set(true); e.controls["Speak callout"].set(true)
e.buttons.Test()
    assert(e.preview.display.text == "",
        "a rule with no line of its own carries none; the preset answers instead")
e.commitAll()
assert(e.saved.trigger.type == "exboss" and e.saved.trigger.spellID == 123 and e.saved.trigger.mapID == 1762)
assert(e.saved.preset == "p1" and e.saved.healerReminder and e.saved.display.tts)
assert(e.buttons.Remove, "saved rule did not stay selected")
e.commitAll(); assert(e.rules.i1 and not e.rules.i2)
e.buttons.Remove(); assert(not next(e.rules))
e = Fixture().debuffs(); e.buttons["+ Debuff Alert"]()
e.boxes["Debuff spell ID"]:SetText("456")
e.controls.When.set("Removed"); e.controls.Unit.set("party"); e.controls.Sound.set("test")
e.commitAll()
assert(e.saved.trigger.type == "auraSound" and e.saved.trigger.auraEvent == "Removed")
-- A new alert starts on the first dungeon in the list. There is no "everywhere" choice
-- to start it on, and zero would read as an instance nobody picked.
assert(e.saved.trigger.target == "party" and e.saved.trigger.mapID == 1762
    and e.saved.display.sound == "test")
assert(e.buttons.Remove and not e.saved.display.tts and not e.saved.preset)
for _, change in ipairs({ "profile", "spec" }) do
    e = Fixture(); SelectTrash(e)
    if change == "profile" then e.rules = {} else e.spec = 251 end
    e.commitAll(); assert(not e.saved)
end
e = Fixture().debuffs(); e.buttons["+ Debuff Alert"]()
e.boxes["Debuff spell ID"]:SetText("21562")
e.controls.Sound.set("voice:stoneform-ready")
e.commitAll()
assert(e.saved.display.sound == "voice:stoneform-ready" and e.saved.trigger.target == "player")
assert(e.controls.Sound.get() == "voice:stoneform-ready")
e.buttons.Test(); assert(e.preview.display.sound == "voice:stoneform-ready")
print("PASS dungeon selection, wide preset control, preview, save/reselection, remove, debuff and profile isolation")

for _, value in ipairs({ "", "invalid" }) do
    e = Fixture().debuffs(); e.buttons["+ Debuff Alert"]()
    e.boxes["Debuff spell ID"]:SetText("21562")
    e.controls.Sound.set("test"); e.commitAll()
    e.boxes["Debuff spell ID"]:SetText(value); e.commitAll()
    assert(e.saved.trigger.spellID == nil, "invalid input fell back to saved ID")
end

-- The instance is picked by name rather than typed as an id, so there is no text left to
-- get wrong, and the same control the trash page has always used does the choosing.
e = Fixture().debuffs(); e.buttons["+ Debuff Alert"]()
assert(e.controls.Dungeon, "the debuff editor picks its instance by name")
assert(e.controls.Dungeon.values[1762] == "Kings Rest", "the catalogue names them")
e.boxes["Debuff spell ID"]:SetText("21562")
e.controls.Dungeon.set(1762); e.commitAll()
assert(e.saved.trigger.mapID == 1762, "and the pick is what gets saved")

-- An alert saved for an instance the catalogue does not carry -- a raid, or a dungeon that
-- has since left it -- keeps that instance rather than being quietly moved to everywhere.
e = Fixture().debuffs()
e.rules.x1 = { name = "Odd", enabled = true,
    trigger = { type = "auraSound", spellID = 999, mapID = 424242, target = "player" },
    display = { type = "icon" } }
e.render(); e.buttons["Odd"]()
assert(e.controls.Dungeon.values[424242] == "Instance 424242")
-- One dungeon at a time, and its abilities listed directly. The dropdown above already
-- names the dungeon, so there is no header row repeating it.
e = Fixture()
assert(e.controls.Dungeon.get() == 1762, "the page opens on the first dungeon")
assert(e.buttons.Slam, "its abilities are listed")
assert(not e.buttons["-  Kings Rest"] and not e.buttons["+  Kings Rest"],
    "the dungeon name is not repeated on a row of its own")

-- Every ability carries a switch, reading off until a reminder exists behind it.
assert(#e.rowToggles == 1 and e.rowToggles[1].get() == false,
    "an unconfigured ability shows an off switch rather than none")
-- Selecting one opens its editor, and the editor agrees with the switch. It used to read
-- enabled for an ability with no rule behind it, contradicting both that switch and the
-- missing Remove button.
e.buttons.Slam()
assert(e.controls["Enabled"] and e.controls["Enabled"].get() == false,
    "the editor must not claim an ability is on when nothing is saved for it")
assert(not e.buttons["Remove"], "and there is nothing to remove yet")
e.rowToggles[1].set(true)
assert(e.saved and e.saved.trigger.spellID == 123 and e.saved.trigger.mapID == 1762,
    "turning it on writes the rule the editor would have")
assert(e.saved.display.dur == 3 and e.saved.trigger.timeleft == 5 and e.saved.enabled == true)
assert(e.saved.display.text == "" and e.saved.preset == nil,
    "the shortcut writes no line and names no preset; the spec's active one answers")
assert(e.rowToggles[1].get() == true, "and the switch now reads from that rule")
assert(e.controls["Enabled"].get() == true, "the editor follows it")
assert(e.buttons["Remove"], "and there is something to remove now")
e.rowToggles[1].set(false)
assert(e.rules.i1.enabled == false, "turning it off disables the rule rather than deleting it")

-- The custom text field is gone: a preset writes the line, and a rule with a blank one
-- is answered by whichever preset the spec has active. Nothing in the editor edits it.
e = Fixture(); SelectTrash(e)
assert(e.boxes["Custom text"] == nil, "the field should not be built at all")
e.controls["Defensive preset"].set("p1")
e.commitAll()
assert(e.saved.preset == "p1")
assert(e.saved.display.text == "", "the saved line stays blank, which is what asks for the preset")

-- Debuff sounds belong to their own tab: they answer to an aura rather than a dungeon, and
-- used to sit in a bucket at the bottom of the trash list with no dungeon to file them under.
e = Fixture().debuffs()
assert(e.buttons["+ Debuff Alert"], "the add button moved to this page")
e.buttons["+ Debuff Alert"]()
e.boxes["Debuff spell ID"]:SetText("456"); e.controls.Sound.set("test")
e.commitAll()
assert(e.saved.trigger.type == "auraSound")
assert(#e.rowToggles == 1, "the saved sound is listed here with its switch")
assert(e.buttons.Remove, "and stays selected on this page after saving")
e.page = nil; e.render()
assert(not e.buttons["+ Debuff Alert"], "the trash page no longer offers debuff sounds")
assert(not e.buttons["Debuff alert"], "and does not list them")
-- One row, for the one catalogue ability, and its switch reads off: the aura rule is not
-- an ability in this dungeon and must not claim a row here.
assert(#e.rowToggles == 1 and e.rowToggles[1].get() == false)

-- One panel, two columns, no tabs. Every control is built and reachable at once, which is
-- also why the tab bugs are gone: there is no hidden group to lose an unsaved edit in and
-- no remembered tab to outlive the rule it was chosen on.
e = Fixture(); SelectTrash(e)
assert(e.boxes["Reminder name"] and e.boxes["Display duration (1-15 seconds)"],
    "the display controls are built")
assert(e.controls["Defensive preset"] and e.controls.Sound and e.controls["Speak callout"],
    "so are the cast and voice ones, without a click")
assert(not e:tab("Cast") and not e:tab("Voice") and not e:tab("Text & Test"),
    "and there are no tabs left to click")

-- The FIRST change creates the rule, so the page rebuilds once to list it and give it a
-- Remove button. Every change after that updates in place, or a rebuild would fight the
-- keyboard while typing.
e.controls["Speak callout"].set(true)
assert(e.rules.i1, "the first change wrote the rule")
local renders = e.renders
e.controls["Defensive preset"].set("p1")
e.boxes["Reminder name"]:SetText("Typed")
assert(e.renders == renders, "a later change must not rebuild the page")
assert(e.boxes["Reminder name"]:GetText() == "Typed")

-- Test and Remove sit above both columns and act on the whole rule.
e.commitAll()
assert(e.buttons.Test and e.buttons.Remove)


e = Fixture().debuffs(); e.buttons["+ Debuff Alert"]()
-- An alert being authored from scratch has no row to agree with, and asking for one is
-- asking for it to work, so this one does still start on.
assert(e.controls["Enabled"].get() == true, "a new alert starts enabled")


-- The list is not the whole world: it comes from ExBoss and holds dungeons it has trash
-- data for, so without that addon it is empty and a raid is never in it. "Another
-- instance" has to stay reachable or an alert could be scoped to nothing at all.
e = Fixture().debuffs(); e.buttons["+ Debuff Alert"]()
assert(e.controls["Dungeon"].values.other == "Another instance (by ID)")
assert(e.controls["Dungeon"].values[0] == nil,
    "a debuff alert names the instance it belongs to; there is no everywhere choice")
assert(not e.boxes["Instance ID (0 = every dungeon or raid)"], "hidden until asked for")

-- Saved first, deliberately. The very first save creates the rule and rebuilds the page,
-- and that rebuild resets the editor back to the list -- so a sequence that switches to
-- the id field before the rule exists never reaches the transition below at all.
e.boxes["Debuff spell ID"]:SetText("21562"); e.controls.Sound.set("test"); e.commitAll()
e.controls["Dungeon"].set("other")
local idBox = e.boxes["Instance ID (0 = every dungeon or raid)"]
assert(idBox, "picking it brings the field back")
idBox:SetText("2657"); e.commitAll()
assert(e.saved.trigger.mapID == 2657, "and the typed id is what gets saved")

-- Picking a dungeon by name puts the list back in charge. Asserted on the pick itself,
-- which saves on its own and has to beat the id still sitting in the box it is about to
-- remove: Value() prefers a box whenever one exists, and the box outlives the pick by one
-- rebuild, so this saved the id last typed rather than the dungeon just chosen.
e.controls["Dungeon"].set(1762)
assert(e.saved.trigger.mapID == 1762, "the pick wins, not the id left in the box")
assert(not e.boxes["Instance ID (0 = every dungeon or raid)"], "and the field goes away")

-- An ordinary pick does not rebuild the page. The dropdown repaints its own label, and a
-- rebuild throws away whatever is typed into an alert too incomplete to have saved yet.
-- Done on an alert that already exists: the very first save creates the rule and redraws
-- for its Remove button, which is a different rebuild with its own reason.
e = Fixture().debuffs(); e.buttons["+ Debuff Alert"]()
e.boxes["Debuff spell ID"]:SetText("21562"); e.controls.Sound.set("test"); e.commitAll()
local renders = e.renders
e.controls["Dungeon"].set(1762)
assert(e.renders == renders, "nothing appeared or disappeared, so nothing to redraw")

-- Only the field coming or going costs a rebuild.
e.controls["Dungeon"].set("other")
assert(e.renders > renders, "the id field has to be drawn")
-- The Every dungeon entry is the bucket for a saved rule no dungeon in the catalogue
-- accounts for. It is offered only when something is actually in it, so the dropdown does
-- not carry an entry that opens an empty list.
e = Fixture()
assert(e.controls["Dungeon"], "the dungeon dropdown is built")
assert(e.controls["Dungeon"].values.saved == nil,
    "nothing is loose, so there is no Every dungeon to pick")
e.rules["loose1"] = { name = "Loose", enabled = true,
    trigger = { type = "exboss", spellID = 999, mapID = 0 }, display = { type = "icon" } }
e.render()
assert(e.controls["Dungeon"].values.saved == "Every dungeon",
    "a rule no dungeon claims has to stay reachable")

-- Debuff alerts are grouped by the instance they are set for, and a group folds away
-- without letting go of whatever is selected inside it.
e = Fixture()
for i = 1, 4 do
    e.rules["b" .. i] = { name = "Alert " .. i, enabled = true,
        trigger = { type = "auraSound", spellID = 200 + i,
            mapID = (i <= 2) and 1762 or 0 },
        display = { type = "icon" } }
end
e.debuffs()
assert(#e.rowToggles == 4, "every alert is listed under the instance it names")
assert(e.buttons["-  Kings Rest  (2)"], "the catalogue names the group")
assert(e.buttons["-  Every dungeon or raid  (2)"], "and one set everywhere is its own")

e.buttons["Alert 1"]()
assert(e.buttons["Remove"], "picking an alert opens its editor")
e.buttons["-  Kings Rest  (2)"]()
assert(#e.rowToggles == 2, "a folded group stops drawing its rows")
assert(e.buttons["+  Kings Rest  (2)"], "and says it is folded")
assert(e.buttons["Remove"],
    "folding the group is not deselecting what is inside it")
e.buttons["+  Kings Rest  (2)"]()
assert(#e.rowToggles == 4, "and it comes back")

-- Picking a rule rebuilds the page, and the list is rebuilt onto a new scroll frame with
-- it. Without the offset being carried across, choosing anything below the fold sent the
-- list back to the top, which is where you were not.
e = Fixture()
for i = 1, 30 do
    e.rules["a" .. i] = { name = "Alert " .. i, enabled = true,
        trigger = { type = "auraSound", spellID = 100 + i, target = "me" },
        display = { type = "icon" } }
end
e.debuffs()
local list = e.scrolls[#e.scrolls]
assert(list.hooks and list.hooks.OnVerticalScroll, "the list has to report its own offset")
list.hooks.OnVerticalScroll(list, 120)
e.render()
assert(e.scrolls[#e.scrolls].vscroll == 120,
    "got " .. tostring(e.scrolls[#e.scrolls].vscroll))

-- Clamped to what the rebuilt list can actually show: deleting most of the rules while
-- scrolled to the bottom must not leave it parked past the end.
for i = 4, 30 do e.rules["a" .. i] = nil end
e.render()
assert(e.scrolls[#e.scrolls].vscroll == 0,
    "a list shorter than its frame has nowhere to scroll to")

print("PASS edited invalid IDs reach validation instead of falling back")
