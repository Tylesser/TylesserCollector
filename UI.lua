local addonName, ns = ...

-- The collector's window (2026-11-24, the user's request: "an UI to see which kind of data collected and their
-- details"): the kinds of data on the left with their counts, a searchable list of one kind in the middle, the
-- chosen entry's details on the right, and "Show on map" for anything with a spot (the game's own map pin).
-- /tcollect opens it. It only reads TylesserCollectorDB.

local T = ns.T
local V = {}
ns.view = V

local WIDTH, HEIGHT = 940, 640
local SIDE, LIST = 170, 300
local ROW, ROWS = 20, 24 -- (the range line under the rows stays clear of the note at the bottom)

V.KINDS = {
  { key = "npcs", name = "NPCs" },
  { key = "objects", name = "Objects" },
  { key = "quests", name = "Quests" },
  { key = "vendors", name = "Vendors" },
  { key = "trainers", name = "Trainers" },
  { key = "loot", name = "Loot sources" },
  { key = "taxi", name = "Flight points" },
  { key = "flights", name = "Flight times" },
  { key = "instances", name = "Dungeons" },
  { key = "encounters", name = "Bosses" },
  { key = "areas", name = "Sub-zones" },
  { key = "discovered", name = "Discovered" },
  { key = "graveyards", name = "Graveyards" },
  { key = "vignettes", name = "Rares & treasures" },
  { key = "pois", name = "Map points" },
  { key = "recipes", name = "Recipes" },
  { key = "prices", name = "Auction prices" },
  { key = "texts", name = "Readable texts" },
  { key = "speech", name = "Unnamed speakers" },
  { key = "mail", name = "Letters" },
  { key = "errors", name = "Errors" },
}

-- Names ---------------------------------------------------------------------------------------------------------------

local function DB()
  return ns.DB or {}
end

local function NpcName(id)
  local npc = DB().npcs and DB().npcs[id]
  return (npc and npc.name or "NPC") .. " (" .. tostring(id) .. ")"
end

local function ObjectName(id)
  local object = DB().objects and DB().objects[id]
  return (object and object.name or "Object") .. " (" .. tostring(id) .. ")"
end

local function ItemName(id)
  local name
  if C_Item and C_Item.GetItemNameByID then
    name = ns.Str(ns.Ask(C_Item.GetItemNameByID, id))
  end
  name = name or ns.Str((ns.Ask(GetItemInfo, id)))
  return (name or "Item") .. " (" .. tostring(id) .. ")"
end

-- A quest's title: what was kept, else what the game knows now (quests first seen without one)
local function QuestTitle(id, quest)
  local title = quest and quest.title
  if not title and C_QuestLog and C_QuestLog.GetTitleForQuestID then
    title = ns.Str(ns.Ask(C_QuestLog.GetTitleForQuestID, id))
    if title and quest then
      quest.title = title
    end
  end
  return title
end

local function QuestName(id)
  local quest = DB().quests and DB().quests[id]
  return (QuestTitle(id, quest) or "Quest") .. " (" .. tostring(id) .. ")"
end

local function NodeName(id)
  local node = DB().taxi and DB().taxi[tonumber(id)]
  return node and node.name or ("node " .. tostring(id))
end

