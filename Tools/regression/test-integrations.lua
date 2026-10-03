local root = arg[1] or "."
local function Fixture()
    local e = { now = 0, map = 1877, kind = "party", spec = 250, timers = {}, shown = {}, added = {}, removed = {}, hooks = {},
        registered = {}, muteCalls = {}, mutedBy = {}, known = true, dead = false, usable = true,
        cooldown = { isActive = false, isEnabled = true }, restrictions = {} }
    local db = { enabled = true, integrationRules = { ["250"] = {} } }
    local ns = { UI = {}, trackedReminderTimers = {} }
    ns.DB = function() return db end
    ns.IsReminderEnabled = function(r) return r.enabled ~= false and not (e.healerOff and r.healerReminder) end
    ns.DisplayRaidReminder = function(r) e.shown[#e.shown + 1] = r end
    ns.DisplayIntegrationReminder = function(r) e.shown[#e.shown + 1] = r end
    ns.HideIntegrationReminders = function() e.hidden = true end
    ns.ResolveReminderSpell = function() return e.picked end
    ns.InEncounter = function() return e.encounter end
    ns.PlayReminderSound = function(d) e.previewSound = true; e.previewKey = d.sound end
    ns.UI.SoundPathFor = function(key)
        if key == "voice:stoneform-ready" then return "stoneform-ready.ogg" end
        if key == "voice:shadowmeld-ready" then return "shadowmeld-ready.ogg" end
        return key == "test" and "Interface/AddOns/Test/test.ogg"
    end
    local env = setmetatable({ NaowhUITankReminder = ns, Enum = { UnitAuraSoundTrigger = { Added = 0, ApplicationsIncreased = 1, Removed = 2 } },
        GetTime = function() return e.now end,
        GetSpecialization = function() return 1 end, GetSpecializationInfo = function() return e.spec end,
        GetInstanceInfo = function() return "Dungeon", e.kind, 8, "", 5, 0, false, e.map end,
        InCombatLockdown = function() return e.combat end,
        C_Spell = { GetSpellInfo = function() return { name = "Anti-Magic Shell" } end,
            -- Per spell where a case says so, falling back to the shared answer.
            GetSpellCooldown = function(id)
                if e.cooldowns and e.cooldowns[id] ~= nil then return e.cooldowns[id] end
                return e.cooldown
            end,
            IsSpellUsable = function(id)
                if e.usables and e.usables[id] ~= nil then return e.usables[id] end
                return e.usable
            end },
        C_SpellBook = { IsSpellKnown = function(id)
            if e.knowns and e.knowns[id] ~= nil then return e.knowns[id] end
            return e.known
        end },
        UnitIsDeadOrGhost = function() return e.dead end,
        MuteSoundFile = function(path)
            e.muted = true; e.mutedBy[path] = true; e.muteCalls[#e.muteCalls + 1] = path
        end,
        UnmuteSoundFile = function(path)
            e.muted = false; e.mutedBy[path] = false; e.muteCalls[#e.muteCalls + 1] = path
        end,
        C_RestrictedActions = { GetAddOnRestrictionState = function(kind) return e.restrictions[kind] or 0 end },
        CreateFrame = function() return { SetScript = function(_, _, f) e.event = f end,
            RegisterEvent = function(_, event) e.registered[event] = true end,
            UnregisterEvent = function(_, event) e.registered[event] = nil end } end,
        hooksecurefunc = function(object, name, callback) e.hooks[name] = callback end,
        issecretvalue = function(v) return v == e.secret end,
        canaccesstable = function(v) return v ~= e.forbidden end,
        C_UnitAuras = { AddAuraSound = function(trigger, info)
            assert(not e.combat and not e.encounter and not e.restrictions[0] and not e.restrictions[1])
            e.added[#e.added + 1] = { trigger = trigger, info = info }; return #e.added
        end, RemoveAuraSound = function(id)
            assert(not e.combat and not e.encounter); e.removed[#e.removed + 1] = id
        end },
    }, { __index = _G })
    env._G = env
    env.Enum.AddOnRestrictionType = { Combat = 0, Encounter = 1, Map = 4 }
    env.Enum.AddOnRestrictionState = { Inactive = 0, Activating = 1, Active = 2 }
    e.secret, e.forbidden = {}, {}
    ns.PruneCustomReminderTimers = function()
        for i = #ns.trackedReminderTimers, 1, -1 do
            local t = ns.trackedReminderTimers[i]
            if not t.valid() then t.handle:Cancel(); table.remove(ns.trackedReminderTimers, i) end
        end
    end
    ns.TrackReminderTimer = function(_, delay, callback, _, valid)
        local handle = { Cancel = function(t) t.cancelled = true end }
        local entry = { handle = handle, valid = valid }
        ns.trackedReminderTimers[#ns.trackedReminderTimers + 1] = entry
        e.timers[#e.timers + 1] = { at = e.now + delay, handle = handle, callback = callback, valid = valid }
        return entry
    end
    local scheduler = { active = {}, _AdvanceTrashFixedCombatTimeline = function() end, RegisterTrashLocalTimer = function() end, _RemoveActiveTimerByID = function() end }
    function scheduler:GetActiveTimers() return self.active end
    env.ExBoss = { Timeline = { Scheduler = scheduler } }
    local chunk = assert(loadfile(root .. "/NaowhUI_SmartReminders_Integrations.lua")); setfenv(chunk, env); chunk()
    e.I, e.ns, e.env, e.db, e.scheduler = ns.Integrations, ns, env, db, scheduler
    function e:advance(at)
        self.now = at
        for _, t in ipairs(self.timers) do
            if not t.handle.cancelled and t.at <= at then
                t.handle.cancelled = true
                if t.valid() then t.callback() end
            end
        end
    end
    function e:rule(kind)
        return { name = "Test", enabled = true, trigger = { type = kind or "exboss", spellID = 123,
            mapID = 1877, timeleft = 5, target = "player", auraEvent = "Added" },
            display = { type = "icon", text = "Defensive", dur = 3, sound = "test" } }
    end
    function e:timer(id, at)
        self.scheduler.active[id] = { source = "trash", spellID = 123, castTime = at }
        self.I.ObserveTimer(self.scheduler, id)
    end
    return e
end
local count = 0
local function Case(name, fn) fn(); count = count + 1; print("PASS " .. name) end
Case("reused trash timer delivers each deadline once across refreshes", function()
    local e = Fixture()
    e.I.Save(nil, e:rule())
    e:timer(1, 10); e:advance(5)
    assert(#e.shown == 1)
    e:advance(10)
    e.scheduler.active[1].castTime = 20
    e.I.ObserveTimer(e.scheduler, 1); e.I.ObserveTimer(e.scheduler, 1)
    e:advance(15); assert(#e.shown == 2)
    e.I.Refresh(); e:advance(16); assert(#e.shown == 2)
end)
Case("observed cast anchor separates early new cycles from corrections", function()
    local e = Fixture(); e.I.Save(nil, e:rule())
    e.scheduler.active[1] = {source="trash", spellID=123, castTime=10,
        trashRuntime={nextSpellAnchorAt={[123]=0}}}
    e.I.ObserveTimer(e.scheduler, 1); e:advance(5); assert(#e.shown == 1)
    e.scheduler.active[1].castTime = 12
    e.I.ObserveTimer(e.scheduler, 1); e:advance(7); assert(#e.shown == 1)
    e.scheduler.active[1].trashRuntime.nextSpellAnchorAt[123] = 7
    e.scheduler.active[1].castTime = 20
    e.I.ObserveTimer(e.scheduler, 1); e:advance(15); assert(#e.shown == 2)
end)
Case("fixed combat timeline advancement schedules the next reminder", function()
    local e = Fixture()
    e.I.Save(nil, e:rule())
    e:timer(1, 10); e:advance(5)
    local timer = e.scheduler.active[1]; timer.id = 1; timer.trashFixedCombatTimeline = true; timer.castTime = 20
    e.hooks._AdvanceTrashFixedCombatTimeline(e.scheduler, timer)
    e.hooks._AdvanceTrashFixedCombatTimeline(e.scheduler, timer)
    e:advance(15); assert(#e.shown == 2)
end)
Case("invalid edited aura IDs are rejected without replacing saved rule", function()
    local e = Fixture(); local r = e:rule("auraSound")
    local ok, uid = e.I.Save(nil, r); assert(ok)
    for _, field in ipairs({ "spellID", "mapID" }) do
        local edited = e:rule("auraSound"); edited.trigger[field] = nil
        assert(not e.I.Save(uid, edited))
        assert(e.I.Rules(false)[uid] == r)
    end
end)

Case("preset and custom-text previews use addon voice volume, with silence diagnostics", function()
    local e = Fixture()
    local file = assert(io.open(root .. "/NaowhUI_SmartReminders.lua", "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n"); file:close()
    local speech = assert(source:match("function ns.SpeakReminderTTS%b()%s*.-\nend"))
    local calls, messages = {}, {}
    e.env.C_VoiceChat = {
        GetTtsVoices = function() return { { voiceID = 2 } } end,
        SpeakText = function(...) calls[#calls + 1] = { ... } end,
    }
    e.env.C_TTSSettings = { GetSpeechRate = function() return 0 end,
        GetSpeechVolume = function() return 0 end }
    e.ns.TTSVoiceID = function() return 2 end
    e.ns.Print = function(message) messages[#messages + 1] = message end
    e.db.voiceVol = 65
    local chunk = assert(loadstring("local ns, TRDB = ...; " .. speech))
    setfenv(chunk, e.env); chunk(e.ns, e.ns.DB)
    -- The real function, not a stand-in: resolving a preset to the spoken name is the half
    -- of it worth testing, and a stub would only ever be testing the stub.
    -- Both halves of the real thing, plus the callout-name lookup they resolve through:
    -- the spoken line has to be the name the player gave the spell, not Blizzard's.
    local callout = assert(source:match("local function CalloutFor%b()%s*.-\nend"))
    local shower = assert(source:match("local function ShowOnAlert%b()%s*.-\nend"))
    -- The set helpers too: the spoken line for a preset-bound reminder resolves through
    -- them, and they are the half this suite is here to pin.
    local integ = callout .. "\n" .. shower .. "\n" ..
        assert(source:match("function ns.TogetherPartners%b()%s*.-\nend")) .. "\n" ..
        assert(source:match("function ns.SetCalloutLine%b()%s*.-\nend")) .. "\n" ..
        assert(source:match("function ns.IntegrationPreset%b()%s*.-\nend")) .. "\n" ..
        assert(source:match("function ns.DisplayIntegrationReminder%b()%s*.-\nend"))
    e.env.TRDB = e.ns.DB
    -- File-locals in the real chunk, so the slice reads them from the environment.
    e.env.specID = 250
    e.env.PresetsTable = function() return { defensives = { list = { 48707 } } } end
    e.env.ActivePresetKey = function() return "defensives" end
    -- The defensive alert's own internals, which the function now drives directly.
    local alert = {}
    e.env.Reminder = { Create = function() alert.created = true end }
    e.env.RebuildSlots = function(_, keepIfEmpty, preset)
        alert.preset, alert.keepIfEmpty = preset, keepIfEmpty; return true
    end
    e.env.ApplyPriorityAlpha = function() end
    e.env.ClearTankGate = function() end
    e.env.HideReminder = function() alert.hidden = true end
    e.env.textFrame = { Show = function() alert.textShown = true end,
        SetFrameStrata = function(_, v) alert.textStrata = v end }
    e.env.frame = { Show = function() alert.shown = true end,
        SetFrameStrata = function(_, v) alert.strata = v end,
        reminder = { SetText = function(_, t) alert.line = t end,
            Show = function() alert.lineShown = true end,
            Hide = function() alert.lineShown = false end } }
    e.env.C_Timer = { NewTimer = function(delay)
        alert.dur = delay; return { Cancel = function() end }
    end }
    -- Two slots left showing whatever the spec's preset last built.
    alert.slots = { { alpha = 1 }, { alpha = 1 } }
    for _, slot in ipairs(alert.slots) do
        slot.SetAlpha = function(self, a) self.alpha = a end
    end
    e.env.slots = alert.slots
    e.env.activeSlots = 2
    e.env.frame.fallback = { SetAlpha = function(_, a) alert.fallbackAlpha = a end }
    local ichunk = assert(loadstring("local ns = ...; " .. integ))
    setfenv(ichunk, e.env); ichunk(e.ns)
    local r = e:rule(); r.display.tts = true; r.display.text = "Move out"
    e.I.Preview(r)
    -- No preset: the rule's own line on the alert's authored-line row, no slot rebuild.
    assert(alert.shown and alert.line == "Move out" and alert.lineShown)
    assert(alert.preset == nil and alert.dur == r.display.dur)
    -- A custom line shows alone: a defensive left in the slots from the spec's own preset
    -- is not part of what this rule asked for.
    assert(alert.slots[1].alpha == 0 and alert.slots[2].alpha == 0)
    assert(e.env.activeSlots == 0 and alert.fallbackAlpha == 0)
    assert(e.ns.slotsStale == true, "the real list is rebuilt when the callout ends")
    assert(#calls == 1 and calls[1][1] == 2 and calls[1][2] == "Move out")
    assert(calls[1][3] == 0 and calls[1][4] == 65 and calls[1][5] == false)
    r.preset = "defensives"; e.picked = 48707; e.I.Preview(r)
    assert(calls[2][2] == "Anti-Magic Shell")
    -- With a preset the alert's own slots answer, and the custom line is put away.
    assert(alert.preset == "defensives" and alert.keepIfEmpty == true)
    assert(alert.lineShown == false, "the custom line must not sit under the slots")
    assert(e.env.shownForEvent == "authored", "the alert is marked occupied")
    e.db.voiceVol = 0; e.I.Preview(r)
    assert(#calls == 2 and messages[#messages]:find("Voice Volume is zero", 1, true))
    e.db.voiceVol = 100; e.env.C_VoiceChat.GetTtsVoices = function() return {} end
    e.I.Preview(r); assert(#calls == 2 and messages[#messages]:find("No TTS voices", 1, true))
    e.env.C_VoiceChat.GetTtsVoices = function() return { { voiceID = 2 } } end
    e.env.C_VoiceChat.SpeakText = function() error("unavailable") end
    e.I.Preview(r); assert(messages[#messages]:find("could not start TTS", 1, true))
    r.display.tts = false; local before = #messages
    e.I.Preview(r); assert(#messages == before)

    -- Renaming Anti-Magic Shell to "AMS" renames what it SAYS, the same way the slot label
    -- beside it has always followed the rename. Speaking the full name was the two channels
    -- disagreeing about one spell.
    e.env.C_VoiceChat.SpeakText = function(...) calls[#calls + 1] = { ... } end
    r.display.tts = true
    e.db.callouts = { [48707] = "AMS" }
    e.I.Preview(r)
    assert(calls[#calls][2] == "AMS", "the spoken line must use the name you gave it")

    -- A preset built as "AMS + Death's Advance" says both halves, not whichever one
    -- happened to win the pick. The boss callout has always done this; the authored path
    -- that trash rules fire through spoke the winner alone.
    e.env.slots[1].spellID, e.env.slots[2].spellID = 48707, 48265
    e.env.activeSlots = 2
    e.env.GetTime = function() return 0 end
    e.env.SpellReady = function() return true end
    e.ns.slotsPreset = "defensives"
    e.ns.IsAudioOff = function() return false end
    e.ns.CalledTogetherInPreset = function(_, _, sid)
        return sid == 48707 or sid == 48265
    end
    e.db.callouts = { [48707] = "AMS", [48265] = "DA" }
    e.I.Preview(r)
    assert(calls[#calls][2] == "AMS and DA", "got " .. tostring(calls[#calls][2]))

    -- A member that is down is left out rather than holding the callout back.
    e.env.SpellReady = function(sid) return sid ~= 48265 end
    e.I.Preview(r)
    assert(calls[#calls][2] == "AMS", "a set of one speaks as one")

    -- Muting a member drops it from the line without dropping the set.
    e.env.SpellReady = function() return true end
    e.ns.IsAudioOff = function(sid) return sid == 48265 end
    e.I.Preview(r)
    assert(calls[#calls][2] == "AMS")

    -- Nothing on the preset is up. The slots have already gone dark, and the audio has to
    -- agree: a rule sitting on the bundled "Use a defensive" clip, or on the generic line
    -- a rule without its own text carries, was calling for a defensive that was not there.
    e.picked = nil
    e.previewSound, e.previewKey = nil, nil
    local quiet = #calls
    e.I.Preview(r)
    assert(#calls == quiet, "nothing is up, so nothing is spoken")
    assert(not e.previewSound, "and the rule's own clip stays quiet with it")

    -- A rule carrying only custom text is untouched: it never asked what was ready.
    local plain = e:rule(); plain.display.tts = true; plain.display.text = "Move out"
    e.I.Preview(plain)
    assert(calls[#calls][2] == "Move out" and e.previewSound)
end)
Case("repeated previews replace the last test and preserve live reminders", function()
    local e = Fixture()
    local file = assert(io.open(root .. "/NaowhUI_SmartReminders_RaidReminders.lua", "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n"); file:close()
    local cleanup = assert(source:match("function ns.HideIntegrationReminders%b()%s*.-\nend"))
    -- Anything already in the region pool when the integration display moved onto the
    -- shared reminder frame is still there, so that sweep has to keep working.
    local legacy = { reminderEntry = { integration = true } }
    local other = { reminderEntry = {} }
    local anchor = { active = { legacy, other } }
    local chunk = assert(loadstring("local ns, anchors, ReleaseRegion = ...; " .. cleanup))
    chunk(e.ns, { anchor }, function(a, r)
        r.cancelled = true
        for i = #a.active, 1, -1 do if a.active[i] == r then table.remove(a.active, i) end end
    end)
    -- Stands in for the shared frame: one showing at a time, cleared on the same terms.
    local showing
    e.ns.HideIntegrationCustomReminder = function(previewOnly)
        if showing and (not previewOnly or showing.integrationPreview) then
            showing.hidden = true; showing = nil
        end
    end
    e.ns.DisplayIntegrationReminder = function(rule, preview)
        showing = { integrationPreview = preview or nil, rule = rule }
    end
    e.I.Preview(e:rule()); local first = showing
    e.I.Preview(e:rule())
    assert(first.hidden and showing and showing ~= first)
    assert(#anchor.active == 2, "a preview must not disturb live entries in the pool")
    e.ns.HideIntegrationReminders()
    assert(#anchor.active == 1 and anchor.active[1] == other)
    assert(showing == nil)
end)
Case("catalogue maps challenge IDs to instance filters and deduplicates spells", function()
    local e = Fixture()
    assert(#e.I.Catalogue() == 0)
    local trash = { [249] = { mapName = "Kings Rest", mobs = {
        [10] = { spells = { [123] = {} } }, [11] = { spells = { [123] = {} } } } },
        [999] = { mapName = "Unmapped", mobs = {} } }
    local maps = { maps = { [1762] = { mapID = 1762, mapName = "Kings Rest" } } }
    e.env.EXBossData = { GetTrashCDDataRoot = function() return trash end,
        GetEncounterDataRoot = function() return maps end }
    e.env.GetLocale = function() return "enUS" end
    e.env.C_ChallengeMode = { GetMapUIInfo = function(id) assert(id == 249); return "Localized dungeon" end }
    local result = e.I.Catalogue()
    assert(#result == 1 and result[1].id == 1762 and result[1].name == "Localized dungeon")
    assert(#result[1].abilities == 1 and result[1].abilities[1].spellID == 123)
    assert(trash[249].mobs[10].spells[123].name == nil, "catalogue mutated provider data")
    maps.maps[2222] = { mapID = 2222, mapName = "Kings Rest" }
    assert(#e.I.Catalogue() == 0, "ambiguous instance mapping was guessed")
end)
Case("optional provider and empty configuration stay inactive, and say so", function()
    local e = Fixture(); e.env.ExBoss = nil; e.I.Refresh()
    assert(next(e.hooks) == nil and #e.added == 0)
    -- Nothing here can fire without the provider, so the tab has to name it rather than
    -- report an empty configuration.
    assert(e.I.trashStatus:find("ExBoss", 1, true))
    assert(e.I.Save(nil, e:rule())); e.I.Refresh()
    assert(e.I.trashStatus:find("ExBoss", 1, true))
    assert(next(e.hooks) == nil and #e.added == 0)
end)
Case("trash predictions schedule once, reschedule and cancel by timer identity", function()
    local e = Fixture(); assert(e.I.Save(nil, e:rule()))
    e:timer(1, 20); e.I.ObserveTimer(e.scheduler, 1)
    assert(#e.timers == 1)
    e.scheduler.active[1].castTime = 25; e.I.ObserveTimer(e.scheduler, 1)
    e:advance(15); assert(#e.shown == 0)
    e:advance(20); assert(#e.shown == 1)
    e:timer(2, 40); e.scheduler.active[2] = nil; e.hooks._RemoveActiveTimerByID(e.scheduler, 2)
    e:advance(40); assert(#e.shown == 1)
end)
Case("multiple identical mobs keep independent timers and short timers fire promptly", function()
    local e = Fixture(); e.I.Save(nil, e:rule())
    e:timer(1, 3); e:timer(2, 4); e:advance(0.02)
    assert(#e.shown == 2)
end)
Case("post-registration hook reads the assigned provider timer ID", function()
    local e=Fixture(); e.I.Save(nil,e:rule())
    e.scheduler.active[17]={ source="trash", spellID=123, castTime=12 }
    local runtime={ localTimerIDsBySpellID={ [123]=17 } }
    e.hooks.RegisterTrashLocalTimer(e.scheduler,runtime,{}, {spellID=123})
    e:advance(7); assert(#e.shown==1)
end)
Case("removed provider timer is rejected even without removal notification", function()
    local e = Fixture(); e.I.Save(nil, e:rule()); e:timer(1, 10)
    e.scheduler.active[1] = nil; e:advance(5); assert(#e.shown == 0)
end)
Case("map, spec, disable and healer changes invalidate old work", function()
    for _, what in ipairs({ "map", "spec", "disable", "healer", "profile" }) do
        local e = Fixture(); local r = e:rule(); r.healerReminder = true
        e.I.Save(nil, r); e:timer(1, 10)
        if what == "map" then e.map = 99
        elseif what == "spec" then e.spec = 251
        elseif what == "disable" then e.db.enabled = false
        elseif what == "profile" then e.db.integrationRules = { ["250"] = {} }
        else e.healerOff = true end
        e:advance(5); assert(#e.shown == 0, what)
    end
end)
Case("secret and inaccessible provider data never schedules", function()
    local e = Fixture(); e.I.Save(nil, e:rule())
    e.scheduler.active[1] = e.forbidden; e.I.ObserveTimer(e.scheduler, 1)
    e.scheduler.active[1] = { source = "trash", spellID = e.secret, castTime = 10 }; e.I.ObserveTimer(e.scheduler, 1)
    e.scheduler.active[1] = { source = "trash", spellID = 123, castTime = e.secret }; e.I.ObserveTimer(e.scheduler, 1)
    e.I.ObserveTimer(e.scheduler, e.secret); assert(#e.timers == 0)
end)
Case("aura registration deduplicates and supports each trigger and party unit", function()
    local e = Fixture(); local r = e:rule("auraSound")
    e.I.Save(nil, r); e.I.Refresh(); assert(#e.added == 1 and e.added[1].trigger == 0)
    e.I.Save(nil, r); assert(#e.added == 1)
    local other = e:rule("auraSound"); other.trigger.auraEvent = "Removed"; other.trigger.target = "party"
    e.I.Save(nil, other); assert(#e.added == 5 and e.added[2].trigger == 2)
    other = e:rule("auraSound"); other.trigger.auraEvent = "ApplicationsIncreased"
    e.I.Save(nil, other); assert(#e.added == 6 and e.added[6].trigger == 1)
end)
Case("aura changes defer through combat then remove disabled rules", function()
    local e = Fixture(); local r = e:rule("auraSound"); r.healerReminder = true
    e.I.Save(nil, r); e.combat = true; e.healerOff = true; e.I.Refresh()
    assert(#e.removed == 0 and e.I.auraStatus:find("pending"))
    e.combat = false; e.I.Refresh(); assert(#e.removed == 1)
end)
Case("bundled voices resolve and register without SharedMedia", function()
    local e = Fixture()
    local file = assert(io.open(root .. "/NaowhUI_SmartReminders_Widgets.lua", "rb"))
    local source = file:read("*a"); file:close()
    local start = assert(source:find("local bundledVoices =", 1, true))
    local chunk = assert(loadstring("local ns = ...; local UI = ns.UI; " .. source:sub(start)))
    setfenv(chunk, e.env); chunk(e.ns)
    local paths, names, order = e.ns.UI.BuildAlertSoundTables()
    assert(#order == 4 and order[1] == "none")
    assert(e.ns.UI.SoundPathFor("none") == nil and e.ns.UI.SoundPathFor("missing") == nil)
    for index = 2, #order do
        local key = order[index]
        assert(names[key]:find("Voice:", 1, true))
        assert(e.ns.UI.SoundPathFor(key) == paths[key])
        local relative = assert(paths[key]:match("NaowhSmartReminders\\(.+)$")):gsub("\\", "/")
        local sound = assert(io.open(root .. "/" .. relative, "rb"))
        assert(sound:read(4) == "OggS"); sound:close()
        local r = e:rule("auraSound"); r.display.sound = key
        assert(e.I.Save(nil, r))
        assert(e.added[index - 1].info.soundFileName == paths[key])
    end
end)
Case("aura profile and instance changes clear registrations", function()
    local e = Fixture(); e.I.Save(nil, e:rule("auraSound"))
    e.kind = "none"; e.I.Refresh(); assert(#e.removed == 1)
    e.kind = "party"; e.I.Refresh(); assert(#e.added == 2)
    e.db.integrationRules = {}; e.I.Refresh(); assert(#e.removed == 2)
end)
Case("malformed rules are rejected, and a spec may hold as many good ones as it likes", function()
    local e = Fixture(); local r = e:rule(); r.trigger.spellID = 0/0; assert(not e.I.Save(nil,r))
    r=e:rule("auraSound"); r.display.sound="none"; assert(not e.I.Save(nil,r))
    -- Well past the cap this addon used to impose on itself. The client decides what it
    -- will register, and says so; the addon does not decide for it in advance.
    for i = 1, 120 do assert(e.I.Save(nil, e:rule()), "rule " .. i) end
    local n = 0
    for _ in pairs(e.I.Rules(false)) do n = n + 1 end
    assert(n == 120)
end)
Case("the retired cast switches are still validated, so old rules still load", function()
    local e = Fixture()
    local r = e:rule(); r.display.castRepeat = "no"
    assert(not e.I.Save(nil, r))
    r = e:rule(); r.display.castAudio = 1
    assert(not e.I.Save(nil, r))
    r = e:rule(); r.display.castRepeat = false; r.display.castAudio = true
    assert(e.I.Save(nil, r))
end)
Case("settings refresh and resync do not replay an already delivered prediction", function()
    local e=Fixture(); e.I.Save(nil,e:rule()); e:timer(1,10); e:advance(5)
    assert(#e.shown==1)
    e.I.Refresh(); e.scheduler.active[1].castTime=12; e.I.ObserveTimer(e.scheduler,1)
    e:advance(7); assert(#e.shown==1)
    e.scheduler.active[1]=nil; e.hooks._RemoveActiveTimerByID(e.scheduler,1)
    e:timer(2,20); e:advance(15); assert(#e.shown==2)
end)
Case("shared packs validate integration rules, IDs and size before import", function()
    local e=Fixture()
    local f=assert(io.open(root.."/NaowhUI_SmartReminders_Packs.lua","rb"))
    local source=f:read("*a"); f:close()
    local first=assert(source:find("local SECTIONS =",1,true))
    local last=assert(source:find("-- LibSerialize's Deserialize",first,true))
    local chunk=assert(loadstring(source:sub(first,last-1).."\nreturn ValidData"))
    e.env.ns=e.ns; setfenv(chunk,e.env); local valid=chunk()
    local data={ integrationRules={ ["250"]={ i1=e:rule(), i2=e:rule("auraSound") } } }
    assert(valid(data))
    data.integrationRules["250"].i2.trigger.mapID="1877"; assert(not valid(data))
    data.integrationRules["250"].i2.trigger.mapID=1877
    data.integrationRules["250"][1]=e:rule(); assert(not valid(data))
    data.integrationRules["250"][1]=nil
    -- A pack may carry far more than a spec used to be allowed, but not an unbounded table.
    for i=3,120 do data.integrationRules["250"]["i"..i]=e:rule() end
    assert(valid(data), "a large but sane pack is still a valid pack")
    for i=121,502 do data.integrationRules["250"]["i"..i]=e:rule() end
    assert(not valid(data), "past the sanity bound it is refused")
end)
Case("Stoneform follows cooldown events in combat without re-registering", function()
    local e = Fixture(); local r = e:rule("auraSound"); r.display.sound = "voice:stoneform-ready"
    assert(e.I.Save(nil, r)); assert(e.muted == false and e.registered.SPELL_UPDATE_COOLDOWN)
    e.combat = true; e.cooldown.isActive = true
    e.event(nil, "SPELL_UPDATE_COOLDOWN", 20594); assert(e.muted == true)
    local calls = #e.muteCalls
    e.event(nil, "SPELL_UPDATE_COOLDOWN", 123); assert(#e.muteCalls == calls)
    e.cooldown.isActive = false; e.event(nil, "SPELL_UPDATE_COOLDOWN", 20594)
    assert(e.muted == false and #e.added == 1 and #e.removed == 0)
    e.I.Refresh(); assert(e.muted == false and #e.added == 1)
end)
Case("Stoneform fails silent for unknown, dead, unusable and secret readiness", function()
    for _, what in ipairs({ "unknown", "dead", "unusable", "secret", "missing", "held" }) do
        local e = Fixture(); local r = e:rule("auraSound"); r.display.sound = "voice:stoneform-ready"
        e.I.Save(nil, r)
        if what == "unknown" then e.known = false
        elseif what == "dead" then e.dead = true
        elseif what == "unusable" then e.usable = false
        elseif what == "secret" then e.usable = e.secret
        elseif what == "missing" then e.cooldown = nil
        else e.cooldown.isEnabled = false end
        e.event(nil, "SPELL_UPDATE_USABLE"); assert(e.muted == true, what)
    end
end)
Case("Stoneform preview never unmutes the registered file", function()
    local e = Fixture(); local r = e:rule("auraSound"); r.display.sound = "voice:stoneform-ready"
    e.cooldown.isActive = true; e.I.Save(nil, r)
    local calls = #e.muteCalls; e.I.Preview(r)
    assert(e.previewKey == "voice:stoneform-preview" and e.muted and #e.muteCalls == calls)
end)
Case("Stoneform disable in combat silences stale rules until cleanup", function()
    local e = Fixture(); local r = e:rule("auraSound"); r.display.sound = "voice:stoneform-ready"
    e.I.Save(nil, r); e.combat = true; e.db.enabled = false; e.I.Refresh()
    assert(e.muted and not e.registered.SPELL_UPDATE_COOLDOWN and #e.removed == 0)
    e.combat = false; e.I.Refresh()
    assert(e.muted == false and #e.removed == 1)
end)
Case("Stoneform rejects party rules and remains idle for ordinary sounds", function()
    local e = Fixture(); e.I.Save(nil, e:rule("auraSound"))
    assert(#e.muteCalls == 0 and not e.registered.SPELL_UPDATE_COOLDOWN)
    local r = e:rule("auraSound"); r.display.sound = "voice:stoneform-ready"; r.trigger.target = "party"
    assert(not e.I.Save(nil, r))
end)
Case("Shadowmeld gates on its own racial, and the two are independent", function()
    local e = Fixture()
    local stone = e:rule("auraSound"); stone.display.sound = "voice:stoneform-ready"
    local meld = e:rule("auraSound"); meld.display.sound = "voice:shadowmeld-ready"
    meld.trigger.spellID = 456
    assert(e.I.Save(nil, stone)); assert(e.I.Save(nil, meld))
    assert(#e.added == 2 and e.registered.SPELL_UPDATE_COOLDOWN)

    local function MutedFor(file)
        local state
        for _, path in ipairs(e.muteCalls) do
            if path == file then state = e.mutedBy[path] end
        end
        return state
    end
    -- Shadowmeld on cooldown, Stoneform still up: only one of the two goes quiet.
    e.cooldowns = { [58984] = { isActive = true, isEnabled = true } }
    e.event(nil, "SPELL_UPDATE_COOLDOWN")
    assert(MutedFor("shadowmeld-ready.ogg") == true, "Shadowmeld should be muted")
    assert(MutedFor("stoneform-ready.ogg") == false, "Stoneform should still be audible")
    -- And back again when it comes off cooldown.
    e.cooldowns = nil
    e.event(nil, "SPELL_UPDATE_COOLDOWN")
    assert(MutedFor("shadowmeld-ready.ogg") == false)
end)
Case("Shadowmeld preview uses its own file and rejects a party rule", function()
    local e = Fixture()
    local r = e:rule("auraSound"); r.display.sound = "voice:shadowmeld-ready"
    e.cooldown.isActive = true
    assert(e.I.Save(nil, r))
    local calls = #e.muteCalls
    e.I.Preview(r)
    assert(e.previewKey == "voice:shadowmeld-preview" and #e.muteCalls == calls,
        "the preview must not touch the registered file")
    local party = e:rule("auraSound")
    party.display.sound = "voice:shadowmeld-ready"; party.trigger.target = "party"
    assert(not e.I.Save(nil, party), "a racial you cast on yourself cannot answer for a party debuff")
end)
Case("a racial with nothing left registered hands its file back unmuted", function()
    local e = Fixture()
    local r = e:rule("auraSound"); r.display.sound = "voice:shadowmeld-ready"
    e.cooldown.isActive = true
    e.I.Save(nil, r)
    assert(e.mutedBy["shadowmeld-ready.ogg"] == true)
    e.db.integrationRules = {}
    e.I.Refresh()
    assert(e.mutedBy["shadowmeld-ready.ogg"] == false, "it must not stay silenced for everything else")
end)
Case("forced restrictions defer registration without combat lockdown", function()
    for _, kind in ipairs({ 0, 1 }) do
        local e = Fixture(); e.restrictions[kind] = 2
        e.I.Save(nil, e:rule("auraSound")); assert(#e.added == 0 and e.I.auraStatus:find("pending"))
        e.restrictions[kind] = nil
        e.event(nil, "ADDON_RESTRICTION_STATE_CHANGED", kind, 0); assert(#e.added == 1)
    end
end)
-- Copy From Spec on the Trash & Debuff page. Rules are stored per spec, so a second spec
-- starts empty and the whole dungeon has to be rebuilt by hand without this.
local function CopyFixture()
    local e = Fixture()
    e.ns.SpecName = function(k) return "Spec " .. tostring(k) end
    e.db.integrationRules["581"] = {}
    return e
end
local function RuleCount(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
Case("rules copy across as independent entries on fresh uids", function()
    local e = CopyFixture()
    local src = e:rule()
    src.name = "Knock"
    e.db.integrationRules["581"] = { i1 = src }
    e.db.integrationRules["250"] = { i1 = e:rule("auraSound") }
    local copied, skipped = e.I.CopyRulesFromSpec("581", "exboss")
    assert(copied == 1 and skipped == 0)
    local mine = e.db.integrationRules["250"]
    assert(RuleCount(mine) == 2 and mine.i1.trigger.type == "auraSound")
    local landed
    for _, r in pairs(mine) do if r.name == "Knock" then landed = r end end
    assert(landed and landed ~= src and landed.trigger ~= src.trigger and landed.display ~= src.display)
    assert(landed.trigger.spellID == 123 and landed.display.text == "Defensive")
    assert(RuleCount(e.db.integrationRules["581"]) == 1, "the source spec keeps its own")
end)
Case("a rule this spec already has for that ability is left alone", function()
    local e = CopyFixture()
    e.db.integrationRules["581"] = { i1 = e:rule() }
    e.db.integrationRules["250"] = { i1 = e:rule() }
    local copied, skipped = e.I.CopyRulesFromSpec("581", "exboss")
    assert(copied == 0 and skipped == 1)
    assert(RuleCount(e.db.integrationRules["250"]) == 1)
end)
Case("same spell on a different map or aura event is its own rule", function()
    local e = CopyFixture()
    local other = e:rule("auraSound")
    other.trigger.auraEvent = "Removed"
    local elsewhere = e:rule()
    elsewhere.trigger.mapID = 2000
    e.db.integrationRules["581"] = { i1 = other, i2 = elsewhere }
    e.db.integrationRules["250"] = { i1 = e:rule("auraSound"), i2 = e:rule() }
    -- One of each kind, so each half is copied by the page that owns it.
    local copied, skipped = e.I.CopyRulesFromSpec("581", "auraSound")
    assert(copied == 1 and skipped == 0, "a different aura event is its own rule")
    copied, skipped = e.I.CopyRulesFromSpec("581", "exboss")
    assert(copied == 1 and skipped == 0, "and so is a different map")
    assert(RuleCount(e.db.integrationRules["250"]) == 4)
end)
Case("each page copies only its own kind of rule", function()
    local e = CopyFixture()
    local trash = e:rule()
    local debuff = e:rule("auraSound")
    debuff.trigger.spellID = 456
    e.db.integrationRules["581"] = { i1 = trash, i2 = debuff }

    -- The trash page's button takes trash rules and leaves the debuff alert behind.
    local copied = e.I.CopyRulesFromSpec("581", "exboss")
    assert(copied == 1)
    local mine = e.db.integrationRules["250"]
    assert(RuleCount(mine) == 1)
    for _, r in pairs(mine) do assert(r.trigger.type == "exboss") end

    -- The debuff page's button takes the other one.
    copied = e.I.CopyRulesFromSpec("581", "auraSound")
    assert(copied == 1 and RuleCount(mine) == 2)
    local kinds = {}
    for _, r in pairs(mine) do kinds[r.trigger.type] = true end
    assert(kinds.exboss and kinds.auraSound)
end)
Case("the picker counts only the kind the page asked about", function()
    local e = CopyFixture()
    local debuff = e:rule("auraSound")
    debuff.trigger.spellID = 456
    e.db.integrationRules["581"] = { i1 = e:rule(), i2 = e:rule(), i3 = debuff }
    local trashSpecs = e.I.SpecsWithRules("exboss")
    assert(#trashSpecs == 1 and trashSpecs[1].total == 2)
    local debuffSpecs = e.I.SpecsWithRules("auraSound")
    assert(#debuffSpecs == 1 and debuffSpecs[1].total == 1)
end)
Case("a spec with only the other kind is not offered at all", function()
    local e = CopyFixture()
    e.db.integrationRules["581"] = { i1 = e:rule("auraSound") }
    assert(#e.I.SpecsWithRules("exboss") == 0, "nothing to copy means nothing to pick")
    assert(#e.I.SpecsWithRules("auraSound") == 1)
end)
Case("two callouts on one ability at different warning times both come across", function()
    local e = CopyFixture()
    local early, late = e:rule(), e:rule()
    early.trigger.timeleft, late.trigger.timeleft = 8, 2
    e.db.integrationRules["581"] = { i1 = early, i2 = late }
    local copied, skipped = e.I.CopyRulesFromSpec("581", "exboss")
    assert(copied == 2 and skipped == 0)
    assert(RuleCount(e.db.integrationRules["250"]) == 2)
    -- And a repeat press still recognises both as already here.
    local again, skippedAgain = e.I.CopyRulesFromSpec("581", "exboss")
    assert(again == 0 and skippedAgain == 2)
end)
Case("a copy is no longer cut short by a cap", function()
    local e = CopyFixture()
    local src, mine = {}, {}
    for i = 1, 5 do
        local r = e:rule(); r.trigger.spellID = 1000 + i
        src["i" .. i] = r
    end
    for i = 1, 30 do
        local r = e:rule(); r.trigger.spellID = 2000 + i
        mine["i" .. i] = r
    end
    e.db.integrationRules["581"], e.db.integrationRules["250"] = src, mine
    local copied, skipped = e.I.CopyRulesFromSpec("581", "exboss")
    assert(copied == 5 and skipped == 0, "every source rule comes across")
    assert(RuleCount(e.db.integrationRules["250"]) == 35)
end)
Case("an invalid source rule is passed over", function()
    local e = CopyFixture()
    local bad = e:rule(); bad.display.dur = 99
    local good = e:rule(); good.trigger.spellID = 999
    e.db.integrationRules["581"] = { i1 = bad, i2 = good }
    local copied = e.I.CopyRulesFromSpec("581", "exboss")
    assert(copied == 1 and RuleCount(e.db.integrationRules["250"]) == 1)
end)
Case("the picker lists other specs with counts and never this one", function()
    local e = CopyFixture()
    e.db.integrationRules["250"] = { i1 = e:rule() }
    e.db.integrationRules["581"] = { i1 = e:rule(), i2 = e:rule("auraSound") }
    e.db.integrationRules["104"] = {}
    -- Two rules saved there, but only one of the kind this picker was opened for.
    local specs = e.I.SpecsWithRules("exboss")
    assert(#specs == 1 and specs[1].key == "581" and specs[1].total == 1)
end)
Case("copying from a spec with nothing saved changes nothing", function()
    local e = CopyFixture()
    e.db.integrationRules["250"] = { i1 = e:rule() }
    local copied, skipped = e.I.CopyRulesFromSpec("999", "exboss")
    assert(copied == 0 and skipped == 0)
    assert(RuleCount(e.db.integrationRules["250"]) == 1)
end)

Case("a trash rule answers with the spec's preset unless it carries a line of its own", function()
    local e = Fixture()
    local file = assert(io.open(root .. "/NaowhUI_SmartReminders.lua", "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n"); file:close()
    local slice = assert(source:match("function ns.IntegrationPreset%b()%s*.-\nend"))
    local presets = { defensives = { list = { 48707 } } }
    local env = setmetatable({ specID = 250,
        PresetsTable = function() return next(presets) and presets or nil end,
        ActivePresetKey = function() return next(presets) end }, { __index = _G })
    local ns = {}
    local chunk = assert(loadstring("local ns = ...; " .. slice))
    setfenv(chunk, env); chunk(ns)
    local function rule(kind, text, preset)
        return { preset = preset, trigger = { type = kind }, display = { text = text } }
    end

    -- A blank line is the question, not an answer: this page has had no text box since
    -- these moved to presets, so nothing new can carry one.
    assert(ns.IntegrationPreset(rule("exboss", "")) == "defensives")
    assert(ns.IntegrationPreset(rule("exboss", "", "defensives")) == "defensives")
    -- A key this spec does not have, which is what a pack built on another one carries.
    -- The fire path takes a key as an override with no fall-through, so this used to be a
    -- rule that silently never called anything.
    assert(ns.IntegrationPreset(rule("exboss", "", "p7")) == "defensives")
    -- A line somebody typed while the box still existed still owns the callout.
    assert(ns.IntegrationPreset(rule("exboss", "Move out")) == nil)
    assert(ns.IntegrationPreset(rule("exboss", "Move out", "p7")) == "p7")
    -- A debuff alert is not a defensive callout and must never pick one up.
    assert(ns.IntegrationPreset(rule("auraSound", "")) == nil)
    -- A spec with no presets at all stays silent rather than erroring.
    presets = {}
    assert(ns.IntegrationPreset(rule("exboss", "")) == nil)
end)

Case("the minted trash line is cleared on load, and only that line", function()
    local file = assert(io.open(root .. "/NaowhUI_SmartReminders.lua", "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n"); file:close()
    local slice = assert(source:match("local function TRDB%b()%s*.-\nend"))
    local saved = { tankReminder = {
        integrationRules = {
            ["250"] = {
                i1 = { trigger = { type = "exboss" }, display = { text = "Use a defensive" } },
                i2 = { trigger = { type = "exboss" }, display = { text = "Move out" } },
                i3 = { trigger = { type = "exboss" }, display = { text = "" }, preset = "p1" },
                i4 = { trigger = { type = "auraSound" }, display = { text = "Use a defensive" } },
            },
            ["577"] = { i5 = { trigger = { type = "exboss" }, display = { text = "Use a defensive" } } },
            ["62"] = "not a table",
        },
        callouts = { [48707] = "Use AMS" },
    } }
    local env = setmetatable({ DEFAULTS = { leadTime = 3 },
        prepared = setmetatable({}, { __mode = "k" }),
        ns = { SettingsRoot = function() return saved end } }, { __index = _G })
    local chunk = assert(loadstring(slice .. "  return TRDB"))
    setfenv(chunk, env)
    local t = chunk()()
    local r = t.integrationRules
    -- The editor minted this line; nobody could have typed it, so it is not content.
    assert(r["250"].i1.display.text == "")
    assert(r["577"].i5.display.text == "", "every spec bucket is walked, not just the first")
    -- A line saved while the text box still existed is the one thing that must survive.
    assert(r["250"].i2.display.text == "Move out")
    assert(r["250"].i3.display.text == "" and r["250"].i3.preset == "p1", "already converted")
    -- A debuff alert is not a trash rule and shares none of this.
    assert(r["250"].i4.display.text == "Use a defensive")
    assert(r["62"] == "not a table", "a malformed bucket is stepped over rather than indexed")
    -- The migrations beside it still run, and the defaults still fill.
    assert(t.callouts[48707] == "AMS" and t.leadTime == 3)
end)
Case("a trash callout already covered by a running defensive is skipped", function()
    local file = assert(io.open(root .. "/NaowhUI_SmartReminders.lua", "rb"))
    local source = file:read("*a"):gsub("\r\n", "\n"); file:close()
    local db, shown, logged, covered = {}, {}, {}, true
    local env = setmetatable({ specID = 250,
        PresetsTable = function() return { defensives = { list = { 48707 } } } end,
        ActivePresetKey = function() return "defensives" end,
        TRDB = function() return db end,
        ShowOnAlert = function(opts) shown[#shown + 1] = opts end,
        AppendLog = function(entry) logged[#logged + 1] = entry end,
        CoveredByActiveDefensive = function(fp, preset)
            assert(fp == "authored" and preset == "defensives")
            if covered then return true, 48792, "cast" end
            return false
        end }, { __index = _G })
    local ns = {}
    local chunk = assert(loadstring("local ns = ...; "
        .. assert(source:match("function ns.IntegrationPreset%b()%s*.-\nend")) .. "\n"
        .. assert(source:match("function ns.DisplayIntegrationReminder%b()%s*.-\nend"))))
    setfenv(chunk, env); chunk(ns)
    local rule = { trigger = { type = "exboss", spellID = 123 }, display = { text = "", dur = 3 } }
    ns.DisplayIntegrationReminder(rule)
    assert(#shown == 0 and #logged == 1)
    assert(logged[1].kind == "skip" and logged[1].sid == 48792 and logged[1].tankSid == 123)
    -- The editor's Preview always shows.
    ns.DisplayIntegrationReminder(rule, true)
    assert(#shown == 1)
    db.coveredSkip = false
    ns.DisplayIntegrationReminder(rule)
    assert(#shown == 2 and #logged == 1)
    db.coveredSkip, covered = nil, false
    ns.DisplayIntegrationReminder(rule)
    assert(#shown == 3 and shown[3].preset == "defensives")
    -- A rule with its own line and no preset never asked for a defensive.
    covered = true
    ns.DisplayIntegrationReminder({ trigger = { type = "exboss", spellID = 123 },
        display = { text = "Move out", dur = 3 } })
    assert(#shown == 4 and shown[4].preset == nil)
end)
print(count .. " integration regressions passed")
