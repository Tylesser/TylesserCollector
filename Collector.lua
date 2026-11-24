local addonName, ns = ...

-- Tylesser Collector (2026-11-24, private: the user and the people they hand it to). It only listens to what the game
-- shows you while you play and keeps it in TylesserCollectorDB (written by the game on /reload or logout), for
-- tools/collector/collect.py, which merges the files and builds the TylesserData addon. Nothing is sent anywhere.
--
-- What it keeps (game data only: never a player's name, realm or GUID):
--   npcs[id]      name, title, level range, classification, creature type, faction, reaction, gossip options,
--                 spots per map (where you stood while talking to it, looting it or right next to it)
--   objects[id]   name, spots (herbs, ore, chests, quest objects: looted or soft-targeted)
--   quests[id]    title, level, objectives, who starts / ends it (NPC, object or item), where you accepted it,
--                 where its objectives progressed, rewards, the factions / classes / races that took it
--   vendors[id]   items with price, stack, limited stock and other costs
--   trainers[id]  type and services (spell, rank, level, cost, skill)
--   loot[source]  how often a creature / object / fishing spot was looted and what it dropped
--   taxi[node]    flight points (name, map, position), and the flight master
--   (2026-11-24, "do all": everything below too)
--   quests        + description, progress and completion texts, required items and money, rewards (choice / given
--                 items, money, xp), time limit, reputation, the quest done just before it (chains)
--   loot          + containers opened from the bags ("item:<id>"), skinning / pick pocket / mining / herbs on a
--                 corpse ("skin:<npc>" ...), money per source, your fishing skill at each catch
--   npcs          + xp per kill by your level, reputation per kill, spells they cast, rare sightings (time, spot,
--                 dead or alive), services (mail, bank, auction, stable, guild bank, inn, repair, spirit healer)
--   instances     entrances (the last spot outside), encounters (bosses, kills, their NPCs)
--   areas         sub-zone names with spots, "Discovered" places and their xp
--   graveyards    where you came back as a ghost
--   flights       time between two flight points
--   vendors       + limited stock over time (restock)
--   (2026-11-24, the user's questions after a first look) relations and gathering:
--   quests        + titles of every quest in your log, the creatures whose kills moved an objective on
--                 (objectiveNpcs), the loot / objects that did (objectiveSources), items that drop for it (dropItems)
--   objects       + gather kind (herb / mine, from the spell you cast on it), your skill when you gathered it,
--                 what its tooltip says ("Requires Herbalism (270)"), the skill the game said it needs
--   npcs          + skinnable (its tooltip), your skinning skill when you skinned it
--   (2026-11-24, "collect all data possible")
--   vignettes     rares and treasures from the minimap's own markers: name, kind, exact spots, its creature / object
--   pois          the map's points of interest (name, description, spot) per map
--   npcs          + what they say / yell / emote, their greeting text, beast family, power type, the inn they bind to
--   texts         readable texts (books, plaques, letters): pages, from which object or item
--   objects       + where a portal / object took you (leadsTo: the map you arrived on)
--   taxi          + the hops of each flight route
--   vendors       + what an item requires (its tooltip's "Requires ..." lines: reputation, rank, skill)
--   quests        + tag (elite, dungeon, raid, PvP), quest line, the lowest level you were offered it at, xp by level
--   loot          + disenchanting / prospecting / milling results ("disenchant:<item>" ...)
--   prices        auction house prices over time (lowest price and quantity per item)
--   recipes       your professions' recipes: product, amount made, reagents, and their colour at your skill
--   quests        + the zone it sits under in your quest log, its description and objective text from the log
--                 (quests shared, auto-accepted or escorts never showed an offer window)
--   npcs          + every page of their talk (the text after each option), not only the first
--   (2026-11-24, "collect those too")
--   npcs          + what each talk option leads to (a page, a vendor, a trainer, the flight map, a quest, ...),
--                 the flight master where you discovered a flight point, ordinary creatures' respawn (a living one
--                 next to the spot you killed one at, the shortest wait)
--   taxi          + what each flight costs from here (costs[to] = copper)
--   mail          letters from NPCs and the game (never from players): sender, subject, text, money, items
--
-- Forever hides some values from addons (secret values: unit identity in restricted situations, much in combat).
-- Every value is tested with issecretvalue / canaccessvalue before it is used; a hidden one is skipped, never
-- compared or joined.

local DB
local paused = false
local SPOT_MERGE = 1.0 -- map percent: spots closer than this count as one
local SPOT_CAP = 40 -- per thing per map

-- Values -------------------------------------------------------------------------------------------------------------

local function Hidden(value)
  if value == nil then
    return false
  end
  if type(issecretvalue) == "function" then
    local ok, secret = pcall(issecretvalue, value)
    if not ok or secret then
      return true
    end
  end
  if type(canaccessvalue) == "function" then
    local ok, can = pcall(canaccessvalue, value)
    if not ok or not can then
      return true
    end
  end
  return false
end

local function Plain(value)
  if value == nil or Hidden(value) then
    return nil
  end
  return value
end

local function Num(value)
  value = Plain(value)
  return type(value) == "number" and value or nil
end

local function Str(value)
  value = Plain(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function Bool(value)
  value = Plain(value)
  if type(value) == "boolean" then
    return value
  end
  return nil
end

local function Pack(ok, ...)
  if ok then
    return ...
  end
  return nil
end

local function Ask(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  return Pack(pcall(fn, ...))
end
ns.Ask, ns.Str, ns.Num = Ask, Str, Num

local function Now()
  return type(time) == "function" and time() or 0
end

local function Table(parent, key)
  local value = parent[key]
  if type(value) ~= "table" then
    value = {}
    parent[key] = value
  end
  return value
end

-- GUIDs: "Creature-0-<server>-<instance>-<zone>-<npcID>-<spawn>", "GameObject-..." alike. Players, pets and items
-- carry nothing we keep.
function ns.ParseGUID(guid)
  guid = Str(guid)
  if not guid then
    return nil
  end
  local kind, _, _, _, _, id = strsplit("-", guid)
  id = tonumber(id)
  if not id then
    return nil
  end
  if kind == "Creature" or kind == "Vehicle" then
    return "npc", id
  elseif kind == "GameObject" then
    return "object", id
  end
  return nil
end

-- Where you stand: the map and percent (0.1 steps).
function ns.Here()
  if not C_Map then
    return nil
  end
  local map = Num(Ask(C_Map.GetBestMapForUnit, "player"))
  if not map then
    return nil
  end
  local pos = Ask(C_Map.GetPlayerMapPosition, map, "player")
  if type(pos) ~= "table" or type(pos.GetXY) ~= "function" then
    return nil
  end
  local x, y = Ask(pos.GetXY, pos)
  x, y = Num(x), Num(y)
  if not x or not y or (x == 0 and y == 0) then
    return nil
  end
  return map, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
end

-- A spot on a thing's list for that map: near an old one, it counts there (the place moves to the average).
function ns.AddSpot(record, map, x, y)
  if not (map and x and y) then
    return
  end
  local spots = Table(record, "spots")
  local list = Table(spots, map)
  for _, spot in ipairs(list) do
    local dx, dy = spot[1] - x, spot[2] - y
    if dx * dx + dy * dy <= SPOT_MERGE * SPOT_MERGE then
      local n = spot[3] or 1
      spot[1] = math.floor((spot[1] * n + x) / (n + 1) * 10 + 0.5) / 10
      spot[2] = math.floor((spot[2] * n + y) / (n + 1) * 10 + 0.5) / 10
      spot[3] = n + 1
      return
    end
  end
  if #list < SPOT_CAP then
    list[#list + 1] = { x, y, 1 }
  end
end

local function SpotHere(record)
  local map, x, y = ns.Here()
  ns.AddSpot(record, map, x, y)
end

local function Clock()
  return Num(Ask(GetTime)) or 0
end

-- what just happened, to tie a later event to it (a kill's xp to the creature, a loot to the skinning cast, ...)
local recent = {} -- use = { item, t }, cast = { kind, t }, kill = { npc, t }, turnIn = { quest, t }, boss = { id, t }
ns.recent = recent
local function Fresh(entry, seconds)
  return entry ~= nil and Clock() - entry.t <= seconds
end
local names = {} -- [NPC name] = npcID (seen this session: an xp line names the creature, not its ID)
ns.names = names

-- A chat line read with a game string ("%s dies, you gain %d experience."): the values, or nil.
local patterns = {}
function ns.Match(text, format)
  text = Str(text)
  if not text or type(format) ~= "string" then
    return nil
  end
  local pattern = patterns[format]
  if not pattern then
    -- "%1$s" / "%s" -> a string capture, "%1$d" / "%d" -> a number; everything else matched as written
    pattern = format:gsub("%%%d%$s", "\1"):gsub("%%%d%$d", "\2"):gsub("%%s", "\1"):gsub("%%d", "\2")
    pattern = pattern:gsub("[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%0")
    pattern = "^" .. pattern:gsub("\1", "(.+)"):gsub("\2", "(%%d+)") .. "$"
    patterns[format] = pattern
  end
  return text:match(pattern)
end

-- NPCs and objects ----------------------------------------------------------------------------------------------------

local function Npc(id)
  local npcs = Table(DB, "npcs")
  local npc = npcs[id]
  if not npc then
    npc = {}
    npcs[id] = npc
  end
  return npc
end

local function Object(id)
  local objects = Table(DB, "objects")
  local object = objects[id]
  if not object then
    object = {}
    objects[id] = object
  end
  return object
end

-- Every line of a unit's tooltip (for objects: "Requires Herbalism (270)"), plain texts only.
local function TooltipLines(unit)
  if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then
    return nil
  end
  local data = Ask(C_TooltipInfo.GetUnit, unit)
  local lines = type(data) == "table" and data.lines
  if type(lines) ~= "table" then
    return nil
  end
  local out = {}
  for index, line in ipairs(lines) do
    local text = type(line) == "table" and Str(line.leftText)
    if text and index > 1 then
      out[#out + 1] = text
    end
    if #out >= 6 then
      break
    end
  end
  return #out > 0 and out or nil
end

-- "Requires Herbalism (270)" / "Requires Mining" / "Requires Herbalism 270" in a text: the skill and the level.
function ns.Requirement(text)
  for _, format in ipairs({ ITEM_MIN_SKILL, ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI, SPELL_FAILED_MIN_SKILL }) do
    local skill, level = ns.Match(text, format)
    if skill and tonumber(level) then
      return skill, tonumber(level)
    end
  end
  local skill = ns.Match(text, LOCKED_WITH_SPELL)
  if skill and not skill:find("%d") then
    return skill, nil
  end
  return nil
end

-- The second line of a unit's tooltip when it is a title ("Weapon Merchant"), not the level line.
local function UnitTitle(unit)
  if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then
    return nil
  end
  local data = Ask(C_TooltipInfo.GetUnit, unit)
  local lines = type(data) == "table" and data.lines
  local line = type(lines) == "table" and lines[2]
  local text = type(line) == "table" and Str(line.leftText)
  if not text then
    return nil
  end
  local level = type(LEVEL) == "string" and LEVEL or "Level"
  if text:find(level, 1, true) then
    return nil
  end
  return text
end

local RARE = { rare = true, rareelite = true, worldboss = true }

-- What a unit shows of itself; `spot` = you stand next to it (talking, trading, looting it); `service` = what it
-- does for you ("mail", "bank", ...).
function ns.NoteUnit(unit, spot, service)
  if paused or not DB then
    return nil
  end
  local kind, id = ns.ParseGUID(Ask(UnitGUID, unit))
  if kind == "object" then
    local object = Object(id)
    object.name = Str((Ask(UnitName, unit))) or object.name
    if spot then
      SpotHere(object)
    end
    local lines = TooltipLines(unit)
    if lines then
      object.tooltip = lines
      for _, line in ipairs(lines) do
        local skill, level = ns.Requirement(line)
        if skill then
          object.requires = { skill = skill, level = level or (object.requires and object.requires.level) }
        end
      end
    end
    recent.object = { id = id, t = Clock() }
    if service then
      Table(object, "services")[service] = true
    end
    return kind, id, object
  end
  if kind ~= "npc" then
    return nil
  end
  local npc = Npc(id)
  npc.name = Str((Ask(UnitName, unit))) or npc.name
  local level = Num(Ask(UnitLevel, unit))
  if level and level > 0 then
    npc.minLevel = math.min(npc.minLevel or level, level)
    npc.maxLevel = math.max(npc.maxLevel or level, level)
  elseif level and level < 0 then
    npc.boss = true -- "??"
  end
  npc.class = Str(Ask(UnitClassification, unit)) or npc.class
  npc.type = Str(Ask(UnitCreatureType, unit)) or npc.type
  npc.faction = Str((Ask(UnitFactionGroup, unit))) or npc.faction
  npc.reaction = Num(Ask(UnitReaction, unit, "player")) or npc.reaction
  npc.family = Str(Ask(UnitCreatureFamily, unit)) or npc.family
  npc.power = Num((Ask(UnitPowerType, unit))) or npc.power
  if spot or not npc.title then
    npc.title = UnitTitle(unit) or npc.title
  end
  if not npc.skinnable and type(UNIT_SKINNABLE_LEATHER) == "string" then
    for _, line in ipairs(TooltipLines(unit) or {}) do
      if line == UNIT_SKINNABLE_LEATHER then
        npc.skinnable = true
      end
    end
  end
  if Bool(Ask(UnitIsDead, unit)) and unit == "target" then
    recent.deadTarget = { npc = id, t = Clock() }
  end
  npc.seen = Now()
  if npc.name then
    names[npc.name] = id
  end
  if spot then
    SpotHere(npc)
  end
  if service then
    Table(npc, "services")[service] = true
  end
  -- rares: each sighting (at most one a minute), where you were and whether it was alive
  if npc.class and RARE[npc.class] and (not npc.lastSighting or Now() - npc.lastSighting >= 60) then
    npc.lastSighting = Now()
    local sightings = Table(npc, "sightings")
    local map, x, y = ns.Here()
    if #sightings >= 30 then
      table.remove(sightings, 1)
    end
    sightings[#sightings + 1] = { t = Now(), map = map, x = x, y = y, dead = Bool(Ask(UnitIsDead, unit)) }
  end
  return kind, id, npc
end

-- The NPC (or object) you are talking to.
local function Talking()
  return ns.NoteUnit("npc", true)
end

-- Quests --------------------------------------------------------------------------------------------------------------

local function Quest(id)
  local quests = Table(DB, "quests")
  local quest = quests[id]
  if not quest then
    quest = {}
    quests[id] = quest
  end
  return quest
end

local function NoteWho(quest, field, kind, id)
  if kind and id then
    Table(Table(quest, field), kind)[id] = true
  end
end

local function NoteTaker(quest)
  local _, race = Ask(UnitRace, "player")
  local _, class = Ask(UnitClass, "player")
  local faction = Str((Ask(UnitFactionGroup, "player")))
  if Str(race) then Table(quest, "races")[race] = true end
  if Str(class) then Table(quest, "classes")[class] = true end
  if faction then Table(quest, "factions")[faction] = true end
end

local function QuestLogInfo(questID)
  if not (C_QuestLog and C_QuestLog.GetLogIndexForQuestID) then
    return nil
  end
  local index = Num(Ask(C_QuestLog.GetLogIndexForQuestID, questID))
  local info = index and Ask(C_QuestLog.GetInfo, index)
  return type(info) == "table" and info or nil
end

local function NoteObjectives(quest, questID)
  local list = C_QuestLog and Ask(C_QuestLog.GetQuestObjectives, questID)
  if type(list) ~= "table" or #list == 0 then
    return
  end
  local out = {}
  for index, objective in ipairs(list) do
    if type(objective) == "table" then
      out[index] = { text = Str(objective.text), type = Str(objective.type), need = Num(objective.numRequired) }
    end
  end
  quest.objectives = out
end

-- An item of the quest window ("required", "reward", "choice"): { item, count }.
local function QuestItem(kind, index)
  local _, _, count, _, _, itemID = Ask(GetQuestItemInfo, kind, index)
  itemID = Num(itemID)
  if not itemID then
    local link = Str(Ask(GetQuestItemLink, kind, index))
    itemID = link and tonumber(link:match("item:(%d+)")) or nil
  end
  return itemID and { item = itemID, count = Num(count) or 1 } or nil
end

local function QuestItems(kind, count)
  local list = {}
  for index = 1, Num(count) or 0 do
    list[#list + 1] = QuestItem(kind, index)
  end
  return #list > 0 and list or nil
end

-- The rewards the window shows (offer and completion windows).
local function NoteRewards(quest)
  quest.choices = QuestItems("choice", Ask(GetNumQuestChoices)) or quest.choices
  quest.rewards = QuestItems("reward", Ask(GetNumQuestRewards)) or quest.rewards
  local money, xp = Num(Ask(GetRewardMoney)), Num(Ask(GetRewardXP))
  if money and money > 0 then quest.rewardMoney = money end
  if xp and xp > 0 then quest.rewardXP = xp end
end

function ns.QuestDetail(startItemID)
  local questID = Num(Ask(GetQuestID))
  if not questID or questID == 0 then
    return
  end
  local quest = Quest(questID)
  quest.title = Str(Ask(GetTitleText)) or quest.title
  quest.text = Str(Ask(GetObjectiveText)) or quest.text
  quest.description = Str(Ask(GetQuestText)) or quest.description
  NoteRewards(quest)
  ns.QuestExtras(quest, questID)
  local level = Num(Ask(UnitLevel, "player"))
  if level then
    quest.offeredAt = math.min(quest.offeredAt or level, level) -- the lowest level you were offered it at
  end
  -- chains: the quest you handed in just before this one was offered (within 30 minutes)
  local before = recent.turnIn
  if before and Fresh(before, 1800) and before.quest ~= questID then
    local after = Table(quest, "after")
    after[before.quest] = (after[before.quest] or 0) + 1
  end
  startItemID = Num(startItemID)
  if startItemID and startItemID > 0 then
    NoteWho(quest, "starts", "item", startItemID)
  else
    local kind, id = Talking()
    NoteWho(quest, "starts", kind, id)
  end
end

function ns.QuestAccepted(questID)
  questID = Num(questID)
  if not questID then
    return
  end
  local quest = Quest(questID)
  quest.title = Str(C_QuestLog and Ask(C_QuestLog.GetTitleForQuestID, questID)) or quest.title
  local info = QuestLogInfo(questID)
  if info then
    quest.level = Num(info.level) or quest.level
    quest.group = Num(info.suggestedGroup) or quest.group
    quest.frequency = Num(info.frequency) or quest.frequency
  end
  NoteObjectives(quest, questID)
  NoteTaker(quest)
  ns.QuestExtras(quest, questID)
  local total = C_QuestLog and Num((Ask(C_QuestLog.GetTimeAllowed, questID)))
  if total and total > 0 then
    quest.timeLimit = total
  end
  local map, x, y = ns.Here()
  if map then
    ns.AddSpot(Table(quest, "accepted"), map, x, y)
  end
end

-- The progress window ("progress": what to bring) and the completion window ("complete": rewards).
function ns.QuestEnd(window)
  local questID = Num(Ask(GetQuestID))
  if not questID or questID == 0 then
    return
  end
  local quest = Quest(questID)
  local kind, id = Talking()
  NoteWho(quest, "ends", kind, id)
  quest.title = Str(Ask(GetTitleText)) or quest.title
  if window == "progress" then
    quest.progressText = Str(Ask(GetProgressText)) or quest.progressText
    quest.required = QuestItems("required", Ask(GetNumQuestItems)) or quest.required
    local money = Num(Ask(GetQuestMoneyToGet))
    if money and money > 0 then quest.requiredMoney = money end
  else
    quest.completionText = Str(Ask(GetRewardText)) or quest.completionText
    NoteRewards(quest)
  end
end

function ns.QuestTurnedIn(questID, xp, money)
  questID = Num(questID)
  if not questID then
    return
  end
  local quest = Quest(questID)
  quest.xp = Num(xp) or quest.xp
  quest.money = Num(money) or quest.money
  quest.done = (quest.done or 0) + 1
  recent.turnIn = { quest = questID, t = Clock() }
  local level = Num(Ask(UnitLevel, "player"))
  if level and Num(xp) then
    Table(quest, "xpByLevel")[level] = Num(xp)
  end
end

-- Where a quest's objectives move on: the count of an objective went up, so you are where it is done.
local progress = {} -- [questID] = { [index] = fulfilled } (this session)
function ns.QuestProgress()
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then
    return
  end
  local count = Num(Ask(C_QuestLog.GetNumQuestLogEntries)) or 0
  local map, x, y
  local zone -- the header the quests below sit under (their zone, or a group like "Class")
  for index = 1, count do
    local info = Ask(C_QuestLog.GetInfo, index)
    if type(info) == "table" and Plain(info.isHeader) then
      zone = Str(info.title)
    end
    local questID = type(info) == "table" and not Plain(info.isHeader) and Num(info.questID)
    if questID then
      -- every quest in your log gets its title and level (the "?" quests of the first look had none)
      local quest = Quest(questID)
      quest.title = quest.title or Str(info.title) or Str(Ask(C_QuestLog.GetTitleForQuestID, questID))
      quest.level = quest.level or Num(info.level)
      quest.zone = zone or quest.zone
      -- its texts from the log (by its line: nothing is selected), for quests that never showed an offer window
      if not quest.description then
        local description, objectives = Ask(GetQuestLogQuestText, index)
        quest.description = Str(description)
        quest.text = quest.text or Str(objectives)
      end
      local list = Ask(C_QuestLog.GetQuestObjectives, questID)
      if not quest.objectives then
        NoteObjectives(quest, questID)
      end
      local last = progress[questID]
      local now = {}
      for i, objective in ipairs(type(list) == "table" and list or {}) do
        local done = type(objective) == "table" and Num(objective.numFulfilled) or nil
        now[i] = done
        if done and last and last[i] and done > last[i] then
          if not map then
            map, x, y = ns.Here()
          end
          if map then
            ns.AddSpot(Table(Table(quest, "objectiveSpots"), i), map, x, y)
          end
          ns.ObjectiveCause(quest, i, Str(objective.type))
        end
      end
      progress[questID] = now
    end
  end
end

-- What moved an objective on: a kill (the creature you just got xp for, or your dead target), a loot (its source)
-- or an object you just used. Counted per objective, so the merge can tell the real one from chance.
function ns.ObjectiveCause(quest, index, kind)
  local function Count(field, key)
    local causes = Table(Table(quest, field), index)
    causes[key] = (causes[key] or 0) + 1
  end
  if kind ~= "item" and kind ~= "object" then
    local npc = (Fresh(recent.kill, 5) and recent.kill.npc) or (Fresh(recent.deadTarget, 10) and recent.deadTarget.npc)
    if npc then
      Count("objectiveNpcs", npc)
      return
    end
  end
  if Fresh(recent.loot, 5) then
    Count("objectiveSources", recent.loot.key)
  elseif Fresh(recent.object, 10) then
    Count("objectiveSources", "object:" .. recent.object.id)
  end
end

-- A quest's tag (Elite, Dungeon, Raid, PvP) and its quest line, when the game tells.
function ns.QuestExtras(quest, questID)
  local tag = C_QuestLog and Ask(C_QuestLog.GetQuestTagInfo, questID)
  if type(tag) == "table" then
    quest.tag = Str(tag.tagName) or quest.tag
    quest.tagID = Num(tag.tagID) or quest.tagID
  end
  if C_QuestLine and C_QuestLine.GetQuestLineInfo then
    local map = Num(C_Map and Ask(C_Map.GetBestMapForUnit, "player"))
    local line = Ask(C_QuestLine.GetQuestLineInfo, questID, map)
    if type(line) == "table" then
      quest.line = Str(line.questLineName) or quest.line
      quest.lineID = Num(line.questLineID) or quest.lineID
    end
  end
end

-- Gossip ------------------------------------------------------------------------------------------------------------

function ns.Gossip()
  local kind, id, record = Talking()
  if kind ~= "npc" or not C_GossipInfo then
    return
  end
  -- its talk: the first page is the greeting; every page after an option is kept too (10 at most)
  local text = Str(Ask(C_GossipInfo.GetText))
  if text then
    record.greeting = record.greeting or text
    local pages = Table(record, "pages")
    if not pages[text] then
      local n = 0
      for _ in pairs(pages) do
        n = n + 1
      end
      if n < 10 then
        pages[text] = true
      end
    end
  end
  local options = Ask(C_GossipInfo.GetOptions)
  if type(options) == "table" then
    local list = {}
    ns.gossipOptions = {}
    for _, option in ipairs(options) do
      if type(option) == "table" then
        list[#list + 1] = { name = Str(option.name), icon = Num(option.icon) or Str(option.icon) }
        local optionID = Num(option.gossipOptionID)
        if optionID then
          ns.gossipOptions[optionID] = { npc = id, name = Str(option.name) }
        end
      end
    end
    record.gossip = list
  end
  for _, info in ipairs(Ask(C_GossipInfo.GetAvailableQuests) or {}) do
    local questID = type(info) == "table" and Num(info.questID)
    if questID then
      local quest = Quest(questID)
      quest.title = Str(info.title) or quest.title
      quest.level = Num(info.questLevel) or quest.level
      NoteWho(quest, "starts", "npc", id)
    end
  end
  for _, info in ipairs(Ask(C_GossipInfo.GetActiveQuests) or {}) do
    local questID = type(info) == "table" and Num(info.questID)
    if questID then
      local quest = Quest(questID)
      quest.title = Str(info.title) or quest.title
      NoteWho(quest, "ends", "npc", id)
    end
  end
end

-- A talk option picked (post hook on C_GossipInfo.SelectOption): the next window says what it leads to.
function ns.PickedOption(optionID)
  local option = ns.gossipOptions and ns.gossipOptions[Num(optionID) or -1]
  if option and option.name then
    recent.option = { npc = option.npc, name = option.name, t = Clock() }
  end
end

-- `what` opened right after a pick: "page", "vendor", "trainer", "taxi", "bank", "inn", "quest:<id>", ...
function ns.OptionLed(what)
  local option = recent.option
  if not (option and Fresh(option, 3)) then
    return
  end
  recent.option = nil
  Table(Npc(option.npc), "options")[option.name] = what
end

-- Vendors -------------------------------------------------------------------------------------------------------------

function ns.Merchant()
  local kind, id = Talking()
  if kind ~= "npc" then
    return
  end
  local vendor = Table(Table(DB, "vendors"), id)
  local items = Table(vendor, "items")
  local count = Num(Ask(GetMerchantNumItems)) or 0
  for index = 1, count do
    local itemID = Num(Ask(GetMerchantItemID, index))
    if itemID then
      local entry = {}
      local info = C_MerchantFrame and Ask(C_MerchantFrame.GetItemInfo, index)
      if type(info) == "table" then
        entry.price = Num(info.price)
        entry.stack = Num(info.stackCount)
        local available = Num(info.numAvailable)
        entry.limit = available and available >= 0 and available or nil
        entry.extended = Bool(info.hasExtendedCost) or nil
      else
        local _, _, price, stack, available, _, _, extended = Ask(GetMerchantItemInfo, index)
        entry.price, entry.stack = Num(price), Num(stack)
        available = Num(available)
        entry.limit = available and available >= 0 and available or nil
        entry.extended = Bool(extended) or nil
      end
      -- what it requires (its tooltip's "Requires ..." lines: a reputation standing, a rank, a skill)
      local tip = C_TooltipInfo and C_TooltipInfo.GetMerchantItem and Ask(C_TooltipInfo.GetMerchantItem, index)
      if type(tip) == "table" and type(tip.lines) == "table" then
        local needs = {}
        local word = type(LOCKED_WITH_SPELL) == "string" and LOCKED_WITH_SPELL:match("^(%S+)") or "Requires"
        for _, line in ipairs(tip.lines) do
          local text = type(line) == "table" and Str(line.leftText)
          if text and text:find("^" .. word) then
            needs[#needs + 1] = text
          end
        end
        entry.requires = #needs > 0 and needs or nil
      end
      local costs = Num(Ask(GetMerchantItemCostInfo, index)) or 0
      if costs > 0 then
        entry.costs = {}
        for c = 1, costs do
          local _, value, link, currency = Ask(GetMerchantItemCostItem, index, c)
          link = Str(link)
          entry.costs[c] = { amount = Num(value), item = link and tonumber(link:match("item:(%d+)")) or nil,
            currency = Str(currency) }
        end
      end
      items[itemID] = entry
      -- limited stock over time (how fast it comes back): a line when the count changed or 10 minutes passed
      if entry.limit then
        local stock = Table(Table(vendor, "stock"), itemID)
        local last = stock[#stock]
        if not last or last.n ~= entry.limit or Now() - last.t >= 600 then
          if #stock >= 12 then
            table.remove(stock, 1)
          end
          stock[#stock + 1] = { t = Now(), n = entry.limit }
        end
      end
    end
  end
  vendor.seen = Now()
  if Bool(Ask(CanMerchantRepair)) then
    Table(Npc(id), "services").repair = true
  end
end

-- Trainers ------------------------------------------------------------------------------------------------------------

function ns.Trainer()
  local kind, id = Talking()
  if kind ~= "npc" then
    return
  end
  local trainer = Table(Table(DB, "trainers"), id)
  trainer.type = C_Trainer and Num(Ask(C_Trainer.GetTrainerType)) or trainer.type
  local services = Table(trainer, "services")
  local count = Num(Ask(GetNumTrainerServices)) or 0
  for index = 1, count do
    local name, state, _, level, rank = Ask(GetTrainerServiceInfo, index)
    name, state = Str(name), Str(state)
    if name and state ~= "header" then
      local data = C_TooltipInfo and Ask(C_TooltipInfo.GetTrainerService, index)
      local spellID = type(data) == "table" and Num(data.id) or nil
      local cost = Num((Ask(GetTrainerServiceCost, index)))
      local skillName, skillRank = Ask(GetTrainerServiceSkillReq, index)
      local key = spellID or (name .. (Str(rank) and (":" .. rank) or ""))
      services[key] = { name = name, rank = Str(rank), level = Num(level) or Num(Ask(GetTrainerServiceLevelReq, index)),
        cost = cost, spell = spellID, skill = Str(skillName), skillRank = Num(skillRank) }
    end
  end
  trainer.seen = Now()
end

-- Loot ----------------------------------------------------------------------------------------------------------------

local lootSeen = {} -- [source GUID] = true (this session: the same corpse opened twice counts once)

-- What a loot window comes from: a creature ("npc:<id>", or "skin:" / "pick:" / "mine:" / "herb:" when you just
-- skinned, pick-pocketed, mined or picked herbs from it), an object, a container you just opened from your bags
-- ("item:<id>": its GUID names no item), or a fishing catch ("fishing:<map>").
local function SourceKey(guid, fishing, map)
  local kind, id = ns.ParseGUID(guid)
  if kind == "npc" and Fresh(recent.cast, 3) and recent.cast.kind then
    return recent.cast.kind .. ":" .. id, kind, id
  end
  if kind then
    return kind .. ":" .. id, kind, id
  end
  if guid and guid:find("^Item%-") and Fresh(recent.use, 5) then
    -- disenchanting / prospecting / milling an item (the spell, then the item you clicked), else opening it
    local cast = Fresh(recent.cast, 8) and recent.cast.kind
    if cast == "disenchant" or cast == "prospect" or cast == "mill" then
      return cast .. ":" .. recent.use.item, cast, recent.use.item
    end
    return "item:" .. recent.use.item, "item", recent.use.item
  end
  if fishing and map then
    return "fishing:" .. map, "fishing", map
  end
  return nil
end

-- Your fishing skill now (GetProfessions' fourth value is the fishing slot).
local function FishingSkill()
  local _, _, _, fishing = Ask(GetProfessions)
  fishing = Num(fishing)
  if not fishing then
    return nil
  end
  local _, _, rank = Ask(GetProfessionInfo, fishing)
  return Num(rank)
end

-- Your skill in a gathering profession now: kind "herb" / "mine" / "skin" (skill lines 182 / 186 / 393).
local SKILL_LINES = { herb = 182, mine = 186, skin = 393 }
function ns.GatherSkill(kind)
  local line = SKILL_LINES[kind]
  if not line then
    return nil
  end
  local first, second = Ask(GetProfessions)
  for _, index in ipairs({ Num(first) or -1, Num(second) or -1 }) do
    if index >= 0 then
      local _, _, rank, _, _, _, skillLine = Ask(GetProfessionInfo, index)
      if Num(skillLine) == line then
        return Num(rank)
      end
    end
  end
  return nil
end

local function NoteSkill(record, kind)
  local skill = ns.GatherSkill(kind)
  if skill then
    record.skillMin = math.min(record.skillMin or skill, skill)
    record.skillMax = math.max(record.skillMax or skill, skill)
  end
end

local moneyLoot -- { start, records } while a loot window with coins is open

function ns.Loot()
  if paused or not DB then
    return
  end
  local count = Num(Ask(GetNumLootItems)) or 0
  if count == 0 then
    return
  end
  local fishing = Bool(Ask(IsFishingLoot)) or false
  local map, x, y = ns.Here()
  local loot = Table(DB, "loot")
  local opened = {}
  local moneySlot = Enum and Enum.LootSlotType and Enum.LootSlotType.Money
  local coinRecords = {}
  for slot = 1, count do
    local isMoney = moneySlot ~= nil and Num(Ask(GetLootSlotType, slot)) == moneySlot
    local link = Str(Ask(GetLootSlotLink, slot))
    local itemID = link and tonumber(link:match("item:(%d+)")) or nil
    local _, _, quantity, _, _, _, isQuestItem, questID = Ask(GetLootSlotInfo, slot)
    quantity = Num(quantity) or 1
    questID = Num(questID)
    if itemID and (Bool(isQuestItem) or (questID and questID > 0)) then
      -- an item that drops for a quest
      Table(DB, "questItems")[itemID] = questID and questID > 0 and questID or true
      if questID and questID > 0 then
        Table(Quest(questID), "dropItems")[itemID] = true
      end
    end
    local sources = { Ask(GetLootSourceInfo, slot) }
    if #sources == 0 and fishing then
      sources = { false, quantity } -- (no GUID: the fishing spot of this map)
    end
    for i = 1, #sources, 2 do
      local guid = sources[i] and Str(sources[i]) or nil -- a hidden GUID is never compared: Str tests it first
      local key, kind, id = SourceKey(guid, fishing and not guid, map)
      if key then
        local record = Table(loot, key)
        local openKey = key .. "|" .. (guid or "")
        if not opened[openKey] then
          opened[openKey] = { record = record, guid = guid, kind = kind, id = id }
        end
        if isMoney then
          opened[openKey].coins = true
        end
        if itemID then
          local items = Table(record, "items")
          local item = items[itemID] or { 0, 0 }
          item[1] = item[1] + 1
          item[2] = item[2] + (Num(sources[i + 1]) or quantity)
          items[itemID] = item
        end
      end
    end
  end
  for key in pairs(opened) do
    recent.loot = { key = key:match("^[^|]+"), t = Clock() } -- (for a quest objective that moves on right after)
    break
  end
  for _, open in pairs(opened) do
    local fresh = not open.guid or not lootSeen[open.guid]
    if open.guid then
      lootSeen[open.guid] = true
    end
    if fresh then
      open.record.opened = (open.record.opened or 0) + 1
      if open.coins then
        coinRecords[#coinRecords + 1] = open.record
      end
      if open.kind == "fishing" then
        local skill = FishingSkill()
        if skill then
          open.record.skillMin = math.min(open.record.skillMin or skill, skill)
          open.record.skillMax = math.max(open.record.skillMax or skill, skill)
        end
      end
      if open.kind == "object" then
        local object = Object(open.id)
        ns.AddSpot(object, map, x, y)
        -- gathered with herbalism / mining (the spell you just cast on it): its kind and your skill
        local cast = Fresh(recent.cast, 3) and recent.cast.kind
        if cast == "herb" or cast == "mine" then
          object.gather = cast
          NoteSkill(object, cast)
        end
      elseif open.kind == "npc" then
        ns.AddSpot(Npc(open.id), map, x, y)
        ns.NoteKill(open.id, map, x, y)
        local cast = Fresh(recent.cast, 3) and recent.cast.kind
        if cast == "skin" then
          local npc = Npc(open.id)
          npc.skinnable = true
          local skill = ns.GatherSkill("skin")
          if skill then
            npc.skinSkillMin = math.min(npc.skinSkillMin or skill, skill)
          end
        end
        -- a boss of the encounter just won (inside an instance)
        local boss = recent.boss
        if boss and Fresh(boss, 120) then
          local encounter = Table(Table(DB, "encounters"), boss.id)
          Table(encounter, "npcs")[open.id] = true
          Npc(open.id).encounter = boss.id
        end
      end
    end
  end
  -- coins: what your money grew by when the window closes, shared by the sources that had coins
  if #coinRecords > 0 then
    moneyLoot = { start = Num(Ask(GetMoney)), records = coinRecords }
  end
end

function ns.LootClosed()
  local pending = moneyLoot
  moneyLoot = nil
  local now = Num(Ask(GetMoney))
  if not (pending and pending.start and now) then
    return
  end
  local gained = now - pending.start
  if gained <= 0 then
    return
  end
  local share = math.floor(gained / #pending.records)
  for _, record in ipairs(pending.records) do
    record.money = (record.money or 0) + share
    record.moneyTimes = (record.moneyTimes or 0) + 1
  end
end

-- Gathering on a corpse and pick pocketing: the spell you just cast, by name (any language: the names come from
-- these spell IDs).
local CAST_KINDS = { [8613] = "skin", [921] = "pick", [2575] = "mine", [2366] = "herb", [13262] = "disenchant",
  [31252] = "prospect", [51005] = "mill" }
local castNames
local function SpellName(spellID)
  if C_Spell and C_Spell.GetSpellName then
    return Str(Ask(C_Spell.GetSpellName, spellID))
  end
  return Str((Ask(GetSpellInfo, spellID)))
end
function ns.PlayerCast(spellID)
  spellID = Num(spellID)
  if not spellID then
    return
  end
  if not castNames then
    castNames = {}
    for id, kind in pairs(CAST_KINDS) do
      local name = SpellName(id)
      if name then
        castNames[name] = kind
      end
    end
  end
  local name = SpellName(spellID)
  local kind = CAST_KINDS[spellID] or (name and castNames[name])
  if kind then
    recent.cast = { kind = kind, t = Clock() }
  end
end

-- Containers opened from the bags: the item, for the loot window that follows.
function ns.UsedItem(bag, slot)
  if not C_Container then
    return
  end
  local itemID = Num(Ask(C_Container.GetContainerItemID, bag, slot))
  if itemID then
    recent.use = { item = itemID, t = Clock() }
  end
end

-- Flight points ---------------------------------------------------------------------------------------------------------

function ns.Taxi()
  local kind, id = Talking()
  if not C_TaxiMap then
    return
  end
  local mapID = Num(Ask(GetTaxiMapID)) or Num(C_Map and Ask(C_Map.GetBestMapForUnit, "player"))
  local nodes = mapID and Ask(C_TaxiMap.GetAllTaxiNodes, mapID)
  if type(nodes) ~= "table" then
    return
  end
  local taxi = Table(DB, "taxi")
  ns.taxiNodes, ns.taxiHere, ns.taxiSlots = {}, nil, {}
  local seen = {}
  for _, node in ipairs(nodes) do
    local nodeID = type(node) == "table" and Num(node.nodeID)
    if nodeID then
      local entry = taxi[nodeID] or {}
      entry.name = Str(node.name) or entry.name
      local pos = node.position
      if type(pos) == "table" then
        local x, y = Ask(pos.GetXY, pos)
        x, y = Num(x or pos.x), Num(y or pos.y)
        if x and y then
          entry.map, entry.x, entry.y = mapID, math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
        end
      end
      entry.faction = Num(node.faction) or entry.faction
      local state = Num(node.state)
      local slot = Num(node.slotIndex)
      if slot then
        ns.taxiNodes[slot] = nodeID
        ns.taxiSlots[nodeID] = slot
      end
      entry.pendingCost = slot and Num(Ask(TaxiNodeCost, slot)) or nil
      if state == 0 then -- Enum.FlightPathState.Current: the node you stand at
        ns.taxiHere = nodeID
        if kind == "npc" then
          entry.master = id
          Npc(id).taxiNode = nodeID
        end
      end
      taxi[nodeID] = entry
      seen[#seen + 1] = entry
    end
  end
  -- what each flight costs from the node you stand at
  local here = ns.taxiHere and taxi[ns.taxiHere]
  for _, entry in ipairs(seen) do
    if here and entry ~= here and entry.pendingCost and entry.pendingCost > 0 then
      for nodeID, e in pairs(taxi) do
        if e == entry then
          Table(here, "costs")[nodeID] = entry.pendingCost
        end
      end
    end
    entry.pendingCost = nil
  end
end

-- The hops of each route from here (the older taxi calls, when this build has them): taxi[from].routes[to] = { nodes }.
function ns.TaxiRoutes()
  if not (ns.taxiHere and type(GetNumRoutes) == "function" and type(TaxiGetNodeSlot) == "function") then
    return
  end
  local here = DB.taxi and DB.taxi[ns.taxiHere]
  if not here then
    return
  end
  local bySlot = {}
  for nodeID, slot in pairs(ns.taxiSlots or {}) do
    bySlot[slot] = nodeID
  end
  for nodeID, slot in pairs(ns.taxiSlots or {}) do
    if nodeID ~= ns.taxiHere then
      local hops = Num(Ask(GetNumRoutes, slot))
      if hops and hops > 0 then
        local path = {}
        for hop = 1, hops do
          local to = bySlot[Num(Ask(TaxiGetNodeSlot, slot, hop, false)) or -1]
          path[#path + 1] = to or 0
        end
        Table(here, "routes")[nodeID] = path
      end
    end
  end
end

-- Flights: TakeTaxiNode (post hook) starts the clock, landing (control back, off the taxi) stops it.
function ns.TookTaxi(slot)
  local to = ns.taxiNodes and ns.taxiNodes[Num(slot) or -1]
  if to and ns.taxiHere and to ~= ns.taxiHere then
    recent.flight = { from = ns.taxiHere, to = to, t = Clock() }
  end
end

function ns.Landed()
  local flight = recent.flight
  if not flight or Bool(Ask(UnitOnTaxi, "player")) then
    return
  end
  recent.flight = nil
  local seconds = Clock() - flight.t
  if seconds < 5 or seconds > 3600 then
    return
  end
  local record = Table(Table(DB, "flights"), flight.from .. "-" .. flight.to)
  record.sum = (record.sum or 0) + math.floor(seconds + 0.5)
  record.n = (record.n or 0) + 1
end

-- Chat lines: xp for a kill, reputation (a kill or a quest just before it), discovered places.
function ns.XPLine(text)
  local name, xp = ns.Match(text, COMBATLOG_XPGAIN_FIRSTPERSON)
  xp = tonumber(xp)
  local id = name and names[name]
  if not (id and xp) then
    return
  end
  local level = Num(Ask(UnitLevel, "player")) or 0
  local byLevel = Table(Table(Npc(id), "xp"), level)
  byLevel[1] = (byLevel[1] or 0) + xp
  byLevel[2] = (byLevel[2] or 0) + 1
  recent.kill = { npc = id, t = Clock() }
end

function ns.FactionLine(text)
  local faction, amount = ns.Match(text, FACTION_STANDING_INCREASED)
  local sign = 1
  if not faction then
    faction, amount = ns.Match(text, FACTION_STANDING_DECREASED)
    sign = -1
  end
  amount = tonumber(amount)
  if not (faction and amount) then
    return
  end
  if Fresh(recent.turnIn, 2) then
    Table(Quest(recent.turnIn.quest), "rep")[faction] = sign * amount
  elseif Fresh(recent.kill, 2) then
    Table(Npc(recent.kill.npc), "rep")[faction] = sign * amount
  end
end

function ns.SystemLine(text)
  ns.NewFlightPath(text)
  local place, xp = ns.Match(text, ERR_ZONE_EXPLORED_XP)
  if not place then
    place = ns.Match(text, ERR_ZONE_EXPLORED)
  end
  if not place then
    return
  end
  local entry = Table(Table(DB, "discovered"), place)
  entry.xp = tonumber(xp) or entry.xp
  local map, x, y = ns.Here()
  if map then
    entry.map, entry.x, entry.y = map, x, y
  end
end

-- Spells creatures cast (when the game lets an addon see them: a hidden spell ID is skipped).
function ns.UnitCast(unit, spellID)
  spellID = Num(spellID)
  if not spellID then
    return
  end
  local kind, id = ns.ParseGUID(Ask(UnitGUID, unit))
  if kind ~= "npc" then
    return
  end
  local spells = Table(Npc(id), "spells")
  local known = 0
  for _ in pairs(spells) do
    known = known + 1
  end
  if spells[spellID] or known < 40 then
    spells[spellID] = (spells[spellID] or 0) + 1
  end
end

-- Instances and bosses: the entrance is the last spot outside before you went in.
local inside = false
function ns.WhereAmI()
  local isIn, kind = Ask(IsInInstance)
  isIn = Bool(isIn) or false
  if isIn and not inside then
    local name, type_, difficulty, _, _, _, _, instanceID = Ask(GetInstanceInfo)
    instanceID = Num(instanceID)
    if instanceID then
      local instance = Table(Table(DB, "instances"), instanceID)
      instance.name = Str(name) or instance.name
      instance.type = Str(type_) or Str(kind) or instance.type
      Table(instance, "difficulties")[Num(difficulty) or 0] = true
      local out = recent.outside
      if out and Fresh(out, 300) then
        ns.AddSpot(Table(instance, "entrance"), out.map, out.x, out.y)
      end
      ns.instance = instanceID
    end
  elseif not isIn then
    ns.instance = nil
  end
  inside = isIn
end

function ns.EncounterEnd(encounterID, name, difficulty, size, success)
  encounterID = Num(encounterID)
  if not encounterID then
    return
  end
  local encounter = Table(Table(DB, "encounters"), encounterID)
  encounter.name = Str(name) or encounter.name
  encounter.instance = ns.instance or encounter.instance
  Table(encounter, "difficulties")[Num(difficulty) or 0] = true
  if Num(success) == 1 then
    encounter.kills = (encounter.kills or 0) + 1
    recent.boss = { id = encounterID, t = Clock() }
  else
    encounter.wipes = (encounter.wipes or 0) + 1
  end
end

-- Every 5 s out of a fight: the sub-zone you are in (names and where they apply), and the last spot outside.
function ns.Tick()
  if paused or not DB or Ask(InCombatLockdown) then
    return
  end
  local map, x, y = ns.Here()
  if not map then
    return
  end
  recent.outside = { map = map, x = x, y = y, t = Clock() }
  local sub = Str(Ask(GetSubZoneText))
  local zone = Str(Ask(GetZoneText))
  local name = sub or zone
  if name then
    local area = Table(Table(Table(DB, "areas"), map), name)
    area.zone = zone
    ns.AddSpot(area, map, x, y)
  end
end

-- The game said your skill is too low ("Requires Herbalism 270"): the object (or creature) you just tried.
function ns.ErrorLine(text)
  local skill, level = ns.Requirement(text)
  if not (skill and level) then
    return
  end
  if Fresh(recent.object, 10) then
    Object(recent.object.id).requires = { skill = skill, level = level }
  elseif Fresh(recent.deadTarget, 30) then
    Npc(recent.deadTarget.npc).requires = { skill = skill, level = level }
  end
end

-- Quests seen before without a title: the game's name for them, once it knows it.
function ns.FillTitles()
  if not (DB and DB.quests and C_QuestLog and C_QuestLog.GetTitleForQuestID) then
    return
  end
  for questID, quest in pairs(DB.quests) do
    if not quest.title then
      quest.title = Str(Ask(C_QuestLog.GetTitleForQuestID, questID))
    end
  end
end

-- Rares and treasures: the minimap's own markers (vignettes), with their exact spot, and the creature / object.
local vignettesSeen = {} -- [vignette GUID] = true (this session)
function ns.Vignettes()
  if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then
    return
  end
  local map = Num(C_Map and Ask(C_Map.GetBestMapForUnit, "player"))
  for _, guid in ipairs(Ask(C_VignetteInfo.GetVignettes) or {}) do
    guid = Str(guid)
    if guid and not vignettesSeen[guid] then
      local info = Ask(C_VignetteInfo.GetVignetteInfo, guid)
      local id = type(info) == "table" and Num(info.vignetteID)
      if id then
        vignettesSeen[guid] = true
        local record = Table(Table(DB, "vignettes"), id)
        record.name = Str(info.name) or record.name
        record.type = Num(info.type) or record.type
        record.atlas = Str(info.atlasName) or record.atlas
        record.quest = Num(info.rewardQuestID) ~= 0 and Num(info.rewardQuestID) or record.quest
        local kind, objectID = ns.ParseGUID(info.objectGUID)
        if kind then
          record.kind, record.id = kind, objectID
        end
        local pos = map and Ask(C_VignetteInfo.GetVignettePosition, guid, map)
        if type(pos) == "table" then
          local x, y = Ask(pos.GetXY, pos)
          x, y = Num(x), Num(y)
          if x and y and (x > 0 or y > 0) then
            x, y = math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
            ns.AddSpot(record, map, x, y)
            if kind == "npc" then
              ns.AddSpot(Npc(objectID), map, x, y)
            elseif kind == "object" then
              ns.AddSpot(Object(objectID), map, x, y)
            end
          end
        end
      end
    end
  end
end

-- The map's points of interest (once per map per session).
local poisSeen = {}
function ns.MapPOIs()
  local map = Num(C_Map and Ask(C_Map.GetBestMapForUnit, "player"))
  if not (map and C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIForMap) or poisSeen[map] then
    return
  end
  poisSeen[map] = true
  for _, poiID in ipairs(Ask(C_AreaPoiInfo.GetAreaPOIForMap, map) or {}) do
    poiID = Num(poiID)
    local info = poiID and Ask(C_AreaPoiInfo.GetAreaPOIInfo, map, poiID)
    if type(info) == "table" then
      local entry = Table(Table(Table(DB, "pois"), map), poiID)
      entry.name = Str(info.name) or entry.name
      entry.description = Str(info.description) or entry.description
      entry.atlas = Str(info.atlasName) or entry.atlas
      entry.linkedMap = Num(info.linkedUiMapID) or entry.linkedMap
      local pos = info.position
      if type(pos) == "table" then
        local x, y = Ask(pos.GetXY, pos)
        x, y = Num(x or pos.x), Num(y or pos.y)
        if x and y then
          entry.x, entry.y = math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
        end
      end
    end
  end
end

-- What NPCs say: the line and how ("say", "yell", "emote", "whisper"), on the NPC when its name is known.
function ns.MonsterLine(how, text, sender)
  text, sender = Str(text), Str(sender)
  if not (text and sender) then
    return
  end
  local id = names[sender]
  local says = id and Table(Npc(id), "says") or Table(Table(DB, "speech"), sender)
  if not says[text] then
    local count = 0
    for _ in pairs(says) do
      count = count + 1
    end
    if count >= 40 then
      return -- (40 lines per speaker are plenty)
    end
  end
  says[text] = how
end

-- Readable texts (books, plaques, letters): every page, from the object or item you read.
local reading
function ns.ReadText()
  local page = Num(Ask(ItemTextGetPage)) or 1
  local text = Str(Ask(ItemTextGetText))
  if not text then
    return
  end
  if page == 1 or not reading then
    local title = Str(Ask(ItemTextGetItem))
    local from
    if Fresh(recent.object, 15) then
      from = "object:" .. recent.object.id
    elseif Fresh(recent.use, 15) then
      from = "item:" .. recent.use.item
    end
    reading = { key = from or ("title:" .. tostring(title)), title = title }
  end
  local record = Table(Table(DB, "texts"), reading.key)
  record.title = reading.title or record.title
  Table(record, "pages")[page] = text
end

-- Portals and the like: the object you just used, and the map you arrived on.
local lastMap
function ns.Arrived()
  local map = Num(C_Map and Ask(C_Map.GetBestMapForUnit, "player"))
  if map and lastMap and map ~= lastMap and Fresh(recent.object, 20) then
    Table(Object(recent.object.id), "leadsTo")[map] = true
    recent.object = nil -- (once: a second zone change soon after is your own walk, not the portal's)
  end
  lastMap = map or lastMap
end

-- Auction house prices over time: the lowest price and quantity per item, a line when it changed or after an hour.
local function NotePrice(itemID, price, quantity)
  itemID, price = Num(itemID), Num(price)
  if not (itemID and price and price > 0) then
    return
  end
  local list = Table(Table(DB, "prices"), itemID)
  local last = list[#list]
  if last and last.p == price and Now() - last.t < 3600 then
    return
  end
  if #list >= 20 then
    table.remove(list, 1)
  end
  list[#list + 1] = { t = Now(), p = price, q = Num(quantity) }
end
ns.NotePrice = NotePrice

function ns.BrowseResults()
  if not (C_AuctionHouse and C_AuctionHouse.GetBrowseResults) then
    return
  end
  for _, result in ipairs(Ask(C_AuctionHouse.GetBrowseResults) or {}) do
    if type(result) == "table" and type(result.itemKey) == "table" then
      NotePrice(result.itemKey.itemID, result.minPrice, result.totalQuantity)
    end
  end
end

function ns.CommodityResults(itemID)
  itemID = Num(itemID)
  if not (itemID and C_AuctionHouse and C_AuctionHouse.GetCommoditySearchResultInfo) then
    return
  end
  local first = Ask(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, 1)
  local quantity = C_AuctionHouse.GetCommoditySearchResultsQuantity and Num(Ask(C_AuctionHouse.GetCommoditySearchResultsQuantity, itemID))
  if type(first) == "table" then
    NotePrice(itemID, first.unitPrice, quantity)
  end
end

-- Your professions' recipes (your own window, not a linked one): product, amount, reagents, colour at your skill.
local DIFFICULTY = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }
function ns.Recipes()
  if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeSchematic) then
    return
  end
  if C_TradeSkillUI.IsTradeSkillReady and not Ask(C_TradeSkillUI.IsTradeSkillReady) then
    return
  end
  for _, name in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsNPCCrafting", "IsTradeSkillGuildMember" }) do
    if C_TradeSkillUI[name] and Ask(C_TradeSkillUI[name]) then
      return
    end
  end
  local base = Ask(C_TradeSkillUI.GetBaseProfessionInfo)
  local profession = type(base) == "table" and Str(base.professionName) or nil
  local skill = type(base) == "table" and Num(base.skillLevel) or nil
  for _, recipeID in ipairs(Ask(C_TradeSkillUI.GetAllRecipeIDs) or {}) do
    recipeID = Num(recipeID)
    local info = recipeID and Ask(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if type(info) == "table" and not Plain(info.isDummyRecipe) then
      local recipe = Table(Table(DB, "recipes"), recipeID)
      recipe.name = Str(info.name) or recipe.name
      recipe.profession = profession or recipe.profession
      local schematic = Ask(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
      if type(schematic) == "table" then
        recipe.product = Num(schematic.outputItemID) or recipe.product
        recipe.makesMin, recipe.makesMax = Num(schematic.quantityMin), Num(schematic.quantityMax)
        local reagents = {}
        for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
          local first = type(slot) == "table" and slot.reagents and slot.reagents[1]
          local itemID = type(first) == "table" and Num(first.itemID)
          if itemID then
            reagents[#reagents + 1] = { item = itemID, count = Num(slot.quantityRequired) or 1 }
          end
        end
        if #reagents > 0 then
          recipe.reagents = reagents
        end
      end
      -- its colour at your skill: the merge reads where it turns yellow / green / grey from these
      local difficulty = Num(info.relativeDifficulty)
      if skill and difficulty and Plain(info.learned) then
        Table(recipe, "colors")[skill] = DIFFICULTY[difficulty] or difficulty
      end
    end
  end
end

-- Ordinary creatures' respawn: where you looted one (this session), then the same kind alive next to you at that
-- spot: the wait is the most it took to come back; the shortest wait seen is kept.
local kills = {} -- [npcID] = { { t, map, x, y }, ... }
function ns.NoteKill(npcID, map, x, y)
  if not (map and x and y) then
    return
  end
  local list = kills[npcID] or {}
  kills[npcID] = list
  if #list >= 20 then
    table.remove(list, 1)
  end
  list[#list + 1] = { t = Now(), map = map, x = x, y = y }
end

function ns.SeenAlive(npcID)
  local list = kills[npcID]
  if not list then
    return
  end
  local map, x, y = ns.Here()
  if not map then
    return
  end
  for index = #list, 1, -1 do
    local kill = list[index]
    local dx, dy = kill.x - x, kill.y - y
    if kill.map == map and dx * dx + dy * dy <= 1 and Now() - kill.t >= 30 then
      local npc = Npc(npcID)
      local wait = Now() - kill.t
      npc.respawnSeen = math.min(npc.respawnSeen or wait, wait)
      table.remove(list, index)
      return
    end
  end
end

-- A flight point discovered: the flight master you are talking to (or the last one you met there).
function ns.NewFlightPath(text)
  text = Str(text)
  if not (text and type(ERR_NEWTAXIPATH) == "string" and text == ERR_NEWTAXIPATH) then
    return
  end
  local kind, id = ns.ParseGUID(Ask(UnitGUID, "npc"))
  if kind == "npc" then
    Npc(id).discoversFlightPath = true
  end
  local map, x, y = ns.Here()
  if map then
    ns.AddSpot(Table(DB, "flightPathsFound"), map, x, y)
  end
end

-- Letters from NPCs and the game (never a player's: a letter you can reply to is a player's; auction house
-- invoices are skipped too). The text only of a letter already read (reading one marks it read).
function ns.Mail()
  local count = Num(Ask(GetInboxNumItems)) or 0
  for index = 1, count do
    local _, _, sender, subject, money, _, _, itemCount, wasRead, _, _, canReply, isGM = Ask(GetInboxHeaderInfo, index)
    sender, subject = Str(sender), Str(subject)
    local invoice = Ask(GetInboxInvoiceInfo, index)
    if sender and subject and Bool(canReply) == false and not Bool(isGM) and not Str(invoice) then
      local letter = Table(Table(DB, "mail"), sender .. ": " .. subject)
      letter.sender, letter.subject = sender, subject
      letter.money = Num(money) and Num(money) > 0 and Num(money) or letter.money
      if Bool(wasRead) then
        letter.text = Str((Ask(GetInboxText, index))) or letter.text
      end
      local items = {}
      for slot = 1, math.min(Num(itemCount) or 0, 12) do
        local _, itemID, _, n = Ask(GetInboxItem, index, slot)
        if Num(itemID) then
          items[#items + 1] = { item = Num(itemID), count = Num(n) or 1 }
        end
      end
      letter.items = #items > 0 and items or letter.items
      letter.seen = Now()
    end
  end
end

-- Graveyards: you came back as a ghost here.
function ns.Alive()
  if Bool(Ask(UnitIsGhost, "player")) then
    local map, x, y = ns.Here()
    if map then
      ns.AddSpot(Table(DB, "graveyards"), map, x, y)
    end
  end
end

-- Events ----------------------------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local HANDLERS = {
  ADDON_LOADED = function(name)
    if name ~= addonName then
      return
    end
    TylesserCollectorDB = type(TylesserCollectorDB) == "table" and TylesserCollectorDB or {}
    DB = TylesserCollectorDB
    DB.version = 1
    DB.started = DB.started or Now()
    -- an anonymous ID for this install (random, tied to no account or character): the uploads of one install
    -- replace each other on tylesser.com, so a file that grows week after week is never counted twice
    if type(DB.install) ~= "string" or #DB.install < 16 then
      local digits = {}
      for i = 1, 24 do
        digits[i] = ("%x"):format(math.random(0, 15))
      end
      DB.install = table.concat(digits)
    end
    DB.addonVersion = Str(C_AddOns and C_AddOns.GetAddOnMetadata and Ask(C_AddOns.GetAddOnMetadata, addonName, "Version"))
    local version, build, _, interface = Ask(GetBuildInfo)
    DB.client = { version = Str(version), build = Str(build) or Num(build), interface = Num(interface),
      locale = Str(Ask(GetLocale)) }
    ns.DB = DB
  end,
  PLAYER_TARGET_CHANGED = function()
    -- next to it (interact distance, out of combat only): a spot too
    local near = not Ask(InCombatLockdown) and Ask(CheckInteractDistance, "target", 3) == true
    local kind, id = ns.NoteUnit("target", near)
    if near and kind == "npc" and Bool(Ask(UnitIsDead, "target")) == false then
      ns.SeenAlive(id)
    end
  end,
  UPDATE_MOUSEOVER_UNIT = function()
    ns.NoteUnit("mouseover", false)
  end,
  NAME_PLATE_UNIT_ADDED = function(unit)
    if not Ask(InCombatLockdown) then
      ns.NoteUnit(unit, false)
    end
  end,
  PLAYER_SOFT_INTERACT_CHANGED = function()
    if not Ask(InCombatLockdown) then
      ns.NoteUnit("softinteract", true)
    end
  end,
  GOSSIP_SHOW = function()
    ns.OptionLed("page")
    ns.Gossip()
  end,
  GOSSIP_CLOSED = function() ns.OptionLed("closes") end,
  MAIL_INBOX_UPDATE = function() ns.Mail() end,
  UI_INFO_MESSAGE = function(_, text) ns.NewFlightPath(text) end,
  QUEST_DETAIL = function(startItemID)
    ns.OptionLed("quest:" .. tostring(Num(Ask(GetQuestID)) or "?"))
    ns.QuestDetail(startItemID)
  end,
  QUEST_ACCEPTED = function(a, b) ns.QuestAccepted(b or a) end, -- (questLogIndex, questID) on older builds
  QUEST_PROGRESS = function() ns.QuestEnd("progress") end,
  QUEST_COMPLETE = function() ns.QuestEnd("complete") end,
  QUEST_TURNED_IN = function(questID, xp, money) ns.QuestTurnedIn(questID, xp, money) end,
  QUEST_LOG_UPDATE = function()
    if not ns.progressQueued and C_Timer and C_Timer.After then
      ns.progressQueued = true
      C_Timer.After(0.5, function()
        ns.progressQueued = false
        if not paused and DB then
          ns.QuestProgress()
        end
      end)
    end
  end,
  MERCHANT_SHOW = function()
    ns.OptionLed("vendor")
    ns.Merchant()
  end,
  TRAINER_SHOW = function()
    ns.OptionLed("trainer")
    ns.Trainer()
  end,
  TRAINER_UPDATE = function() ns.Trainer() end,
  TAXIMAP_OPENED = function()
    ns.OptionLed("flight map")
    ns.Taxi()
    ns.TaxiRoutes()
  end,
  LOOT_READY = function() ns.Loot() end,
  LOOT_CLOSED = function() ns.LootClosed() end,
  UNIT_SPELLCAST_SUCCEEDED = function(unit, _, spellID)
    unit = Str(unit)
    if unit == "player" then
      ns.PlayerCast(spellID)
    elseif unit then
      ns.UnitCast(unit, spellID)
    end
  end,
  CHAT_MSG_COMBAT_XP_GAIN = function(text) ns.XPLine(text) end,
  CHAT_MSG_COMBAT_FACTION_CHANGE = function(text) ns.FactionLine(text) end,
  CHAT_MSG_SYSTEM = function(text) ns.SystemLine(text) end,
  PLAYER_ENTERING_WORLD = function()
    ns.WhereAmI()
    ns.FillTitles()
    ns.Arrived()
    ns.MapPOIs()
  end,
  UI_ERROR_MESSAGE = function(_, text) ns.ErrorLine(text) end,
  ZONE_CHANGED_NEW_AREA = function()
    ns.WhereAmI()
    ns.Arrived()
    ns.MapPOIs()
  end,
  ENCOUNTER_END = function(...) ns.EncounterEnd(...) end,
  PLAYER_ALIVE = function() ns.Alive() end,
  PLAYER_CONTROL_GAINED = function() ns.Landed() end,
  MAIL_SHOW = function() ns.NoteUnit("npc", true, "mail") end,
  BANKFRAME_OPENED = function()
    ns.OptionLed("bank")
    ns.NoteUnit("npc", true, "bank")
  end,
  AUCTION_HOUSE_SHOW = function()
    ns.OptionLed("auction house")
    ns.NoteUnit("npc", true, "auction")
  end,
  PET_STABLE_SHOW = function()
    ns.OptionLed("stable")
    ns.NoteUnit("npc", true, "stable")
  end,
  GUILDBANKFRAME_OPENED = function() ns.NoteUnit("npc", true, "guildbank") end,
  CONFIRM_BINDER = function(area)
    ns.OptionLed("bind here")
    local _, id, npc = ns.NoteUnit("npc", true, "inn")
    if npc and Str(area) then
      npc.inn = Str(area) -- the place its inn binds you to
    end
  end,
  QUEST_GREETING = function()
    local _, _, npc = Talking()
    if npc then
      npc.greeting = Str(Ask(GetGreetingText)) or npc.greeting
    end
  end,
  VIGNETTES_UPDATED = function() ns.Vignettes() end,
  VIGNETTE_MINIMAP_UPDATED = function() ns.Vignettes() end,
  CHAT_MSG_MONSTER_SAY = function(text, sender) ns.MonsterLine("say", text, sender) end,
  CHAT_MSG_MONSTER_YELL = function(text, sender) ns.MonsterLine("yell", text, sender) end,
  CHAT_MSG_MONSTER_EMOTE = function(text, sender) ns.MonsterLine("emote", text, sender) end,
  CHAT_MSG_MONSTER_WHISPER = function(text, sender) ns.MonsterLine("whisper", text, sender) end,
  ITEM_TEXT_READY = function() ns.ReadText() end,
  ITEM_TEXT_CLOSED = function() reading = nil end,
  AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = function() ns.BrowseResults() end,
  AUCTION_HOUSE_BROWSE_RESULTS_ADDED = function() ns.BrowseResults() end,
  COMMODITY_SEARCH_RESULTS_UPDATED = function(itemID) ns.CommodityResults(itemID) end,
  TRADE_SKILL_LIST_UPDATE = function()
    if not ns.recipesQueued and C_Timer and C_Timer.After then
      ns.recipesQueued = true
      C_Timer.After(1, function()
        ns.recipesQueued = false
        if not paused and DB then
          pcall(ns.Recipes)
        end
      end)
    end
  end,
  CONFIRM_XP_LOSS = function()
    ns.OptionLed("resurrect")
    ns.NoteUnit("npc", true, "spirithealer")
  end,
}
ns.HANDLERS = HANDLERS
frame:SetScript("OnEvent", function(_, event, ...)
  if event ~= "ADDON_LOADED" and (paused or not DB) then
    return
  end
  local ok, err = pcall(HANDLERS[event], ...)
  if not ok and DB then
    -- never in the player's way: the error is kept for the tools, not shown
    local errors = Table(DB, "errors")
    if #errors < 50 then
      errors[#errors + 1] = event .. ": " .. tostring(err)
    end
  end
end)
for event in pairs(HANDLERS) do
  pcall(frame.RegisterEvent, frame, event) -- (an event this build doesn't have is left out)
end
-- post hooks only (they change nothing of the game's): containers opened, a flight taken
if C_Container and type(C_Container.UseContainerItem) == "function" then
  hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
    if not paused and DB then
      pcall(ns.UsedItem, bag, slot)
    end
  end)
end
if C_GossipInfo and type(C_GossipInfo.SelectOption) == "function" then
  hooksecurefunc(C_GossipInfo, "SelectOption", function(optionID)
    if not paused and DB then
      pcall(ns.PickedOption, optionID)
    end
  end)
end
if type(TakeTaxiNode) == "function" then
  hooksecurefunc("TakeTaxiNode", function(slot)
    if not paused and DB then
      pcall(ns.TookTaxi, slot)
    end
  end)
end
if C_Timer and C_Timer.NewTicker then
  C_Timer.NewTicker(5, function()
    pcall(ns.Tick)
  end)
end

-- /tcollect -------------------------------------------------------------------------------------------------------------

local function Count(t)
  local n = 0
  for _ in pairs(type(t) == "table" and t or {}) do
    n = n + 1
  end
  return n
end

function ns.Summary()
  if not DB then
    return "not loaded"
  end
  return ("%d NPCs, %d objects, %d quests, %d vendors, %d trainers, %d loot sources, %d flight points, "
    .. "%d instances, %d bosses, %d flights timed, %d rares / treasures, %d recipes, %d prices, %d texts%s"):format(
    Count(DB.npcs), Count(DB.objects), Count(DB.quests), Count(DB.vendors), Count(DB.trainers), Count(DB.loot),
    Count(DB.taxi), Count(DB.instances), Count(DB.encounters), Count(DB.flights), Count(DB.vignettes),
    Count(DB.recipes), Count(DB.prices), Count(DB.texts), paused and " (paused)" or "")
end

local function Say(text)
  print("|cffc8a25aTylesser Collector:|r " .. text)
end

-- Sharing: the game writes the file on /reload or logout; players upload it on tylesser.com (an addon can't send).
ns.UPLOAD_URL = "https://tylesser.com/collect/"
function ns.ShowUpload()
  local text = "Type /reload first so the game saves it, then upload this file on the page:\n"
    .. "World of Warcraft\\_forever_\\WTF\\Account\\<your account>\\SavedVariables\\TylesserCollector.lua"
  if ns.T and ns.T.ShowLink then
    ns.T.ShowLink(ns.UPLOAD_URL, text)
  else
    Say("upload your file on " .. ns.UPLOAD_URL)
  end
end

function ns.IsPaused()
  return paused
end

function ns.SetPaused(on)
  paused = on and true or false
end

SLASH_TYLESSERCOLLECTOR1 = "/tcollect"
SlashCmdList.TYLESSERCOLLECTOR = function(message)
  local command = (message or ""):lower():match("^%s*(.-)%s*$")
  if command == "pause" then
    paused = true
    Say("paused. /tcollect resume to go on.")
  elseif command == "resume" then
    paused = false
    Say("collecting again.")
  elseif command == "reset yes" then
    for key in pairs(DB or {}) do
      DB[key] = nil
    end
    HANDLERS.ADDON_LOADED(addonName)
    Say("emptied.")
  elseif command == "reset" then
    Say("type /tcollect reset yes to empty everything collected.")
  elseif command == "upload" then
    ns.ShowUpload()
  elseif command == "id" then
    -- the anonymous install ID: what to send to have your uploaded files removed from tylesser.com
    if ns.T and ns.T.ShowLink and DB and DB.install then
      ns.T.ShowLink(DB.install, "Your anonymous install ID (send it through /tcollect feedback to have your uploads removed):")
    else
      Say("install ID: " .. tostring(DB and DB.install))
    end
  elseif command == "feedback" and ns.T then
    ns.T.ShowFeedback()
  elseif command == "status" or not ns.view then
    Say(ns.Summary() .. ". Saved on /reload or logout. /tcollect | status | upload | id | pause | resume | reset | feedback")
  else
    ns.view.Toggle() -- the window (UI.lua)
  end
end
