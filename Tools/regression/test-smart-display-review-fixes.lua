local f=assert(io.open(arg[1],"rb")); local source=f:read("*a"):gsub("\r\n","\n");f:close()
local function extract(start)
    local a=assert(source:find(start,1,true))
    local z=assert(source:find("\nend",a,true))+3
    return source:sub(a,z)
end
local code=extract("local function RebuildSlots(").."\n"..extract("function ns.HideIfCalloutPressed(")
local test=[[
local alpha,hidden,sized=1,false,false
local shownForEvent,lastAnnouncedSpellID=123,99
local settings={hideOnCast=true,voiceOn=false}
local ns={}
local slots={{spellID=22,SetAlpha=function(_,v) alpha=v end,GetAlpha=function() return alpha end}}
local activeSlots=1
local frame={}
local specID,currentEncounter,MAX_SLOTS=250,1,8
local incoming={}
local function EffectiveList() return incoming,nil,"preset" end
local function IsSpellAvailable(sid) return sid~=33 end
local function IsSpellDisabled(sid) return sid==44 end
local function ApplySize() sized=true end
local function TRDB() return settings end
local castToBase={[22]=22,[23]=22,[99]=99}
local function HideReminder() hidden=true end
local function issecretvalue(value) return value==0.75 end
]]..code.."\n"..[[
assert(RebuildSlots("empty",true)==false)
assert(alpha==1 and activeSlots==1 and slots[1].spellID==22 and not sized)
incoming={33,44};assert(RebuildSlots("unusable",true)==false)
assert(alpha==1 and activeSlots==1)
incoming=nil;assert(RebuildSlots("missing",true)==false);assert(alpha==1)
ns.HideIfCalloutPressed(99);assert(not hidden,"stale voice winner dismissed icon")
ns.HideIfCalloutPressed(22);assert(hidden,"voice-off visible winner did not dismiss")
hidden=false;ns.HideIfCalloutPressed(23);assert(hidden,"override cast did not dismiss")
hidden=false;alpha=0;ns.HideIfCalloutPressed(22);assert(not hidden,"invisible slot dismissed")
alpha=0.75;ns.HideIfCalloutPressed(22);assert(not hidden,"secret alpha was treated as readable")
alpha=1;settings.hideOnCast=false;ns.HideIfCalloutPressed(22);assert(not hidden)
settings.hideOnCast=true;shownForEvent=nil;ns.HideIfCalloutPressed(22);assert(not hidden)
incoming={};RebuildSlots();assert(alpha==0 and activeSlots==0,"normal rebuild failed to clear")
print("PASS: empty/missing/unusable presets preserve display; normal rebuild clears; voice-off, stale voice, override, invisible, secret and toggle cases")
]]
assert(load(test,"display review regression","t",_G))()
