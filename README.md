# Tylesser - Collector

Records the **WoW Forever** game data you see while you play, so you can share it on
[tylesser.com/collect](https://tylesser.com/collect/). Everyone's files together become the
[Tylesser - Data](https://tylesser.com/tylesserdata/) addon: where NPCs stand, which quests they give, what drops where,
herbs and ore with the skill they need, rares and treasures, vendors, trainers, flight times and more.

It only listens to what the game already shows you, like any addon. It sends nothing by itself (an addon can't), and
it **never records players**: no names, realms or anything about other players, and nothing about your account.

## What it records

- **NPCs**: name, title, level, type, where they stand, what they say, their talk options and what each leads to,
  services (vendor, trainer, flight master, innkeeper, bank, mail ...).
- **Quests**: who gives and ends them, texts, objectives, rewards, required items, the creatures and items that
  count for them, quest chains, tags and zones.
- **Drops**: what creatures, chests, herbs, ore, fishing spots and containers give, and how often; skinning, pick
  pocketing and disenchanting too.
- **Gathering**: herbs and ore with the skill they need.
- **Rares and treasures** from the minimap's markers, with their exact spot.
- **Vendors** (prices, limited stock, what an item requires) and **trainers** (spells, levels, costs).
- **Travel**: flight points, routes, flight times and costs, portals.
- **Places**: sub-zones, points of interest, graveyards, dungeon entrances and bosses.
- **Recipes** of your own professions, and auction house prices you see.

## Sharing it

1. Play as usual. `/tcollect` opens a window with everything collected so far.
2. Type `/reload` (or log out): the game saves the file then.
3. Click **Upload** in the window (or type `/tcollect upload`) for the link, and upload this file on
   [tylesser.com/collect](https://tylesser.com/collect/):
   `World of Warcraft\_forever_\WTF\Account\<your account>\SavedVariables\TylesserCollector.lua`

Upload again whenever you like: your newest file replaces your older ones. The file is stored under a random ID the
addon made for your install, never with your account name. `/tcollect id` shows that ID, to have your files removed.

## Commands

| Command | Action |
| --- | --- |
| `/tcollect` | Open or close the window |
| `/tcollect upload` | The upload link and where the file is |
| `/tcollect status` | What was collected, in chat |
| `/tcollect pause` / `resume` | Stop and start collecting |
| `/tcollect reset` | Empty everything collected (asks first) |
| `/tcollect id` | Your anonymous install ID |
| `/tcollect feedback` | The link to report a bug or suggest an idea |

## Feedback

Found a bug or have an idea? Type `/tcollect feedback` in game to get the link, or go straight to
[tylesser.com/feedback](https://tylesser.com/feedback/#tylessercollector).

No GitHub account? Join the [Tylesser Discord](https://discord.gg/n2rEB6mRxF) and post in #bug-reports or #ideas with
the addon's tag; each post is copied to GitHub and the bot answers with the link.

## Installation

Install from CurseForge or Wago, or download the latest zip from
[Releases](https://github.com/Tylesser/TylesserCollector/releases) and extract it to `Interface/AddOns`. The folder must
be named `TylesserCollector`.

## More from Tylesser

Features, changelog and the other Tylesser addons are on [tylesser.com](https://tylesser.com/tylessercollector/).

## Releasing (maintainers)

Tag `vX.Y.Z` after moving the changes into a `## X.Y.Z` section of `CHANGELOG.md`; the release workflow builds the zip
and uploads it to CurseForge and Wago.

## License

MIT, see [LICENSE](LICENSE).
