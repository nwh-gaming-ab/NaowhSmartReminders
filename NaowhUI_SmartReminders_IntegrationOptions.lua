local ns = _G.NaowhUITankReminder
local I, UI = ns.Integrations, ns.UI
local selection = { dungeon = "all" }
-- The two list pages keep their own selection: picking a debuff sound must not decide what
-- the trash page is showing when you come back to it.
local debuffSelection = {}
-- Whether the debuff editor is showing the raw Instance ID field instead of the dungeon
-- list. Page state, not saved: it is how you are editing right now, not part of the rule.
local debuffByID = false

-- The page is sized to the options window so it never scrolls: the ability list keeps its
-- own scrollbar and nothing else needs one. The editor fits by putting its three groups of
-- settings behind tabs rather than stacking them, the same shape the boss reminder editor
-- already uses. PANEL_H is what is left once the heading block is drawn.
local PANEL_H, BODY_H = 424, 336
local function Label(parent, text, x, y, width, size, color)
    local label = ns.Font(parent, size or 12, nil, color or ns.THEME.muted)
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetWidth(width)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    return label
end
local function Panel(parent, title, x, y, width, height)
    local p = CreateFrame("Frame", nil, parent)
    p:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    p:SetSize(width, height)
    ns.Solid(p, "BACKGROUND", ns.THEME.panel, 1):SetAllPoints()
    ns.Border(p)
    Label(p, title, 14, -12, width - 28, 14, ns.THEME.accent)
    return p
end
local function Box(parent, title, value, y, width)
    local label = Label(parent, title, 14, y, width)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetFontObject(GameFontHighlight)
    box:SetAutoFocus(false)
    box:SetMaxLetters(200)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y - 20)
    box:SetSize(width, 24)
    ns.Solid(box, "BACKGROUND", ns.THEME.bg, 1):SetAllPoints()
    ns.Border(box)
    -- Without an inset the caret and the first character sit on the border itself.
    box:SetTextInsets(7, 7, 0, 0)
    box:SetText(tostring(value or ""))
    return box, label
end
local function Dropdown(parent, title, values, order, get, set, y, width)
    Label(parent, title, 14, y, width)
    local dd = UI.BuildDropdownControl(parent, width, parent:GetFrameLevel() + 2, values, order, get, set)
    dd:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y - 20)
    return dd
end
local function Toggle(parent, title, get, set, y, width)
    Label(parent, title, 14, y - 4, width - 54)
    local toggle = UI.BuildToggleControl(parent, parent:GetFrameLevel() + 2, get, set)
    toggle:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y)
end

-- Picking a row IS a refresh, and a refresh rebuilds the page from scratch onto a brand
-- new scroll frame, so these lists jumped back to the top whenever you chose or switched
-- on a rule near the bottom of one. The offset outlives the frame here and goes back on
-- once the rows are in, which is the first moment there is a range to clamp it against.
--
-- Clamped by hand rather than left to SetVerticalScroll: the frame's own range is not
-- recomputed until it next draws, and an offset past it would land at the top -- which is
-- the very thing being fixed.
local listScroll = {}
local function KeepListScroll(scroll, key, contentHeight)
    scroll:HookScript("OnVerticalScroll", function(_, offset) listScroll[key] = offset end)
    local want = listScroll[key]
    if not want or want <= 0 then return end
    scroll:UpdateScrollChildRect()
    scroll:SetVerticalScroll(math.min(want, math.max(0, contentHeight - scroll:GetHeight())))
