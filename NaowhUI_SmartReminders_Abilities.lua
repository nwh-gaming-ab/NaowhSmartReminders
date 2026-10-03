-------------------------------------------------------------------------------
--  NaowhUI_SmartReminders_Abilities.lua -- tank busters the game does not flag.
--
--  GENERATED. Regenerate rather than hand-editing.
--
--  This addon reads everything else out of the player's own client on purpose, and this
--  file is the one deliberate exception. The reason is measured, not assumed.
--
--  The engine-played callout is registered against every catalogue ability carrying
--  Blizzard's TankRole bit. Checked against a live 870-event catalogue: of the 31 boss
--  tank busters in this season's pool, 23 exist in that catalogue and only 13 carry the
--  bit. So the bit alone is correctly silent on nearly half of them, and correct silence
--  is indistinguishable from a broken feature from where the player is sitting.
--
--  So this list is ADDITIVE and never a replacement. An ability is called if Blizzard
--  says so OR this list does, which means the feature keeps working unchanged on content
--  this file has never heard of.
--
--  Keyed by SPELL ID, not by encounterEventID. Event ids are a client-side index that can
--  be reallocated between builds; a spell id is stable, and the catalogue is plain so the
--  join happens at runtime on the player's own client.
--
--  The value is the DAMAGE TYPE rather than a flag, because which defensive helps depends
--  on whether the hit is physical or magical, and a later version can use it to choose.
--
--  Ability classification is derived from Tactyks' public Season 2 dungeon spreadsheet.
--  Spell ids and names are Blizzard's own.
-------------------------------------------------------------------------------
local ns = _G.NaowhUITankReminder
if not ns then return end

