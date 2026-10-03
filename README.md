# Were Wolf

Were Wolf web game written entirely in Lua.

## Start Server

```bash
lua5.4 server.lua
```

## Configuring a round

The host sets everything in the lobby (rules are locked once the game starts, and kept for "Play again").

- **Roles**: switch the Doctor, Seer and Slut on or off. Werewolf and Villager are always in. The lobby shows how many of each role the current player count produces, and warns when the setup can't be dealt.
- **Rules**: werewolf count (Auto = one per four players), announce roles in play, peaceful first night, auto-advance, doctor may self-protect, no repeat targets, reveal roles of the dead, show vote counts, tied vote (no one dies / random pick), allow abstaining.

Rules live in `Game.settings_schema` in `game.lua`. The lobby UI and the validation are generated from it, so a new rule is one entry there plus a `g.settings.<key>` check where it applies. A new optional role is an entry in `Game.roles` (without `core = true`) and, if it acts at night, one in `verbs`.

## Tests

```bash
lua5.4 test.lua
```