end
local function Editor(parent, uid, kind, ability, dungeon)
    local editedRules, editedSpec = I.Rules(true), I.Spec()
    -- Every control writes straight through, so there is no Save button to forget. Declared
    -- up here because the controls are built before Value() exists to read them; the
    -- closures capture this local and see it once it is assigned below.
    local AutoSave
    -- Text boxes commit when you leave them rather than on every keystroke: saving halfway
    -- through typing a spell id would be saving a different spell.
    local function Commit(box)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEditFocusLost", function() AutoSave() end)
        return box
    end
    local old = uid and editedRules[uid]
    kind = old and old.trigger.type or kind
    local t, d = old and old.trigger or {}, old and old.display or {}
    local spellID = t.spellID or (ability and ability.spellID)
    local mapID = t.mapID or (dungeon and dungeon.id) or 0
    local mapChoice = mapID
    Label(parent, old and old.name or (ability and ability.name) or "New Debuff Sound",
        0, 0, 420, 16, ns.THEME.fg)
    Label(parent, ability and (ability.mob .. "  |  Spell " .. spellID)
        or "Rules belong to the current profile and specialization.", 0, -20, 420)
    -- Two columns, no tabs. Once the custom text field went, neither half was big enough to
    -- be worth hiding behind a click, and the tabs were where the last two bugs came from:
    -- switching one discarded unsaved edits, and the chosen tab outlived the rule it was
    -- chosen on. Nothing to switch, neither bug.
    --
    -- The debuff column is the tall one at roughly 332 against BODY_H. A field added to it
    -- will need the panel to grow, and growing it past 336 brings the page's own scrollbar
    -- back, so measure before adding one.
    local COL_W = 296
    local cast = Panel(parent, kind == "exboss" and "Cast Settings" or "Debuff Settings",
        0, -66, COL_W, BODY_H)
    local test = Panel(parent, kind == "exboss" and "Display & Voice" or "Sound",
        COL_W + 12, -66, COL_W, BODY_H)
    -- One panel now holds what the Voice tab used to; kept as its own name so the controls
    -- below read the same either way.
    local voice = test
    local healer = old and old.healerReminder == true
    -- Off for a catalogue ability nobody has set up, so this agrees with that ability's own
    -- switch in the list beside it. It read on before, contradicting both that switch and
    -- the missing Remove button, which is what made it look like a rule existed when none
    -- did. A rule being authored from scratch has no row to disagree with and still starts
    -- on, since asking for one is asking for it to work.
    local enabled
    if old then
        enabled = old.enabled ~= false
    else
        enabled = ability == nil
    end
    Toggle(cast, "Enabled", function() return enabled end,
        function(v) enabled = v; AutoSave() end, -42, 268)
    Toggle(cast, "Healer Reminder", function() return healer end,
        function(v) healer = v; AutoSave() end, -78, 268)
    local name = Commit(Box(test, "Reminder name",
        old and old.name or (ability and ability.name) or "Debuff alert", -44, 268))
    local duration
    local lead, spell, map
    local auraEvent, target = t.auraEvent or "Added", t.target or "player"
    if kind == "exboss" then
        duration = Commit(Box(test, "Display duration (1-15 seconds)", d.dur or 3, -100, 268))
        lead = Commit(Box(cast, "Warn before readiness (0-30 seconds)", t.timeleft or 5, -124, 268))
        Label(cast, "Timing predicts when the ability is ready. The cast itself is watched separately, which is where a target name can come from.", 14, -184, 268)
    else
        spell = Commit(Box(cast, "Debuff spell ID", spellID, -120, 268))
        -- Picked by name, not typed as an id. The catalogue already knows every dungeon it
        -- carries trash data for, and the trash page has always chosen one this way.
        --
        -- The list is not the whole world, though, and the box has to stay reachable. The
        -- catalogue comes from ExBoss and covers dungeons it holds trash data for: without
        -- that addon it is empty, and a raid is not in it either. Offering only the list
        -- would mean an alert could be scoped to nothing at all on a client without
        -- ExBoss, which is a capability this page used to have. So "Another instance"
        -- brings the id field back, and an id the list does not carry keeps an entry of
        -- its own rather than being quietly moved somewhere it was not set for.
        --
        -- There is no "every dungeon or raid" choice: a debuff alert names the instance it
        -- belongs to. Zero still MEANS everywhere to the engine and an alert saved with it
        -- keeps firing everywhere -- it shows as "Instance 0" until rescoped, and can be
        -- typed back in through the id field by anyone who wants it.
        local catalogue = I.Catalogue() or {}
        -- A new alert starts on the first dungeon rather than at zero, which would show as
        -- an instance nobody chose. With no catalogue there is nothing to start it on, so
        -- it stays at zero and the id field is the way through.
        if not old and mapChoice == 0 and catalogue[1] then mapChoice = catalogue[1].id end
        local mapValues, mapOrder = {}, {}
        for _, dungeon in ipairs(catalogue) do
            mapValues[dungeon.id] = dungeon.name
            mapOrder[#mapOrder + 1] = dungeon.id
        end
        if not mapValues[mapChoice] then
            mapValues[mapChoice] = "Instance " .. tostring(mapChoice)
            mapOrder[#mapOrder + 1] = mapChoice
        end
        mapValues.other = "Another instance (by ID)"
        mapOrder[#mapOrder + 1] = "other"
        -- The id field costs a row, and four rows at the usual spacing already fill this
        -- column against BODY_H. Everything below tightens while it is showing rather than
        -- the panel growing, which would bring the page's own scrollbar back.
        --
        -- 42, not 48: a row is a 20px label over a 24px box, so the last of five sits at
        -- -120 - 4 * gap and ends 44 below that. At 48 it finished 20px past the panel's
        -- own border and over the status line underneath. 42 puts the fifth row's bottom
        -- exactly where the fourth sat before, which is the fit this column was built to.
        local gap = debuffByID and 42 or 56
        local yMap = -120 - gap
        Dropdown(cast, "Dungeon", mapValues, mapOrder,
            function() return debuffByID and "other" or mapChoice end,
            function(v)
                local wasByID = debuffByID
                if v == "other" then
                    debuffByID = true
                else
                    -- map is dropped with it: Value() prefers the box whenever one exists,
                    -- and it still does until the rebuild, so leaving it would save the id
                    -- last typed there instead of the dungeon just picked.
                    debuffByID, mapChoice, map = false, v, nil
                    AutoSave()
                end
                -- Only when the id field comes or goes. The dropdown repaints its own
                -- label, so an ordinary pick needs no rebuild, and rebuilding anyway threw
                -- away whatever was typed into an alert too incomplete to have saved yet.
                if wasByID ~= debuffByID then UI:RefreshPage(true) end
            end, yMap, 268)
        local yWhen = yMap - gap
        if debuffByID then
            map = Commit(Box(cast, "Instance ID (0 = every dungeon or raid)",
                mapChoice, yWhen, 268))
            yWhen = yWhen - gap
        end
        Dropdown(cast, "When", { Added = "Applied", ApplicationsIncreased = "Stack increased", Removed = "Removed" },
            { "Added", "ApplicationsIncreased", "Removed" }, function() return auraEvent end,
            function(v) auraEvent = v; AutoSave() end, yWhen, 268)
        Dropdown(cast, "Unit", { player = "Me", party = "Party members" }, { "player", "party" },
            function() return target end, function(v) target = v; AutoSave() end, yWhen - gap, 268)
        Label(test, "Use the debuff's aura spell ID. The Stoneform and Shadowmeld voices require Unit: Me and stay silent while that racial is on cooldown, unknown or unusable.\n\nChanges apply after combat and encounter restrictions end. Test previews the voice regardless of cooldown.", 14, -200, 268)
    end
    local preset = old and old.preset or "none"
    if kind == "exboss" then
        local values, order = { none = "This spec's active preset" }, { "none" }
        for _, p in ipairs(ns.ListPresets(I.Spec())) do
            values[p.key] = p.name; order[#order + 1] = p.key
        end
        if preset ~= "none" and not values[preset] then
            values[preset] = "Missing preset: " .. preset; order[#order + 1] = preset
        end
        Dropdown(cast, "Defensive preset", values, order, function() return preset end,
            function(v) preset = v; AutoSave() end, -242, 268)
    end
    local sound, tts = d.sound or "none", d.tts == true
    local paths, names, order = UI.BuildAlertSoundTables()
    UI.AppendSharedMediaSounds(paths, names, order)
    -- Named for whose voice it is, matching Naowh's other sound files. The keys are left
    -- alone: a saved rule and a shared pack both store the key, never the label, so
    -- renaming one of these can never orphan a rule somebody already made.
    if kind == "auraSound" then
        names["voice:stoneform-ready"] = "Stoneform - Naowh"
        order[#order + 1] = "voice:stoneform-ready"
        names["voice:shadowmeld-ready"] = "Shadowmeld - Naowh"
        order[#order + 1] = "voice:shadowmeld-ready"
    end
    Dropdown(voice, "Sound", names, order, function() return sound end,
        function(v) sound = v; AutoSave() end, kind == "exboss" and -156 or -100, 268)
    if kind == "exboss" then
        Toggle(voice, "Speak callout", function() return tts end,
            function(v) tts = v; AutoSave() end, -216, 268)
    end
    local status = Label(parent, "Changes save as you make them. Test previews your current choices.", 0, -66 - BODY_H - 10, 604)
    local function Value()
        local id, instanceID = spellID, mapID
        if spell then id = tonumber(spell:GetText()) end
        -- The box wins while it is the control on screen; otherwise the list's pick does.
        if map then instanceID = tonumber(map:GetText())
        elseif mapChoice then instanceID = mapChoice end
        return { name = name:GetText(), enabled = enabled, healerReminder = healer or nil,
            preset = kind == "exboss" and preset ~= "none" and preset or nil,
            trigger = { type = kind, spellID = id, mapID = instanceID,
                timeleft = lead and tonumber(lead:GetText()) or nil, auraEvent = auraEvent, target = target },
            -- No longer edited anywhere. A preset writes the spoken and shown line itself,
            -- and a blank line is what asks for one; only a rule saved while this page still
            -- had a text box carries any, and it keeps it.
            display = { type = d.type or "icon",
                text = d.text or "", sound = sound,
                spellID = d.spellID or id, dur = kind == "exboss" and tonumber(duration:GetText()) or 3,
                -- Carried through untouched rather than dropped. Nothing writes or reads
                -- them any more, but a rule or a shared pack saved while the cast repeat
                -- existed still has them, and rewriting a rule should not quietly strip
                -- fields a future version might mean something by.
                castRepeat = d.castRepeat,
                castAudio = d.castAudio,
                tts = kind == "exboss" and tts or false } }
    end
    -- Refuses rather than writing a half-finished rule: a spell id mid-typing is a valid
    -- number for a spell nobody meant, and I.Save would happily store it. The last good
    -- version stays saved until this one is worth saving.
    AutoSave = function()
        if I.Spec() ~= editedSpec or I.Rules(false) ~= editedRules then
            status:SetText("Profile or specialization changed. Select the reminder again.")
            return
        end
        local value = Value()
        if not I.ValidRule(value) then
            status:SetText("|cffF0A830Not saved:|r check IDs, timing and sound. "
                .. "A racial voice requires Unit: Me.")
            return
        end
        local ok, result = I.Save(uid, value)
        if not ok then status:SetText(result); return end
        status:SetText("Saved.")
        -- A rule that did not exist a moment ago now does, so the list has to show it and
        -- the editor has to gain its Remove button. Every later edit updates in place and
        -- leaves the page alone, or typing would fight a rebuild for the keyboard.
        if not uid then
            uid = result
            if kind == "auraSound" then debuffSelection, debuffByID = { uid = uid }, false
            else selection.uid = uid end
            UI:RefreshPage(true)
        end
    end

    local preview = ns.Button(parent, "Test", 120, 28, function()
        local r = Value()
        if I.ValidRule(r) then
            I.Preview(r)
            if kind == "exboss" and not r.display.tts and r.display.sound == "none" then
                status:SetText("Visual test only. Enable Speak Callout or select a Sound for audio.")
            elseif kind == "exboss" and r.display.tts then
                status:SetText("TTS uses Voice and Voice Volume in Setup. Check chat for any playback errors.")
            else
                status:SetText("Sound preview requested.")
            end
        else status:SetText("Check IDs and sound. A racial voice requires Unit: Me.") end
    end)
    -- Top right, on the tab row: the editor is a fixed height now and a button row under
    -- the body would put it back over the window's own edge. Both act on the whole rule
    -- rather than one group of its settings, so they stay reachable from every tab.
    preview:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -40)
    if uid then
        local remove = ns.Button(parent, "Remove", 120, 28, function()
            if I.Spec() ~= editedSpec or I.Rules(false) ~= editedRules then return end
            editedRules[uid] = nil
            if kind == "auraSound" then debuffSelection, debuffByID = {}, false
            else selection.uid = nil; selection.spellID = nil end
            I.Refresh(); UI:RefreshPage(true)
        end)
        remove:SetPoint("RIGHT", preview, "LEFT", -8, 0)
    end
end
-- Trash rules are saved per spec, so a second spec starts with nothing and rebuilding a
-- dungeon's worth of them by hand is the same ask the boss pages answer with their own Copy
-- From Spec. Deliberately plain next to that one: there is no boss to scope to and no
-- every-boss choice to offer, so the panel is the spec list and nothing else.
function ns.ShowCopyTrashRulesPopup(callerEUI, kind)
    local EUI = callerEUI or ns.UI
    local noun = kind == "auraSound" and "debuff alerts" or "trash rules"
    local specs = I.SpecsWithRules(kind)
    -- Provisional: the hint below wraps to a line count no arithmetic here can know, so the
    -- panel is resized to whatever the content measured once it is laid out.
    local dimmer, panel = ns.MakeModal(430, 150 + math.max(1, #specs) * 30, "copyTrashRules")

    local head = ns.Font(panel, 14, "OUTLINE")
    head:SetPoint("TOP", panel, "TOP", 0, -16)
    head:SetText(kind == "auraSound" and "Copy Debuff Alerts From" or "Copy Trash Rules From")

    local y = -46
    if #specs == 0 then
        local none = ns.Font(panel, 12, nil, ns.THEME.muted)
        none:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
        none:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
        none:SetJustifyH("LEFT")
        none:SetWordWrap(true)
        none:SetText(("No other spec has any %s saved yet."):format(noun))
    else
        local hint = ns.Font(panel, 11, nil, ns.THEME.muted)
        hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
        hint:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        -- The class warning is the one thing worth saying up front: a rule names a spell YOU
        -- cast, so taking one from another class lands rules for spells this spec does not
        -- have. Said rather than prevented -- the same curator who wants it knows why.
        hint:SetText("Anything this spec already has is left alone. A rule calls out one of "
            .. "your own spells, so copying from another class brings rules for spells this "
            .. "spec cannot cast.")
        hint:SetHeight(math.max(16, hint:GetStringHeight() + 4))
        y = y - hint:GetHeight() - 12

        for i = 1, #specs do
            local s = specs[i]
            local btn = ns.Button(panel, s.name, 210, 24, function()
                local copied, skipped = I.CopyRulesFromSpec(s.key, kind)
                ns.Print(("copied |cff0091ed%d|r %s from %s%s."):format(
                    copied, noun, s.name,
                    skipped > 0 and (", left " .. skipped .. " already here alone") or ""))
                dimmer:Hide()
                if EUI and EUI.RefreshPage then EUI:RefreshPage(true) end
            end)
            btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, y)
            local count = ns.Font(panel, 11, nil, ns.THEME.muted)
            count:SetPoint("LEFT", btn, "RIGHT", 10, 0)
            count:SetText(("%d saved"):format(s.total))
            y = y - 30
        end
    end

    -- Cancel anchors to the panel's own bottom, so fitting the panel to the content moves
    -- it with them rather than leaving it floating under a short list.
    panel:SetHeight(math.max(150, -y + 58))
    ns.Button(panel, "Cancel", 90, 26, function() dimmer:Hide() end)
        :SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)
    dimmer:Show()
end

-- Shared by both list pages: a row that is the spell icon, the name, and a switch when
-- there is a saved rule behind it to switch. Deliberately tight -- the whole list used to
-- be two scrollbars deep on a dungeon with a dozen abilities.
local ROW_H, ICON = 26, 20

-- Every row carries a switch, reading off until a reminder exists behind it, so the list
-- says at a glance what is set up. Turning one on for an ability with nothing saved writes
-- the rule the editor would have written and opens it, which is the same "create on demand"
-- the boss ability rows already do rather than a second Add button.
local function ListRow(list, ly, width, text, icon, rule, active, onClick, onCreate, indent)
    local row = ns.Button(list, text, width, ROW_H, onClick)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", indent or 0, -ly)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", 64, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    local on = rule ~= nil and rule.enabled ~= false
    local toggle = UI.BuildToggleControl(row, row:GetFrameLevel() + 2,
        function() return on end,
        function(v)
            on = v and true or false
            if rule then
                rule.enabled = on
                I.Refresh()
            elseif on and onCreate then
                onCreate()
            end
        end, 26, 13)
    toggle:SetPoint("LEFT", row, "LEFT", 6, 0)

    if icon then
        local holder = CreateFrame("Frame", nil, row)
        holder:SetSize(ICON, ICON)
        holder:SetPoint("LEFT", row, "LEFT", 38, 0)
        local tex = holder:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(icon)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ns.Border(holder, { r = 0, g = 0, b = 0 }, 1)
    end
    if active then ns.Border(row, ns.THEME.accent) end
    return row
end

-- Which dungeon groups are folded shut, keyed by instance id. Outside the page for the
-- same reason the scroll offset is: clicking a header rebuilds the page and the state has
-- to outlive that. Not saved to the profile, since which group you last had open is not a
-- setting and reopening the window somewhere unexpected is worse than starting open.
local debuffCollapsed = {}

-- Plus and minus rather than a drawn chevron: it is the tree idiom the game itself uses,
-- and it costs no geometry to get right at two sizes.
local function GroupHeader(list, ly, width, name, count, collapsed, onClick)
    local row = ns.Button(list, ("%s  %s  (%d)"):format(collapsed and "+" or "-", name, count),
        width, ROW_H, onClick)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -ly)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.label:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.label:SetTextColor(ns.THEME.accent.r, ns.THEME.accent.g, ns.THEME.accent.b, 1)
    return row
end

local function StatusLines(parent, y)
    local status = Label(parent, I.trashStatus or "", 20, y - 26, 900)
    local function AuraStatus()
        return (I.auraStatus or "") .. (I.racialStatus and ("  " .. I.racialStatus) or "")
    end
    local auraStatus = Label(parent, AuraStatus(), 20, y - 44, 900)
    -- Deliberately unguarded. An IsVisible() test here looked free and was not: nothing
    -- re-runs this when the page is shown again, so a hidden page came back carrying
    -- whatever it had when it was hidden. The cost this would have saved is two SetText
    -- calls, and the event storm that made them add up is already stopped upstream by
    -- UpdateRacial's unchanged-reason early return.
    I.OnStatusChanged = function()
        status:SetText(I.trashStatus or ""); auraStatus:SetText(AuraStatus())
    end
end

function ns.BuildIntegrationsPage(parent, y)
    I.Refresh()
    Label(parent, "Trash Alerts", 20, y - 4, 900, 16, ns.THEME.accent)

    -- Beside the heading rather than buried in the list: it acts on the whole spec, not on
    -- whichever dungeon happens to be selected below, and it brings debuff rules too.
    local others = I.SpecsWithRules and I.SpecsWithRules("exboss") or {}
    if #others > 0 then
        local copy = ns.Button(parent, "Copy From Spec", 160, 24, function()
            ns.ShowCopyTrashRulesPopup(UI, "exboss")
        end)
        copy:SetPoint("TOPLEFT", parent, "TOPLEFT", 160, y)
        ns.Tooltip(copy, "Copy From Spec",
            "Brings another spec's trash rules over to this one. Rules are saved per spec, "
            .. "and anything already here is left alone. Debuff alerts have their own "
            .. "button on their own tab.")
    end

    StatusLines(parent, y)

    local catalogue = I.Catalogue()

    -- Which saved rules a dungeon in the catalogue already accounts for. Worked out up
    -- here rather than beside the list below, because whether the "Every dungeon" entry is
    -- worth offering at all depends on whether anything is left over.
    local rules = I.Rules(false) or {}
    local savedFor, claimed = {}, {}
    for uid, r in pairs(rules) do
        if r.trigger.type == "exboss" then
            local key = r.trigger.mapID .. ":" .. r.trigger.spellID
            if not savedFor[key] or uid < savedFor[key] then savedFor[key] = uid end
        end
    end
    for _, dungeon in ipairs(catalogue) do
        for _, ability in ipairs(dungeon.abilities) do
            local uid = savedFor[dungeon.id .. ":" .. ability.spellID]
            if uid then claimed[uid] = true end
        end
    end
    local hasLoose = false
    for uid, r in pairs(rules) do
        if r.trigger.type == "exboss" and not claimed[uid] then hasLoose = true break end
    end

    local values, order = {}, {}
    for _, dungeon in ipairs(catalogue) do
        values[dungeon.id] = dungeon.name; order[#order + 1] = dungeon.id
    end
    -- Only when something is actually in it. It is the bucket for a saved rule no dungeon
    -- in the catalogue accounts for, which is usually nothing, and an entry that opens an
    -- empty list every time is an entry worth not having. Kept rather than deleted so a
    -- rule that lands there stays reachable instead of firing from somewhere unopenable.
    if hasLoose then
        values.saved = "Every dungeon"
        order[#order + 1] = "saved"
    end
    -- One dungeon at a time. Listing every one at once was hundreds of rows deep and made
    -- the choice of dungeon something you scrolled past rather than made.
    if not values[selection.dungeon] then
        selection = { dungeon = catalogue[1] and catalogue[1].id or "saved" }
    end

    local side = Panel(parent, "Select a Dungeon", 20, y - 68, 280, PANEL_H)
    Dropdown(side, "Dungeon", values, order, function() return selection.dungeon end, function(v)
        selection = { dungeon = v }; UI:RefreshPage(true)
    end, -42, 252)

    local scroll = CreateFrame("ScrollFrame", nil, side, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -96)
    scroll:SetSize(240, PANEL_H - 108)
    local list = CreateFrame("Frame", nil, scroll)
    list:SetWidth(240); scroll:SetScrollChild(list)

    -- Cast rules only. Debuff alerts have their own tab: they answer to no dungeon and were
    -- only ever reachable here through a bucket at the bottom of somebody else's list.
    local sections = {}
    if selection.dungeon ~= "saved" then
        for _, dungeon in ipairs(catalogue) do
            if dungeon.id == selection.dungeon then
                sections[1] = { id = dungeon.id, name = dungeon.name,
                    dungeon = dungeon, abilities = dungeon.abilities }
            end
        end
    else
        local loose = {}
        for uid, r in pairs(rules) do
            if r.trigger.type == "exboss" and not claimed[uid] then
                loose[#loose + 1] = { uid = uid, name = r.name }
            end
        end
        table.sort(loose, function(a, b) return a.uid < b.uid end)
        sections[1] = { id = "saved", name = "Rules for every dungeon", loose = loose }
    end

    local chosen, ly = nil, 0
    -- No section header: the dropdown above already names the dungeon, and repeating it on
    -- the row below was saying the same thing twice. One dungeon shows at a time, so there
    -- was never a second section to collapse away from either.
    for _, section in ipairs(sections) do
        local entries = {}
        if section.loose then
            for _, item in ipairs(section.loose) do entries[#entries + 1] = item end
        else
            for _, ability in ipairs(section.abilities) do
                entries[#entries + 1] = { ability = ability,
                    uid = savedFor[section.id .. ":" .. ability.spellID] }
            end
        end
        for _, entry in ipairs(entries) do
            local ability, uid = entry.ability, entry.uid
            local rule = uid and rules[uid]
            local active = (uid and uid == selection.uid)
                or (ability and not selection.uid
                    and ability.spellID == selection.spellID
                    and section.id == selection.spellMap)
            if active then
                chosen = { uid = uid, ability = ability, dungeon = section.dungeon }
            end
            local row = ListRow(list, ly, 236, ability and ability.name or entry.name,
                ability and ability.icon, rule, active, function()
                    selection.uid = uid
                    selection.spellID = ability and ability.spellID
                    selection.spellMap = section.id
                    UI:RefreshPage(true)
                end, ability and function()
                    local ok, result = I.Save(nil, {
                        name = ability.name, enabled = true,
                        trigger = { type = "exboss", spellID = ability.spellID,
                            mapID = section.id, timeleft = 5 },
                        display = { type = "icon", text = "", dur = 3 },
                    })
                    if not ok then ns.Print("|cffff6060" .. tostring(result) .. "|r"); return end
                    selection.uid = result
                    selection.spellID = ability.spellID
                    selection.spellMap = section.id
                    UI:RefreshPage(true)
                end or nil)
            ns.Tooltip(row, ability and ability.name or entry.name,
                ability and (ability.mob .. "\nSpell " .. ability.spellID
                    .. (rule and "\n\nSet up on this spec." or "\n\nNot set up yet."))
                or "Edit this saved reminder.")
            ly = ly + ROW_H + 1
        end
    end
    -- Keyed on nothing having been drawn rather than on an empty catalogue: a dungeon
    -- with no abilities and a "saved" bucket with nothing in it are just as blank, and
    -- the label can never land on top of a row this way.
    if ly == 0 then
        Label(list, "No trash abilities to show. The list comes from ExBoss: enable or "
            .. "update it, then reopen this page.", 4, 0, 230)
        ly = 60
    end
    list:SetHeight(math.max(1, ly))
    KeepListScroll(scroll, "trash", math.max(1, ly))

    local selectedDungeon
    for _, dungeon in ipairs(catalogue) do
        if dungeon.id == selection.dungeon then selectedDungeon = dungeon end
    end

    local right = CreateFrame("Frame", nil, parent)
    right:SetPoint("TOPLEFT", parent, "TOPLEFT", 320, y - 68)
    right:SetSize(604, PANEL_H)
    if chosen then Editor(right, chosen.uid, "exboss", chosen.ability, chosen.dungeon or selectedDungeon)
    else
        Label(right, "Select an ability to set up its callout, or switch one on to start from the defaults.", 0, 0, 604, 14)
        Label(right, "Debuff alerts live on their own tab. Changes save as you make them.", 0, -40, 604)
    end
    -- Measured rather than guessed: the wrapper adds its own padding on top of this,
    -- and a fixed number claimed room the page never used.
    return y - (68 + PANEL_H + 8)
end

-- Debuff alerts answer to an aura, not to a dungeon, so they get their own page rather than
-- a bucket at the bottom of the trash list where they had no dungeon to be filed under.
function ns.BuildDebuffsPage(parent, y)
    I.Refresh()
    Label(parent, "Debuff Alerts", 20, y - 4, 900, 16, ns.THEME.accent)

    -- Its own copy, of its own kind: these answer to an aura rather than a dungeon, and the
    -- trash page's button no longer reaches them.
    local others = I.SpecsWithRules and I.SpecsWithRules("auraSound") or {}
    if #others > 0 then
        local copy = ns.Button(parent, "Copy From Spec", 160, 24, function()
            ns.ShowCopyTrashRulesPopup(UI, "auraSound")
        end)
        copy:SetPoint("TOPLEFT", parent, "TOPLEFT", 160, y)
        ns.Tooltip(copy, "Copy From Spec",
            "Brings another spec's debuff alerts over to this one. They are saved per spec, "
            .. "and anything already here is left alone.")
    end
    StatusLines(parent, y)

    local side = Panel(parent, "Saved Debuff Alerts", 20, y - 68, 280, PANEL_H)
    local add = ns.Button(side, "+ Debuff Alert", 252, 26, function()
        debuffSelection, debuffByID = { newAura = true }, false; UI:RefreshPage(true)
    end)
    add:SetPoint("TOPLEFT", side, "TOPLEFT", 14, -42)

    local scroll = CreateFrame("ScrollFrame", nil, side, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -78)
    scroll:SetSize(240, PANEL_H - 90)
    local list = CreateFrame("Frame", nil, scroll)
    list:SetWidth(240); scroll:SetScrollChild(list)

    local rules = I.Rules(false) or {}
    local rows = {}
    for uid, r in pairs(rules) do
        if r.trigger.type == "auraSound" then rows[#rows + 1] = { uid = uid, rule = r } end
    end
    table.sort(rows, function(a, b) return a.uid < b.uid end)

    -- Grouped by the instance each alert is set for. The catalogue names the ones it knows;
    -- an id it does not carry still gets a group of its own rather than being hidden, and
    -- an alert set for everywhere has no instance to file under so it goes last.
    local dungeonName = {}
    for _, dungeon in ipairs(I.Catalogue() or {}) do dungeonName[dungeon.id] = dungeon.name end
    local groups, byMap = {}, {}
    for _, entry in ipairs(rows) do
        local mapID = entry.rule.trigger.mapID or 0
        local group = byMap[mapID]
        if not group then
            group = { mapID = mapID, entries = {},
                name = (mapID == 0 and "Every dungeon or raid")
                    or dungeonName[mapID] or ("Instance " .. tostring(mapID)) }
            byMap[mapID] = group
            groups[#groups + 1] = group
        end
        group.entries[#group.entries + 1] = entry
    end
    table.sort(groups, function(a, b)
        if (a.mapID == 0) ~= (b.mapID == 0) then return b.mapID == 0 end
        return a.name < b.name
    end)

    local chosen, ly = nil, 0
    for _, group in ipairs(groups) do
        local key = tostring(group.mapID)
        local collapsed = debuffCollapsed[key] == true
        GroupHeader(list, ly, 236, group.name, #group.entries, collapsed, function()
            debuffCollapsed[key] = (not collapsed) or nil
            UI:RefreshPage(true)
        end)
        ly = ly + ROW_H + 1
        for _, entry in ipairs(group.entries) do
            local rule = entry.rule
            local active = not debuffSelection.newAura and entry.uid == debuffSelection.uid
            -- Found whether or not its group is open: folding a group away is not the same
            -- as deselecting what is inside it, and the editor on the right must not blank.
            if active then chosen = entry end
            if not collapsed then
                local icon = C_Spell and C_Spell.GetSpellTexture
                    and C_Spell.GetSpellTexture(rule.trigger.spellID)
                local row = ListRow(list, ly, 224, rule.name or "Debuff alert", icon, rule,
                    active,
                    function()
                        debuffSelection, debuffByID = { uid = entry.uid }, false
                        UI:RefreshPage(true)
                    end,
                    nil, 12)
                ns.Tooltip(row, rule.name or "Debuff alert",
                    ("Aura %s on %s, when %s."):format(tostring(rule.trigger.spellID),
                        rule.trigger.target == "party" and "a party member" or "you",
                        (rule.trigger.auraEvent or "Added"):lower()))
                ly = ly + ROW_H + 1
            end
        end
    end
    if #rows == 0 then
        Label(list, "None yet. Add one with the button above.", 4, 0, 230)
        ly = 40
    end
    list:SetHeight(math.max(1, ly))
    KeepListScroll(scroll, "debuff", math.max(1, ly))

    local right = CreateFrame("Frame", nil, parent)
    right:SetPoint("TOPLEFT", parent, "TOPLEFT", 320, y - 68)
    right:SetSize(604, PANEL_H)
    if debuffSelection.newAura then Editor(right, nil, "auraSound", nil, nil)
    elseif chosen then Editor(right, chosen.uid, "auraSound", nil, nil)
    else
        Label(right, "A debuff sound plays when an aura is applied, stacks or falls off.", 0, 0, 604, 14)
        Label(right, "Use the debuff's own aura spell ID. These apply wherever you set them, not to one dungeon. Changes save as you make them.", 0, -40, 604)
    end
    -- Measured rather than guessed: the wrapper adds its own padding on top of this,
    -- and a fixed number claimed room the page never used.
    return y - (68 + PANEL_H + 8)
end