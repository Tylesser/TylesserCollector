# Tylesser - Collector

Records WoW Forever game data while the player plays (2026-11-24; private at first, public on the stores since the
user's "lets put collector addon to store and let them post to tylesser.com"). Forever only (Interface 16001).
Players upload `SavedVariables/TylesserCollector.lua` on https://tylesser.com/collect/ (tylesser-site `upload/`); the
Tylesser - Data addon (`Addons/TylesserData`, its `build/collect.py`) is built weekly from every install's newest file.

- `Collector.lua`: the events and what each records (the header lists every kind). Rules: every value goes through
  `Plain` / `Num` / `Str` / `Bool` (secret values are skipped, never compared or joined); **never a player**: only
  Creature / Vehicle / GameObject GUIDs are parsed (`ns.ParseGUID`), mail you can reply to is a player's and skipped;
  errors inside a handler go to `TylesserCollectorDB.errors`, never on screen. Post hooks only
  (`C_Container.UseContainerItem`, `TakeTaxiNode`, `C_GossipInfo.SelectOption`).
- `DB.install`: an anonymous random ID per install (24 hex digits), so the uploads of one install replace each other
  (a growing file is never counted twice) and a player can ask for removal (`/tcollect id`).
- `UI.lua`: the `/tcollect` window (kinds, searchable list, details, Show on map, Upload, Pause).
- `Tylesser.lua` and `Media/` are the shared Tylesser look: identical in every addon (md5).
- Tests (outside the repo): `node tools/harness/run.js collector_test.lua E:/Games/Wow/Addons/TylesserCollector`
  (records a whole game-like session, prints it as `SAVEDFILE:` for the chain test) and
  `python -I tools/collector/test_collect.py` (merge + build + the data addon's API, including that saved file).
- The store IDs (`X-Curse-Project-ID`, `X-Wago-ID`) come from the user once the projects exist.