local function Money(copper)
  copper = tonumber(copper)
  if not copper then
    return "-"
  end
  local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. "g" end
  if silver > 0 then parts[#parts + 1] = silver .. "s" end
  if rest > 0 or #parts == 0 then parts[#parts + 1] = rest .. "c" end
  return table.concat(parts, " ")
end
V.Money = Money

local function Count(t)
  local n = 0
  for _ in pairs(type(t) == "table" and t or {}) do
    n = n + 1
  end
  return n
end

-- The spots of a record as text, and its most seen spot (for "Show on map").
local function SpotsText(spots)
  local parts, best = {}, nil
  for map, list in pairs(type(spots) == "table" and spots or {}) do
    for _, spot in ipairs(list) do
      parts[#parts + 1] = ("map %s: %.1f, %.1f x%d"):format(tostring(map), spot[1], spot[2], spot[3] or 1)
      if not best or (spot[3] or 1) > best.n then
        best = { map = map, x = spot[1], y = spot[2], n = spot[3] or 1 }
      end
    end
  end
  table.sort(parts)
  return parts, best
end

local function SourceName(key)
  local kind, id = tostring(key):match("^(%a+):(%d+)$")
  id = tonumber(id)
  local labels = { npc = "creature", skin = "skinning", pick = "pick pocket", mine = "mining", herb = "herbs",
    object = "object", item = "container", fishing = "fishing on map" }
  if kind == "object" then
    return ObjectName(id), labels[kind]
  elseif kind == "item" then
    return ItemName(id), labels[kind]
  elseif kind == "fishing" then
    return "Fishing, map " .. tostring(id), labels[kind]
  elseif id then
    return NpcName(id), labels[kind] or kind
  end
  return tostring(key), nil
end

-- Entries per kind: { label, sub, record, id, spot } ---------------------------------------------------------------------

local ENTRIES = {}

ENTRIES.npcs = function(db)
  local list = {}
  for id, npc in pairs(db.npcs or {}) do
    local _, best = SpotsText(npc.spots)
    local level = npc.minLevel and (npc.minLevel == npc.maxLevel and tostring(npc.minLevel) or (npc.minLevel .. "-" .. npc.maxLevel))
    list[#list + 1] = { id = id, label = (npc.name or "?") .. " (" .. id .. ")",
      sub = (level and ("level " .. level) or "") .. (npc.title and ("  <" .. npc.title .. ">") or ""), record = npc, spot = best }
  end
  return list
end

ENTRIES.objects = function(db)
  local list = {}
  for id, object in pairs(db.objects or {}) do
    local _, best = SpotsText(object.spots)
    local kind = object.gather == "herb" and "herb" or object.gather == "mine" and "ore" or nil
    local need = object.requires and (object.requires.skill .. (object.requires.level and (" " .. object.requires.level) or ""))
    list[#list + 1] = { id = id, label = (object.name or "?") .. " (" .. id .. ")", sub = need or kind, record = object, spot = best }
  end
  return list
end

ENTRIES.quests = function(db)
  local list = {}
  for id, quest in pairs(db.quests or {}) do
    local _, best = SpotsText(quest.accepted and quest.accepted.spots)
    list[#list + 1] = { id = id, label = (quest.level and ("[" .. quest.level .. "] ") or "") .. (QuestTitle(id, quest) or "?") .. " (" .. id .. ")",
      record = quest, spot = best }
  end
  return list
end

ENTRIES.vendors = function(db)
  local list = {}
  for id, vendor in pairs(db.vendors or {}) do
    local npc = db.npcs and db.npcs[id]
    local _, best = SpotsText(npc and npc.spots)
    list[#list + 1] = { id = id, label = NpcName(id), sub = Count(vendor.items) .. " items", record = vendor, spot = best }
  end
  return list
end

ENTRIES.trainers = function(db)
  local list = {}
  for id, trainer in pairs(db.trainers or {}) do
    local npc = db.npcs and db.npcs[id]
    local _, best = SpotsText(npc and npc.spots)
    list[#list + 1] = { id = id, label = NpcName(id), sub = Count(trainer.services) .. " services", record = trainer, spot = best }
  end
  return list
end

ENTRIES.loot = function(db)
  local list = {}
  for key, record in pairs(db.loot or {}) do
    local name, kind = SourceName(key)
    list[#list + 1] = { id = key, label = name, sub = (kind and (kind .. ", ") or "") .. "opened " .. (record.opened or 0),
      record = record }
  end
  return list
end

ENTRIES.taxi = function(db)
  local list = {}
  for id, node in pairs(db.taxi or {}) do
    list[#list + 1] = { id = id, label = (node.name or "?") .. " (" .. id .. ")", record = node,
      spot = node.map and { map = node.map, x = node.x, y = node.y } or nil }
  end
  return list
end

ENTRIES.flights = function(db)
  local list = {}
  for key, record in pairs(db.flights or {}) do
    local from, to = tostring(key):match("^(%d+)%-(%d+)$")
    local seconds = record.n and record.n > 0 and math.floor(record.sum / record.n + 0.5) or 0
    local fromNode = db.taxi and db.taxi[tonumber(from)]
    local cost = fromNode and fromNode.costs and fromNode.costs[tonumber(to)]
    list[#list + 1] = { id = key, label = NodeName(from) .. " > " .. NodeName(to),
      sub = ("%d:%02d, flown %d times"):format(math.floor(seconds / 60), seconds % 60, record.n or 0)
        .. (cost and (", " .. Money(cost)) or ""), record = record }
  end
  return list
end

ENTRIES.instances = function(db)
  local list = {}
  for id, instance in pairs(db.instances or {}) do
    local _, best = SpotsText(instance.entrance and instance.entrance.spots)
    list[#list + 1] = { id = id, label = (instance.name or "?") .. " (" .. id .. ")", sub = instance.type, record = instance, spot = best }
  end
  return list
end

ENTRIES.encounters = function(db)
  local list = {}
  for id, encounter in pairs(db.encounters or {}) do
    list[#list + 1] = { id = id, label = (encounter.name or "?") .. " (" .. id .. ")",
      sub = (encounter.kills or 0) .. " kills, " .. (encounter.wipes or 0) .. " wipes", record = encounter }
  end
  return list
end

ENTRIES.areas = function(db)
  local list = {}
  for map, names in pairs(db.areas or {}) do
    for name, area in pairs(names) do
      local _, best = SpotsText(area.spots)
      list[#list + 1] = { id = map .. ":" .. name, label = name, sub = (area.zone or "") .. ", map " .. map, record = area, spot = best }
    end
  end
  return list
end

ENTRIES.discovered = function(db)
  local list = {}
  for name, place in pairs(db.discovered or {}) do
    list[#list + 1] = { id = name, label = name, sub = place.xp and (place.xp .. " xp") or nil, record = place,
      spot = place.map and { map = place.map, x = place.x, y = place.y } or nil }
  end
  return list
end

ENTRIES.graveyards = function(db)
  local list = {}
  for map, spots in pairs(db.graveyards and db.graveyards.spots or {}) do
    for index, spot in ipairs(spots) do
      list[#list + 1] = { id = map .. ":" .. index, label = ("Map %s: %.1f, %.1f"):format(tostring(map), spot[1], spot[2]),
        sub = "seen " .. (spot[3] or 1) .. "x", record = { map = map, x = spot[1], y = spot[2], n = spot[3] },
        spot = { map = map, x = spot[1], y = spot[2] } }
    end
  end
  return list
end

local VIGNETTE_TYPES = { [0] = "rare / event", [1] = "PvP bounty", [2] = "Torghast", [3] = "treasure" }
ENTRIES.vignettes = function(db)
  local list = {}
  for id, v in pairs(db.vignettes or {}) do
    local _, best = SpotsText(v.spots)
    local kind = v.atlas and (v.atlas:lower():find("treasure") and "treasure" or v.atlas:lower():find("rare") and "rare") or VIGNETTE_TYPES[v.type]
    list[#list + 1] = { id = id, label = (v.name or "?") .. " (" .. id .. ")", sub = kind, record = v, spot = best }
  end
  return list
end

ENTRIES.pois = function(db)
  local list = {}
  for map, pois in pairs(db.pois or {}) do
    for id, poi in pairs(pois) do
      list[#list + 1] = { id = map .. ":" .. id, label = (poi.name or "?"), sub = "map " .. map, record = poi,
        spot = poi.x and { map = map, x = poi.x, y = poi.y } or nil }
    end
  end
  return list
end

ENTRIES.recipes = function(db)
  local list = {}
  for id, recipe in pairs(db.recipes or {}) do
    list[#list + 1] = { id = id, label = (recipe.name or "?") .. " (" .. id .. ")", sub = recipe.profession, record = recipe }
  end
  return list
end

ENTRIES.prices = function(db)
  local list = {}
  for itemID, prices in pairs(db.prices or {}) do
    local last = prices[#prices]
    list[#list + 1] = { id = itemID, label = ItemName(itemID), sub = last and Money(last.p), record = prices }
  end
  return list
end

ENTRIES.texts = function(db)
  local list = {}
  for key, text in pairs(db.texts or {}) do
    list[#list + 1] = { id = key, label = text.title or key, sub = Count(text.pages) .. " pages", record = text }
  end
  return list
end

ENTRIES.speech = function(db)
  local list = {}
  for name, says in pairs(db.speech or {}) do
    list[#list + 1] = { id = name, label = name, sub = Count(says) .. " lines", record = says }
  end
  return list
end

ENTRIES.mail = function(db)
  local list = {}
  for key, letter in pairs(db.mail or {}) do
    list[#list + 1] = { id = key, label = letter.subject or key, sub = letter.sender, record = letter }
  end
  return list
end

ENTRIES.errors = function(db)
  local list = {}
  for index, text in ipairs(db.errors or {}) do
    list[#list + 1] = { id = index, label = tostring(text):sub(1, 60), record = { text = text } }
  end
  return list
end

function V.Entries(kind)
  local build = ENTRIES[kind]
  local list = build and build(DB()) or {}
  table.sort(list, function(a, b) return tostring(a.label):lower() < tostring(b.label):lower() end)
  return list
end

function V.CountOf(kind)
  local db = DB()
  if kind == "areas" then
    local n = 0
    for _, names in pairs(db.areas or {}) do
      n = n + Count(names)
    end
    return n
  elseif kind == "pois" then
    local n = 0
    for _, pois in pairs(db.pois or {}) do
      n = n + Count(pois)
    end
    return n
  elseif kind == "graveyards" then
    local n = 0
    for _, spots in pairs(db.graveyards and db.graveyards.spots or {}) do
      n = n + #spots
    end
    return n
  end
  return Count(db[kind])
end

-- Details ---------------------------------------------------------------------------------------------------------------

local GOLD, MUTED = "|cfff0c24e", "|cffb8a67d"
local function Head(lines, text)
  lines[#lines + 1] = " "
  lines[#lines + 1] = GOLD .. text .. "|r"
end
local function Field(lines, label, value)
  if value ~= nil and value ~= "" then
    lines[#lines + 1] = MUTED .. label .. ":|r " .. tostring(value)
  end
end
local function Spots(lines, label, spots)
  local parts = SpotsText(spots)
  if #parts > 0 then
    Head(lines, label .. " (" .. #parts .. ")")
    for _, part in ipairs(parts) do
      lines[#lines + 1] = "  " .. part
    end
  end
end
local function Set(t)
  local out = {}
  for key in pairs(type(t) == "table" and t or {}) do
    out[#out + 1] = tostring(key)
  end
  table.sort(out)
  return table.concat(out, ", ")
end
local function Who(lines, label, who)
  if type(who) ~= "table" then
    return
  end
  for kind, ids in pairs(who) do
    for id in pairs(ids) do
      local name = kind == "npc" and NpcName(id) or kind == "object" and ObjectName(id) or kind == "item" and ItemName(id) or tostring(id)
      Field(lines, label, name .. "  (" .. kind .. ")")
    end
  end
end
local function ItemList(lines, label, list)
  if type(list) == "table" and #list > 0 then
    Head(lines, label)
    for _, entry in ipairs(list) do
      lines[#lines + 1] = "  " .. ItemName(entry.item) .. (entry.count and entry.count > 1 and (" x" .. entry.count) or "")
    end
  end
end

-- The quests that name a creature / object / loot source: started or ended there, an objective moved on by it.
local function QuestsLinked(kind, id)
  local starts, ends, objectives = {}, {}, {}
  local sourceKey = kind .. ":" .. tostring(id)
  for questID, quest in pairs(DB().quests or {}) do
    if quest.starts and quest.starts[kind] and quest.starts[kind][id] then starts[#starts + 1] = QuestName(questID) end
    if quest.ends and quest.ends[kind] and quest.ends[kind][id] then ends[#ends + 1] = QuestName(questID) end
    for index, causes in pairs(kind == "npc" and quest.objectiveNpcs or {}) do
      if causes[id] then
        objectives[#objectives + 1] = QuestName(questID) .. ", objective " .. index .. " (" .. causes[id] .. "x)"
      end
    end
    for index, causes in pairs(quest.objectiveSources or {}) do
      for key, count in pairs(causes) do
        if key == sourceKey or (kind == "npc" and (key == "skin:" .. id or key == "pick:" .. id)) then
          objectives[#objectives + 1] = QuestName(questID) .. ", objective " .. index .. " (" .. count .. "x, " .. key:match("^%a+") .. ")"
        end
      end
    end
  end
  table.sort(starts)
  table.sort(ends)
  table.sort(objectives)
  return starts, ends, objectives
end

local function Relations(lines, kind, id)
  local starts, ends, objectives = QuestsLinked(kind, id)
  -- the quest items its loot gave
  local questItems = {}
  for key, record in pairs(DB().loot or {}) do
    local k, sid = tostring(key):match("^(%a+):(%d+)$")
    if tonumber(sid) == id and ((kind == "npc" and k ~= "object" and k ~= "item" and k ~= "fishing") or k == kind) then
      for itemID in pairs(record.items or {}) do
        local quest = DB().questItems and DB().questItems[itemID]
        if quest then
          questItems[#questItems + 1] = ItemName(itemID) .. (type(quest) == "number" and (" for " .. QuestName(quest)) or "")
        end
      end
    end
  end
  if #starts + #ends + #objectives + #questItems == 0 then
    return
  end
  Head(lines, "Quests")
  for _, name in ipairs(starts) do lines[#lines + 1] = "  starts " .. name end
  for _, name in ipairs(ends) do lines[#lines + 1] = "  ends " .. name end
  for _, name in ipairs(objectives) do lines[#lines + 1] = "  counts for " .. name end
  for _, name in ipairs(questItems) do lines[#lines + 1] = "  drops quest item " .. name end
end

-- What a loot source's record says it dropped (for an object or a creature's details).
local function Drops(lines, key)
  local record = DB().loot and DB().loot[key]
  if not record then
    return
  end
  Head(lines, "Loot (" .. key:match("^%a+") .. ", opened " .. (record.opened or 0) .. ")")
  for itemID, pair in pairs(record.items or {}) do
    lines[#lines + 1] = ("  %s: %.0f%%"):format(ItemName(itemID), pair[1] / math.max(1, record.opened or 1) * 100)
  end
end

local function SaysLines(lines, says)
  if type(says) ~= "table" then
    return
  end
  Head(lines, "Says")
  local rows = {}
  for text, how in pairs(says) do
    rows[#rows + 1] = "  (" .. tostring(how) .. ") " .. text
  end
  table.sort(rows)
  for _, row in ipairs(rows) do
    lines[#lines + 1] = row
  end
end

local DETAILS = {}

DETAILS.npcs = function(npc, id, lines)
  Field(lines, "Name", npc.name)
  Field(lines, "Title", npc.title)
  Field(lines, "Level", npc.minLevel and (npc.minLevel .. (npc.maxLevel ~= npc.minLevel and ("-" .. npc.maxLevel) or "")) or (npc.boss and "??" or nil))
  Field(lines, "Classification", npc.class)
  Field(lines, "Type", npc.type)
  Field(lines, "Faction", npc.faction)
  Field(lines, "Reaction", npc.reaction)
  Field(lines, "Beast family", npc.family)
  Field(lines, "Power", npc.power and (({ [0] = "mana", [1] = "rage", [2] = "focus", [3] = "energy", [6] = "runic power" })[npc.power] or npc.power))
  Field(lines, "Binds you to", npc.inn)
  Field(lines, "Comes back within", npc.respawnSeen and (math.floor(npc.respawnSeen / 60) .. " min " .. (npc.respawnSeen % 60) .. " s (shortest wait seen)"))
  Field(lines, "Flight point discovered here", npc.discoversFlightPath and "yes")
  if type(npc.options) == "table" then
    Head(lines, "Talk options lead to")
    for name, what in pairs(npc.options) do
      lines[#lines + 1] = "  " .. name .. ": " .. tostring(what)
    end
  end
  Field(lines, "Services", Set(npc.services))
  Field(lines, "Flight point", npc.taxiNode and NodeName(npc.taxiNode))
  Field(lines, "Boss of encounter", npc.encounter)
  Field(lines, "Skinnable", npc.skinnable and ("yes" .. (npc.skinSkillMin and (", skinned at skill " .. npc.skinSkillMin) or "")))
  Field(lines, "Needs", npc.requires and (npc.requires.skill .. " " .. (npc.requires.level or "")))
  Relations(lines, "npc", id)
  if type(npc.xp) == "table" then
    Head(lines, "XP per kill (your level: average)")
    for level, pair in pairs(npc.xp) do
      lines[#lines + 1] = ("  level %s: %d (%d kills)"):format(tostring(level), math.floor(pair[1] / math.max(1, pair[2]) + 0.5), pair[2])
    end
  end
  if type(npc.rep) == "table" then
    Head(lines, "Reputation per kill")
    for faction, amount in pairs(npc.rep) do
      lines[#lines + 1] = "  " .. faction .. ": " .. amount
    end
  end
  if type(npc.spells) == "table" then
    Head(lines, "Spells seen")
    for spellID, count in pairs(npc.spells) do
      local name = C_Spell and C_Spell.GetSpellName and ns.Str(ns.Ask(C_Spell.GetSpellName, spellID))
      lines[#lines + 1] = ("  %s (%d) x%d"):format(name or "spell", spellID, count)
    end
  end
  if npc.greeting then
    Head(lines, "Greeting")
    lines[#lines + 1] = npc.greeting
  end
  if type(npc.pages) == "table" then
    for text in pairs(npc.pages) do
      if text ~= npc.greeting then
        Head(lines, "Talk page")
        lines[#lines + 1] = text
      end
    end
  end
  SaysLines(lines, npc.says)
  if type(npc.gossip) == "table" and #npc.gossip > 0 then
    Head(lines, "Talk options")
    for _, option in ipairs(npc.gossip) do
      lines[#lines + 1] = "  " .. tostring(option.name)
    end
  end
  if type(npc.sightings) == "table" then
    Head(lines, "Rare sightings (" .. #npc.sightings .. ")")
    for _, s in ipairs(npc.sightings) do
      lines[#lines + 1] = ("  %s  %s  %s"):format(date and date("%Y-%m-%d %H:%M", s.t) or tostring(s.t),
        s.map and ("map %s %.1f, %.1f"):format(s.map, s.x or 0, s.y or 0) or "", s.dead and "dead" or "alive")
    end
  end
  Drops(lines, "npc:" .. id)
  Drops(lines, "skin:" .. id)
  Drops(lines, "pick:" .. id)
  Spots(lines, "Seen at", npc.spots)
end

DETAILS.objects = function(object, id, lines)
  Field(lines, "Name", object.name)
  Field(lines, "Gathered with", object.gather == "herb" and "Herbalism" or object.gather == "mine" and "Mining" or nil)
  Field(lines, "Requires", object.requires and (object.requires.skill .. (object.requires.level and (" " .. object.requires.level) or "")))
  Field(lines, "Your skill when gathered", object.skillMin and (object.skillMin .. (object.skillMax ~= object.skillMin and ("-" .. object.skillMax) or "")))
  Field(lines, "Services", Set(object.services))
  Field(lines, "Takes you to map", object.leadsTo and Set(object.leadsTo))
  if type(object.tooltip) == "table" then
    Head(lines, "Its tooltip")
    for _, line in ipairs(object.tooltip) do
      lines[#lines + 1] = "  " .. line
    end
  end
  Relations(lines, "object", id)
  Drops(lines, "object:" .. id)
  Spots(lines, "Seen at", object.spots)
end

DETAILS.quests = function(quest, id, lines)
  Field(lines, "Title", QuestTitle(id, quest))
  Field(lines, "Level", quest.level)
  Field(lines, "Group", quest.group and quest.group > 0 and quest.group or nil)
  Field(lines, "Zone", quest.zone)
  Field(lines, "Tag", quest.tag)
  Field(lines, "Quest line", quest.line)
  Field(lines, "Offered to you at level", quest.offeredAt)
  Field(lines, "Time limit", quest.timeLimit and (quest.timeLimit .. " s"))
  Who(lines, "Starts at", quest.starts)
  Who(lines, "Ends at", quest.ends)
  Field(lines, "Taken by factions", Set(quest.factions))
  Field(lines, "Classes", Set(quest.classes))
  Field(lines, "Races", Set(quest.races))
  Field(lines, "Handed in", quest.done and (quest.done .. " times"))
  Field(lines, "XP", quest.xp or quest.rewardXP)
  if type(quest.xpByLevel) == "table" then
    local parts = {}
    for level, xp in pairs(quest.xpByLevel) do
      parts[#parts + 1] = level .. ": " .. xp
    end
    table.sort(parts)
    Field(lines, "XP by your level", table.concat(parts, ", "))
  end
  Field(lines, "Money", (quest.money or quest.rewardMoney) and Money(quest.money or quest.rewardMoney))
  if type(quest.after) == "table" then
    Head(lines, "Offered after")
    for before, count in pairs(quest.after) do
      lines[#lines + 1] = "  " .. QuestName(before) .. " x" .. count
    end
  end
  if type(quest.rep) == "table" then
    Head(lines, "Reputation")
    for faction, amount in pairs(quest.rep) do
      lines[#lines + 1] = "  " .. faction .. ": " .. amount
    end
  end
  ItemList(lines, "Choice of rewards", quest.choices)
  ItemList(lines, "Rewards", quest.rewards)
  ItemList(lines, "Required items", quest.required)
  -- what moved its objectives on: kills, loot sources, objects
  for index, causes in pairs(quest.objectiveNpcs or {}) do
    Head(lines, "Objective " .. index .. ": kills")
    for npcID, count in pairs(causes) do
      lines[#lines + 1] = "  " .. NpcName(npcID) .. " x" .. count
    end
  end
  for index, causes in pairs(quest.objectiveSources or {}) do
    Head(lines, "Objective " .. index .. ": from")
    for key, count in pairs(causes) do
      lines[#lines + 1] = "  " .. (SourceName(key)) .. " (" .. key:match("^%a+") .. ") x" .. count
    end
  end
  if type(quest.dropItems) == "table" then
    Head(lines, "Items that drop for it")
    for itemID in pairs(quest.dropItems) do
      lines[#lines + 1] = "  " .. ItemName(itemID)
    end
  end
  Field(lines, "Required money", quest.requiredMoney and Money(quest.requiredMoney))
  if type(quest.objectives) == "table" then
    Head(lines, "Objectives")
    for _, objective in ipairs(quest.objectives) do
      lines[#lines + 1] = "  " .. tostring(objective.text or objective.type or "?")
    end
  end
  for _, field in ipairs({ { "text", "Objective text" }, { "description", "Description" },
    { "progressText", "Progress text" }, { "completionText", "Completion text" } }) do
    if quest[field[1]] then
      Head(lines, field[2])
      lines[#lines + 1] = quest[field[1]]
    end
  end
  Spots(lines, "Accepted at", quest.accepted and quest.accepted.spots)
  for index, record in pairs(quest.objectiveSpots or {}) do
    Spots(lines, "Objective " .. index .. " done at", record.spots)
  end
end

DETAILS.vendors = function(vendor, id, lines)
  Field(lines, "Vendor", NpcName(id))
  Field(lines, "Last visit", vendor.seen and date and date("%Y-%m-%d %H:%M", vendor.seen))
  Head(lines, "Items (" .. Count(vendor.items) .. ")")
  local rows = {}
  for itemID, entry in pairs(vendor.items or {}) do
    local costs = {}
    for _, cost in ipairs(entry.costs or {}) do
      costs[#costs + 1] = (cost.amount or "?") .. " " .. (cost.item and ItemName(cost.item) or cost.currency or "")
    end
    rows[#rows + 1] = "  " .. ItemName(itemID) .. ": " .. Money(entry.price) .. (entry.stack and entry.stack > 1 and (" for " .. entry.stack) or "")
      .. (entry.limit and ("  (stock " .. entry.limit .. ")") or "") .. (#costs > 0 and ("  + " .. table.concat(costs, ", ")) or "")
      .. (type(entry.requires) == "table" and ("  [" .. table.concat(entry.requires, "; ") .. "]") or "")
  end
  table.sort(rows)
  for _, row in ipairs(rows) do
    lines[#lines + 1] = row
  end
end

DETAILS.trainers = function(trainer, id, lines)
  Field(lines, "Trainer", NpcName(id))
  Field(lines, "Type", trainer.type)
  Head(lines, "Services (" .. Count(trainer.services) .. ")")
  local rows = {}
  for _, s in pairs(trainer.services or {}) do
    rows[#rows + 1] = ("  %s%s  level %s  %s%s"):format(s.name or "?", s.rank and (" (" .. s.rank .. ")") or "",
      tostring(s.level or "?"), Money(s.cost), s.skill and ("  needs " .. s.skill .. " " .. tostring(s.skillRank or "")) or "")
  end
  table.sort(rows)
  for _, row in ipairs(rows) do
    lines[#lines + 1] = row
  end
end

DETAILS.loot = function(record, key, lines)
  local name, kind = SourceName(key)
  Field(lines, "Source", name)
  Field(lines, "Kind", kind)
  Field(lines, "Opened", record.opened)
  Field(lines, "Coins", record.money and (Money(math.floor(record.money / math.max(1, record.moneyTimes or 1))) .. " on average (" .. (record.moneyTimes or 0) .. " times)"))
  Field(lines, "Fishing skill", record.skillMin and (record.skillMin .. "-" .. record.skillMax))
  Head(lines, "Drops")
  local rows = {}
  for itemID, pair in pairs(record.items or {}) do
    local chance = pair[1] / math.max(1, record.opened or 1) * 100
    rows[#rows + 1] = { chance, ("  %s: %d times (%.1f%%), %d in all"):format(ItemName(itemID), pair[1], chance, pair[2]) }
  end
  table.sort(rows, function(a, b) return a[1] > b[1] end)
  for _, row in ipairs(rows) do
    lines[#lines + 1] = row[2]
  end
end

DETAILS.taxi = function(node, id, lines)
  Field(lines, "Name", node.name)
  Field(lines, "Map", node.map and ("%s: %.1f, %.1f"):format(node.map, node.x or 0, node.y or 0))
  Field(lines, "Faction", node.faction)
  Field(lines, "Flight master", node.master and NpcName(node.master))
  if type(node.costs) == "table" then
    Head(lines, "Flights from here cost")
    for to, cost in pairs(node.costs) do
      lines[#lines + 1] = "  " .. NodeName(to) .. ": " .. Money(cost)
    end
  end
  if type(node.routes) == "table" then
    Head(lines, "Routes from here")
    for to, path in pairs(node.routes) do
      local hops = {}
      for _, hop in ipairs(path) do
        hops[#hops + 1] = NodeName(hop)
      end
      lines[#lines + 1] = "  " .. NodeName(to) .. ": " .. table.concat(hops, " > ")
    end
  end
end

DETAILS.instances = function(instance, id, lines)
  Field(lines, "Name", instance.name)
  Field(lines, "Type", instance.type)
  Field(lines, "Difficulties", Set(instance.difficulties))
  Head(lines, "Bosses")
  for encounterID, encounter in pairs(DB().encounters or {}) do
    if encounter.instance == id then
      lines[#lines + 1] = "  " .. (encounter.name or "?") .. " (" .. encounterID .. ")"
    end
  end
  Spots(lines, "Entrance", instance.entrance and instance.entrance.spots)
end

DETAILS.encounters = function(encounter, id, lines)
  Field(lines, "Name", encounter.name)
  Field(lines, "Dungeon", encounter.instance and DB().instances and DB().instances[encounter.instance] and DB().instances[encounter.instance].name)
  Field(lines, "Kills", encounter.kills)
  Field(lines, "Wipes", encounter.wipes)
  Field(lines, "Difficulties", Set(encounter.difficulties))
  Head(lines, "Its creatures")
  for npcID in pairs(encounter.npcs or {}) do
    lines[#lines + 1] = "  " .. NpcName(npcID)
  end
end

DETAILS.flights = function(record, key, lines)
  local from, to = tostring(key):match("^(%d+)%-(%d+)$")
  Field(lines, "From", NodeName(from))
  Field(lines, "To", NodeName(to))
  Field(lines, "Average", record.n and record.n > 0 and (math.floor(record.sum / record.n + 0.5) .. " s"))
  local fromNode = DB().taxi and DB().taxi[tonumber(from)]
  local cost = fromNode and fromNode.costs and fromNode.costs[tonumber(to)]
  Field(lines, "Costs", cost and Money(cost))
  Field(lines, "Flown", record.n)
end

DETAILS.areas = function(area, key, lines)
  Field(lines, "Sub-zone", tostring(key):match(":(.*)$"))
  Field(lines, "Zone", area.zone)
  Spots(lines, "Where", area.spots)
end

DETAILS.discovered = function(place, name, lines)
  Field(lines, "Place", name)
  Field(lines, "XP", place.xp)
  Field(lines, "Where", place.map and ("map %s: %.1f, %.1f"):format(place.map, place.x or 0, place.y or 0))
end

DETAILS.graveyards = function(spot, key, lines)
  Field(lines, "Map", spot.map)
  Field(lines, "Spot", ("%.1f, %.1f"):format(spot.x or 0, spot.y or 0))
  Field(lines, "Seen", spot.n)
end

DETAILS.vignettes = function(v, id, lines)
  Field(lines, "Name", v.name)
  Field(lines, "Marker", v.atlas)
  Field(lines, "Is", v.kind and (v.kind == "npc" and NpcName(v.id) or ObjectName(v.id)))
  Field(lines, "Reward quest", v.quest and QuestName(v.quest))
  Spots(lines, "Seen at", v.spots)
end

DETAILS.pois = function(poi, key, lines)
  Field(lines, "Name", poi.name)
  Field(lines, "Description", poi.description)
  Field(lines, "Map", tostring(key):match("^(%d+)"))
  Field(lines, "Spot", poi.x and ("%.1f, %.1f"):format(poi.x, poi.y))
  Field(lines, "Leads to map", poi.linkedMap)
  Field(lines, "Icon", poi.atlas)
end

DETAILS.recipes = function(recipe, id, lines)
  Field(lines, "Name", recipe.name)
  Field(lines, "Profession", recipe.profession)
  Field(lines, "Makes", recipe.product and (ItemName(recipe.product) .. (recipe.makesMax and recipe.makesMax > 1 and
    (" x" .. recipe.makesMin .. (recipe.makesMax ~= recipe.makesMin and ("-" .. recipe.makesMax) or "")) or "")))
  ItemList(lines, "Reagents", recipe.reagents)
  if type(recipe.colors) == "table" then
    Head(lines, "Colour at your skill")
    local rows = {}
    for skill, color in pairs(recipe.colors) do
      rows[#rows + 1] = { skill, ("  %d: %s"):format(skill, tostring(color)) }
    end
    table.sort(rows, function(a, b) return a[1] < b[1] end)
    for _, row in ipairs(rows) do
      lines[#lines + 1] = row[2]
    end
  end
end

DETAILS.prices = function(prices, itemID, lines)
  Field(lines, "Item", ItemName(itemID))
  Head(lines, "Lowest price seen")
  for i = #prices, 1, -1 do
    local p = prices[i]
    lines[#lines + 1] = ("  %s  %s%s"):format(date and date("%Y-%m-%d %H:%M", p.t) or tostring(p.t), Money(p.p),
      p.q and ("  (" .. p.q .. " up)") or "")
  end
end

DETAILS.texts = function(text, key, lines)
  Field(lines, "Title", text.title)
  local kind, id = tostring(key):match("^(%a+):(%d+)$")
  Field(lines, "From", kind == "object" and ObjectName(tonumber(id)) or kind == "item" and ItemName(tonumber(id)) or nil)
  local pages = {}
  for page in pairs(text.pages or {}) do
    pages[#pages + 1] = page
  end
  table.sort(pages)
  for _, page in ipairs(pages) do
    Head(lines, "Page " .. page)
    lines[#lines + 1] = text.pages[page]
  end
end

DETAILS.speech = function(says, name, lines)
  Field(lines, "Speaker", name)
  SaysLines(lines, says)
end

DETAILS.mail = function(letter, key, lines)
  Field(lines, "From", letter.sender)
  Field(lines, "Subject", letter.subject)
  Field(lines, "Money", letter.money and Money(letter.money))
  ItemList(lines, "Items", letter.items)
  if letter.text then
    Head(lines, "Text")
    lines[#lines + 1] = letter.text
  end
end

DETAILS.errors = function(record, index, lines)
  lines[#lines + 1] = tostring(record.text)
end

function V.Details(kind, entry)
  local lines = {}
  local build = DETAILS[kind]
  if build and entry then
    local ok, err = pcall(build, entry.record, entry.id, lines)
    if not ok then
      lines[#lines + 1] = "|cffff5555" .. tostring(err) .. "|r"
    end
  end
  while lines[1] == " " do
    table.remove(lines, 1)
  end
  return table.concat(lines, "\n")
end

-- The window ------------------------------------------------------------------------------------------------------------

local frame
V.kind, V.offset, V.selected, V.filter = "npcs", 0, nil, ""

local function SmallText(parent, size, color)
  local text = parent:CreateFontString(nil, "OVERLAY")
  text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, "")
  text:SetShadowOffset(1, -1)
  text:SetShadowColor(0, 0, 0, 0.9)
  local c = color or T.PARCHMENT
  text:SetTextColor(c[1], c[2], c[3])
  text:SetJustifyH("LEFT")
  return text
end

local function Filtered()
  local all = V.Entries(V.kind)
  local filter = V.filter:lower()
  if filter == "" then
    return all
  end
  local out = {}
  for _, entry in ipairs(all) do
    local hay = (tostring(entry.label) .. " " .. tostring(entry.sub or "") .. " " .. tostring(entry.id)):lower()
    if hay:find(filter, 1, true) then
      out[#out + 1] = entry
    end
  end
  return out
end

function V.Refresh()
  if not frame then
    return
  end
  frame.summary:SetText(ns.Summary and ns.Summary() or "")
  frame.pause:SetText(ns.IsPaused and ns.IsPaused() and "Resume" or "Pause")
  for _, button in ipairs(frame.kinds) do
    local on = button.kind == V.kind
    button.label:SetText(button.name)
    button.count:SetText(tostring(V.CountOf(button.kind)))
    button.mark:SetShown(on)
    local c = on and T.GOLD or T.PARCHMENT
    button.label:SetTextColor(c[1], c[2], c[3])
  end
  local list = Filtered()
  V.list = list
  V.offset = math.max(0, math.min(V.offset, #list - ROWS))
  for index, row in ipairs(frame.rows) do
    local entry = list[V.offset + index]
    row.entry = entry
    if entry then
      row.label:SetText(entry.label)
      row.sub:SetText(entry.sub or "")
      row.mark:SetShown(V.selected ~= nil and entry.id == V.selected)
      row:Show()
    else
      row:Hide()
    end
  end
  frame.range:SetText(#list == 0 and "nothing yet" or ("%d-%d of %d"):format(V.offset + 1, math.min(#list, V.offset + ROWS), #list))
  local chosen
  for _, entry in ipairs(list) do
    if entry.id == V.selected then
      chosen = entry
    end
  end
  V.chosen = chosen
  frame.detailTitle:SetText(chosen and chosen.label or "Pick an entry on the left")
  frame.detail:SetText(chosen and V.Details(V.kind, chosen) or "")
  frame.detailChild:SetHeight(math.max(10, (frame.detail:GetStringHeight() or 0) + 10))
  frame.mapButton:SetEnabled(chosen ~= nil and chosen.spot ~= nil and chosen.spot.map ~= nil)
end

function V.SetKind(kind)
  V.kind, V.offset, V.selected = kind, 0, nil
  if frame then
    frame.detailScroll:SetVerticalScroll(0)
  end
  V.Refresh()
end

function V.Select(id)
  V.selected = id
  if frame then
    frame.detailScroll:SetVerticalScroll(0)
  end
  V.Refresh()
end

-- The game's own map pin on the chosen entry's most seen spot.
function V.ShowOnMap()
  local spot = V.chosen and V.chosen.spot
  if not (spot and spot.map and C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then
    return false
  end
  if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(spot.map) then
    print("|cffc8a25aTylesser Collector:|r the game doesn't allow a map pin on that map.")
    return false
  end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(spot.map, spot.x / 100, spot.y / 100))
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
  end
  return true
end

local function Build()
  frame = CreateFrame("Frame", "TylesserCollectorFrame", UIParent)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  table.insert(UISpecialFrames, "TylesserCollectorFrame")
  T.Stone(frame)
  T.TitleBar(frame, "Tylesser Collector")
  local close = T.CloseButton(frame)
  close:SetPoint("TOPRIGHT", -10, -9)
  close:SetScript("OnClick", function() frame:Hide() end)

  frame.summary = SmallText(frame, 11, T.MUTED)
  frame.summary:SetPoint("TOPLEFT", 18, -42)
  frame.summary:SetPoint("RIGHT", -290, 0)
  frame.summary:SetWordWrap(true)
  frame.pause = T.Button(frame, 80, 22, "Pause")
  frame.pause:SetPoint("TOPRIGHT", -18, -40)
  frame.pause:SetScript("OnClick", function()
    if ns.SetPaused then
      ns.SetPaused(not ns.IsPaused())
    end
    V.Refresh()
  end)
  local refresh = T.Button(frame, 80, 22, "Refresh")
  refresh:SetPoint("RIGHT", frame.pause, "LEFT", -6, 0)
  refresh:SetScript("OnClick", V.Refresh)
  -- sharing on tylesser.com (the link to copy and where the file is)
  frame.upload = T.Button(frame, 90, 22, "Upload", true)
  frame.upload:SetPoint("RIGHT", refresh, "LEFT", -6, 0)
  frame.upload:SetScript("OnClick", function()
    if ns.ShowUpload then
      ns.ShowUpload()
    end
  end)

  -- the kinds
  frame.kinds = {}
  for index, info in ipairs(V.KINDS) do
    local button = CreateFrame("Button", nil, frame)
    button:SetSize(SIDE, 24)
    button:SetPoint("TOPLEFT", 14, -72 - (index - 1) * 25)
    button.kind, button.name = info.key, info.name
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(T.GOLD[1], T.GOLD[2], T.GOLD[3], 0.1)
    button.mark = button:CreateTexture(nil, "ARTWORK")
    button.mark:SetPoint("TOPLEFT")
    button.mark:SetPoint("BOTTOMLEFT")
    button.mark:SetWidth(3)
    button.mark:SetColorTexture(T.GOLD[1], T.GOLD[2], T.GOLD[3], 1)
    button.label = SmallText(button, 13)
    button.label:SetPoint("LEFT", 10, 0)
    button.count = SmallText(button, 11, T.MUTED)
    button.count:SetPoint("RIGHT", -6, 0)
    button:SetScript("OnClick", function() V.SetKind(info.key) end)
    frame.kinds[index] = button
  end

  -- the list
  local listLeft = 14 + SIDE + 14
  local search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  search:SetSize(LIST - 10, 22)
  search:SetPoint("TOPLEFT", listLeft + 6, -72)
  search:SetAutoFocus(false)
  if T.EditBox then
    T.EditBox(search)
  end
  search.hint = SmallText(search, 11, T.MUTED)
  search.hint:SetPoint("LEFT", 2, 0)
  search.hint:SetText("Search")
  search:SetScript("OnTextChanged", function(self)
    V.filter = self:GetText() or ""
    self.hint:SetShown(V.filter == "")
    V.offset = 0
    V.Refresh()
  end)
  search:SetScript("OnEscapePressed", search.ClearFocus)
  search:SetScript("OnEnterPressed", search.ClearFocus)
  frame.search = search
  frame.rows = {}
  for index = 1, ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(LIST, ROW)
    row:SetPoint("TOPLEFT", listLeft, -102 - (index - 1) * ROW)
    local hover = row:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(T.GOLD[1], T.GOLD[2], T.GOLD[3], 0.1)
    row.mark = row:CreateTexture(nil, "ARTWORK")
    row.mark:SetAllPoints()
    row.mark:SetColorTexture(T.GOLD[1], T.GOLD[2], T.GOLD[3], 0.18)
    row.label = SmallText(row, 12)
    row.label:SetPoint("LEFT", 6, 0)
    row.label:SetPoint("RIGHT", -110, 0)
    row.label:SetWordWrap(false)
    row.sub = SmallText(row, 10, T.MUTED)
    row.sub:SetPoint("RIGHT", -4, 0)
    row.sub:SetWidth(104)
    row.sub:SetJustifyH("RIGHT")
    row.sub:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
      if self.entry then
        V.Select(self.entry.id)
      end
    end)
    frame.rows[index] = row
  end
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    if frame.detailScroll:IsMouseOver() then
      local scroll = frame.detailScroll
      local max = math.max(0, frame.detailChild:GetHeight() - scroll:GetHeight())
      scroll:SetVerticalScroll(math.max(0, math.min(max, scroll:GetVerticalScroll() - delta * 40)))
      return
    end
    V.offset = math.max(0, V.offset - delta * 3)
    V.Refresh()
  end)
  frame.range = SmallText(frame, 11, T.MUTED)
  frame.range:SetPoint("TOPLEFT", listLeft + 6, -102 - ROWS * ROW - 4)

  -- the details
  local detailLeft = listLeft + LIST + 16
  local detailWidth = WIDTH - detailLeft - 18
  local box = CreateFrame("Frame", nil, frame)
  box:SetPoint("TOPLEFT", detailLeft, -72)
  box:SetPoint("BOTTOMRIGHT", -14, 46)
  local fill = box:CreateTexture(nil, "BACKGROUND")
  fill:SetAllPoints()
  fill:SetColorTexture(0, 0, 0, 0.3)
  T.Outline(box, 0, T.BRONZE, 1)
  frame.detailTitle = SmallText(box, 14, T.GOLD)
  frame.detailTitle:SetPoint("TOPLEFT", 10, -8)
  frame.detailTitle:SetPoint("RIGHT", -10, 0)
  frame.detailTitle:SetWordWrap(false)
  local scroll = CreateFrame("ScrollFrame", nil, box)
  scroll:SetPoint("TOPLEFT", 10, -30)
  scroll:SetPoint("BOTTOMRIGHT", -10, 8)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(detailWidth - 20, 10)
  scroll:SetScrollChild(child)
  frame.detail = SmallText(child, 12)
  frame.detail:SetPoint("TOPLEFT")
  frame.detail:SetWidth(detailWidth - 24)
  frame.detail:SetWordWrap(true)
  frame.detail:SetSpacing(2)
  frame.detailScroll, frame.detailChild = scroll, child
  frame.mapButton = T.Button(frame, 130, 24, "Show on map")
  frame.mapButton:SetPoint("BOTTOMRIGHT", -14, 14)
  frame.mapButton:SetScript("OnClick", V.ShowOnMap)
  local note = SmallText(frame, 10, T.MUTED)
  note:SetPoint("BOTTOMLEFT", 16, 18)
  note:SetText("Saved on /reload or logout. Share it with Upload: it goes into the Tylesser - Data addon.")
  frame:SetScript("OnShow", V.Refresh)
  frame:Hide()
  V.frame = frame
end

function V.Toggle()
  if not frame then
    Build()
  end
  frame:SetShown(not frame:IsShown())
  return frame:IsShown()
end

function V.Open(kind)
  if not frame then
    Build()
  end
  if kind then
    V.SetKind(kind)
  end
  frame:Show()
  V.Refresh()
end