ns.TANK_ABILITIES = {
    -- Every id below was audited against the installed BigWigs/LittleWigs and DBM module
    -- source on 2026-08-26. Ids NEITHER mod ever broadcasts were removed (Frigid Shard
    -- 372808, Chaos Barrage 1230298, Warden's Wrath 1239821, Forceful Slam 1297797,
    -- Heart Attack 268007, Tainted Strike 1303446 -- aura-sound only in BigWigs, a TODO
    -- in DBM -- and Searing Beak's aura twin 466091), since the engine can only fire on
    -- a broadcast key. Do not re-add them from the sheet without rechecking the modules.
    [265910] = "Physical",   -- The Golden Serpent: Tail Thrash
    [266237] = "Physical",   -- The Council of Tribes: Debilitating Backhand
    [268586] = "Physical",   -- Dazar, The First King: Blade Combo
    [372858] = "Mixed",   -- Kokia Blazehoof: Searing Blows
    [381512] = "Mixed",   -- Kyrakka and Erkhart Stormvein: Stormslam
    [473898] = "Physical",   -- Xathuux the Annihilator: Legion Strike
    [1222642] = "Magical",   -- Atroxus: Hulking Claw
    [1222795] = "Mixed",   -- Zaen Bladesorrow: Envenom
    [1234753] = "Mixed",   -- Lightblossom Trinity: Bedrock Slam
    [1247685] = "Mixed",   -- Ziekket: Thornspike
    [1311804] = "Mixed",   -- Adderis and Aspix: Overload (was 1288428; BigWigs bars 1311804)
    [1290797] = "Mixed",   -- Merektha: Lightning Bite
    -- 1296220 (Rav'i: Triple Shot) deliberately NOT here. Blizzard's own Dungeon Journal
    -- flags it Healer, not Tank -- visible on the boss page, which reads the journal
    -- directly -- and everything independently found about it this week agrees: it fires
    -- as a PersonalMessage BigWigs targets by the mechanic itself, never by threat, and
    -- it was already pulled out of the owner-slot map for exactly that reason. Being on
    -- this list is what put the wrong |cff0091ed[tank hit]|r tag on it in the Add Ability
    -- picker -- and, more than cosmetic, is what registered the tank-hit SOUND for it too
    -- (NaowhUI_SmartReminders.lua, RegisterEventSounds's "curated" check): anyone with that
    -- feature on has been hearing a tank-incoming cue for a healer mechanic.
    [1297017] = "Magical",   -- Taz'Rah: Void Blast
    [1298949] = "Physical",   -- The Writhing Coil: Tail Scythe
    [1301350] = "Physical",   -- Zul'jan: Chop Down
    -- Dazar's Hunting Leap (269230) and Savage Maul (1303488) are deliberately NOT here,
    -- the same call already made for Hollowing Strikes below. Both are tank BLEEDS, not
    -- busters: each was originally listed by its aura id (1303039, 1303490), LittleWigs
    -- tags exactly one Dazar ability "TANK_HEALER" and it is Blade Combo, and DBM makes
    -- only Blade Combo a NewSpecialWarningDefensive while these two are plain
    -- NewCountAnnounce backed by a "bleedyou" aura sound. Neither mod thinks they warrant
    -- a cooldown.
    --
    -- Live evidence they must not auto-fire: on a real pull Savage Maul called at 10:57:35
    -- and Blade Combo at 10:57:37, so the tank pressed a defensive for the first and was
    -- immediately told to press a second one for the hit two seconds later. Reported as
    -- "it's asking me to press my defensives twice back to back" on Blade Combo. Both stay
    -- available from Setup's own per-boss checkbox for anyone who wants them.
    [1311923] = "Magical",   -- Charonus: Dark Waves

    -- Marked as tank hits in publicly available community boss research; damage
    -- type not recorded there, so it is Unknown until observed.
    [466064] = "Unknown",   -- Emberdawn: Searing Beak
    [1241692] = "Unknown",   -- Vorasius: Shadowclaw Slam
    [467620] = "Unknown",   -- Commander Kro'luk: Rampage
    [472888] = "Unknown",   -- Derelict Duo: Bone Hack
    [1247937] = "Unknown",   -- Nysarra: Void Gash
    [1251023] = "Unknown",   -- Rak'tul: Spiritbreaker
    [1251554] = "Unknown",   -- Vor'daza: Drain Soul
    [1253950] = "Unknown",   -- Lothraxion: Searing Rend (Nexus Point Xenas)
    -- LittleWigs carries this one as an aura option only (soundOnApplied, no bar), so it
    -- never reaches the engine from that side -- but DBM runs a real 26s CD timer for it
    -- under the same id, and its note is CL.tank_hit outright. DBM-driven only, the mirror
    -- of 1253950 above, the same boss's other Searing Rend, being BigWigs-only.
    [1255335] = "Unknown",   -- Lothraxion: Searing Rend
    [1268562] = "Unknown",   -- Nymrissa Wavecaller: Water Jet (Mythic only)
    [1267049] = "Unknown",   -- Midnight Falls: Heaven's Lance
    [1221781] = "Unknown",   -- Rotmire: Putrid Fist
    [1233787] = "Unknown",   -- Crown of the Cosmos: Dark Hand
    [1245645] = "Unknown",   -- Vaelgor & Ezzorak: Rakfang
    [1246461] = "Unknown",   -- Crown of the Cosmos: Rift Slash
    [1246736] = "Unknown",   -- Lightblinded Vanguard: Judgement
    [1251857] = "Unknown",   -- Lightblinded Vanguard: Judgement
    [1262623] = "Unknown",   -- Vaelgor & Ezzorak: Nullbeam
    [1265131] = "Unknown",   -- Vaelgor & Ezzorak: Vaelwing
    [1280458] = "Unknown",   -- Vaelgor & Ezzorak: Grappling Maw
    [1280935] = "Unknown",   -- Vashnik the Malignant: Dripping Fangs
    [1284458] = "Unknown",   -- Entombed Sentinels: Empowering Slam
    [1284487] = "Unknown",   -- Entombed Sentinels: Bloodvenom Injection
    [1288538] = "Unknown",   -- The Twin Fangs: Stone Breaker
    [1295854] = "Unknown",   -- The Lost Explorers: Shredding Shards
    [1250803] = "Unknown",   -- Fallen-King Salhadaar: Shattering Twilight
    [1260763] = "Unknown",   -- Belo'ren, Child of Al'ar: Guardian's Edict
    [1277025] = "Unknown",   -- Sszorak: Apex Predator
    [1286573] = "Unknown",   -- The Coiled Altar: Soul Sever
    [1299680] = "Unknown",   -- The Coiled Altar: Sever
    [1307279] = "Unknown",   -- The Coiled Altar: Blighted Sever
    -- 1284103 (the debuff aura, BigWigs' own soundOnApplied trigger) never reaches
    -- BigWigs_Message/StartBar -- confirmed against BigWigs_TheVenomousAbyss/Nekzali.lua.
    -- The bar it actually fires (self:Bar) is keyed by 1292036, so that is the id this
    -- addon has to match against.
    [1292036] = "Unknown",   -- Nek'zali the Soulcoiler: Possession Barrage
    -- Hollowing Strikes (1284110, stacking debuff) deliberately NOT here: still a real
    -- tank mechanic (its own Tank role tag in Setup comes straight off the live journal
    -- scrape, independent of this table), just default OFF rather than auto-enabled --
    -- flip it on per-boss from Setup's own checkbox if wanted.

    -- Tank hits the community modules gate on a tank role check in code rather than
    -- flagging on the ability, which is why the sheet-derived rows above never carried
    -- them. Found by auditing every Midnight party module for that gate (2026-08-20)
    -- after Den of Nalorakk called nothing at all for a whole dungeon.
    [472662] = "Unknown",   -- The Restless Heart: Tempest Slash
    [474496] = "Unknown",   -- Arcanotron Custos: Repulsing Slam
    [1243569] = "Unknown",   -- Nalorakk: Overwhelming Onslaught
    [1266480] = "Unknown",   -- Murojin and Nekraxx: Flanking Spear
    [1280113] = "Unknown",   -- Degentrius: Hulking Fragment
    -- Classified but NOT fingerprintable from the modules: Ula'tek drives this off
    -- Blizzard event ids rather than bar durations, so there is no duration to key on.
    -- Needs /nutank learn then /nutank tank on a real pull.
    [1298367] = "Unknown",   -- Ula'tek: Mother's Wrath
}

-- BigWigs broadcasts its stable option key, which is not always the id the Dungeon
-- Journal lists for the same mechanic -- and Setup's per-ability store is keyed by the
-- journal id. Broadcast key -> journal id for the confirmed mismatches, so the engine
-- can still find the player's Setup choices for them.
ns.BOSSMOD_KEY_TO_JOURNAL = {
    [1292036] = 1284103,   -- Nek'zali the Soulcoiler: Possession Barrage
}

-- DBM keys some of the same warnings by a different spell id than BigWigs, usually the
-- debuff/aura id (Possession Barrage's is deliberate on DBM's side: 1292036 has no
-- tooltip, their module says so). The engine, the curated list and Setup's rows all
-- speak BigWigs ids, so DBM timer ids are normalized through this map before
-- ns.HandleBigWigsAbility. DBM's Lothraxion module carries 1255335 but not 1253950, so
-- 1253950 stays BigWigs-only.
ns.DBM_TO_BIGWIGS = {
    [1241836] = 1241692,   -- Vorasius: Shadowclaw Slam
    [1288484] = 1288538,   -- The Twin Fangs: Stone Breaker
    [1253024] = 1250803,   -- Fallen-King Salhadaar: Shattering Twilight
    [1287227] = 1307279,   -- The Coiled Altar: Blighted Sever
    [1284103] = 1292036,   -- Nek'zali the Soulcoiler: Possession Barrage
}

-- Some BigWigs bars are driven purely by the encounter timeline (a scripted countdown
-- matched by rounded duration, ENCOUNTER_TIMELINE_EVENT_ADDED) rather than any spell
-- cast -- confirmed against BigWigs_TheVenomousAbyss/TwinFangs.lua and CoiledAltar.lua,
-- both self:CDBar(barInfo.key, ...) off duration matching alone, no cast involved at
-- all. castSourceGUID (fed only by SPELL_CAST_START/SUCCESS) can never learn a caster
-- for these, so TankingCaster fell back to "tanking ANY boss" -- wrong the moment two
-- boss units are alive at once and each tank holds a different one (reported live on
-- both The Twin Fangs and The Coiled Altar P2/P3).
--
-- The boss SLOT, not the npcID: UnitGUID is SecretWhenUnitIdentityRestricted, so in a
-- raid it hands back a secret for boss1-5 and nameplate units alike and nothing can be
-- identified by GUID at all. An npcID-keyed version of this map shipped first and
-- missed on every single callout of a live Coiled Altar night, both phases, both
-- severs. Slot tokens are what BigWigs and DBM gate their own tank warnings on for
-- exactly these abilities, and they need no identity read.
ns.TANK_ABILITY_OWNER_UNIT = {
    -- boss2 per DBM's TheTwinFangs ("--ALways boss2, unless boss1 is dead" on the same
    -- Stone Breaker warning); Caustic Deluge is its boss1 counterpart.
    [1288538] = 2,   -- The Twin Fangs: Stone Breaker (Ithraz)
    -- BigWigs' GetOptions files Caustic Deluge under its "-- Vexhul" heading, leaving
    -- Ithraz boss2 above; its own Message carries "always the tank?" beside the Blizzard
    -- message it stops. Reported live: called for both tanks on every cast.
    [1289192] = 1,   -- The Twin Fangs: Caustic Deluge (Vexhul)

    -- BigWigs registers Malacrass's Soulbinding channel on "boss2" from OnEncounterStart,
    -- leaving Zul'jan boss1.
    [1299680] = 1,   -- The Coiled Altar: Sever (Zul'jan)
    [1286573] = 2,   -- The Coiled Altar: Soul Sever (Hex Lord Malacrass)
    -- BigWigs' GetOptions files Blighted Sever under its "-- Zul'jan" Stage 3 heading,
    -- next to Defilement of the Coiled Altar, which its own journal-section map keys to
    -- Zul'jan (-35063); the Malacrass half of that heading lists no sever at all.
    [1307279] = 1,   -- The Coiled Altar: Blighted Sever (Zul'jan)

    -- BigWigs' Explorers.lua names the slots outright: boss1 Gebbo, boss3 Nama, boss4
    -- Iku. DBM gates the same ability on IsTanking("player","boss4").
    [1295854] = 4,   -- The Lost Explorers: Shredding Shards (Scrollsage Iku)

    -- BigWigs gates each Message with ThreatTarget("player","boss1"/"boss2"), but
    -- self:CDBar -- what actually drives BigWigs_StartBar, the broadcast the engine
    -- schedules off -- runs unconditionally, so both tanks get a bar either way.
    [1284458] = 1,   -- Entombed Sentinels: Empowering Slam (Breath of Ula'tek)
    [1284487] = 2,   -- Entombed Sentinels: Bloodvenom Injection (Blood of Ula'tek)

    -- Ula'tek is the only mob BigWigs enables on and every unit event in the module is
    -- boss1, but the fight puts big adds in the other boss frames. Tanking one of those
    -- satisfied TankingSomeBoss, so Mother's Wrath -- flagged TANK in BigWigs' own
    -- options -- called at the tank who did not have the boss. Reported live.
    [1298367] = 1,   -- Ula'tek: Mother's Wrath

    -- Swept from the BigWigs and LittleWigs modules for the whole pool. One boss unit in
    -- the encounter means the ability is boss1's, and an add holding another frame is not
    -- the thing being called -- the Ula'tek case above, which the fallback got wrong.
    --
    -- Dungeons.
    [265910] = 1,  -- The Golden Serpent: Tail Thrash
    [268586] = 1,  -- Dazar, The First King: Blade Combo
    [372858] = 1,  -- Kokia Blazehoof: Searing Blows
    [466064] = 1,  -- Emberdawn: Searing Beak
    [467620] = 1,  -- Commander Kro'luk: Rampage
    [472662] = 1,  -- The Restless Heart: Tempest Slash
    [473898] = 1,  -- Xathuux the Annihilator: Legion Strike
    [474496] = 1,  -- Arcanotron Custos: Repulsing Slam
    [1222642] = 1, -- Atroxus: Hulking Claw
    [1222795] = 1, -- Zaen Bladesorrow: Envenom
    [1243569] = 1, -- Nalorakk: Overwhelming Onslaught
    [1247685] = 1, -- Ziekket: Thornspike
    [1247937] = 1, -- Nysarra: Void Gash
    [1251023] = 1, -- Rak'tul: Spiritbreaker
    [1251554] = 1, -- Vor'daza: Drain Soul
    [1253950] = 1, -- Lothraxion: Searing Rend (Nexus Point Xenas)
    [1255335] = 1, -- Lothraxion: Searing Rend
    [1280113] = 1, -- Degentrius: Hulking Fragment
    [1290797] = 1, -- Merektha: Lightning Bite
    [1297017] = 1, -- Taz'Rah: Void Blast
    [1298949] = 1, -- The Writhing Coil: Tail Scythe
    [1301350] = 1, -- Zul'jan: Chop Down
    [1311923] = 1, -- Charonus: Dark Waves

    -- Raid, lairs and world.
    [1221781] = 1, -- Rotmire: Putrid Fist
    [1241692] = 1, -- Vorasius: Shadowclaw Slam
    [1250803] = 1, -- Fallen-King Salhadaar: Shattering Twilight
    [1260763] = 1, -- Belo'ren, Child of Al'ar: Guardian's Edict
    [1268562] = 1, -- Nymrissa Wavecaller: Water Jet (Mythic only)
    [1277025] = 1, -- Sszorak: Apex Predator
    [1280935] = 1, -- Vashnik the Malignant: Dripping Fangs
    [1292036] = 1, -- Nek'zali the Soulcoiler: Possession Barrage

    -- Multi-boss fights the modules pin to a slot themselves.
    -- BigWigs gates Heaven's Lance on ThreatTarget(unit, "boss1").
    [1267049] = 1, -- Midnight Falls: Heaven's Lance
    -- GetOptions files it under "-- Vaelgor", boss1 per the module's own note.
    [1262623] = 1, -- Vaelgor & Ezzorak: Nullbeam
    -- BigWigs gates its sound on ThreatTarget("player", "boss1") -- Vaelgor.
    [1265131] = 1, -- Vaelgor & Ezzorak: Vaelwing
    -- The same check for Ezzorak, boss2, sits commented out beside Rakfang's Message.
    [1245645] = 2, -- Vaelgor & Ezzorak: Rakfang
    -- Triple Shot is out for a different reason: Rav'i casts it, but BigWigs announces it
    -- through ENCOUNTER_WARNING as a PersonalMessage at whoever it picked, so it is not an
    -- aggro-driven hit. Gating it on holding the boss would silence it for the tank it is
    -- actually aimed at, which the any-boss fallback at least does not do.

    -- Deliberately absent, all multi-unit fights whose slots the modules do not settle:
    -- Grappling Maw (shared, above both dragons' headings), Adderis and Aspix' Overload
    -- (the module resolves the slot by GUID at fire time, so it is not fixed), Stormslam,
    -- Debilitating Backhand (Council rotates whoever is active into boss1), Bedrock Slam,
    -- Bone Hack, Flanking Spear, both Judgements and both Crown of the Cosmos abilities.
    -- Each names an owner but never a slot, and a wrong slot silences a real call, so they
    -- keep the any-boss fallback until a live capture says which frame the caster holds.
}

