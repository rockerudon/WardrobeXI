# WardrobeXI

A visual lockstyle / appearance editor for **Final Fantasy XI**, built as an
[Ashita v4](https://www.ashitaxi.com/) **addon** with an ImGui interface.

WardrobeXI lets you change how your character looks (race, face, and equipment
models) from a clean windowed UI with searchable, icon-based dropdowns, instead
of typing slash commands. It is inspired by FFXIV's
[Glamourer](https://github.com/Ottermandias/Glamourer), adapted to FFXI's
lockstyle concept.

This is a **client-side visual change only**. It does not affect your real gear,
stats, server state, or how other players see you.

## Features

- **Actor tab** – live editing of your current character: race, face, and the
  eight equipment model slots, each a searchable dropdown with item icons.
  Copy / Paste a set through the clipboard, or save it as a design.
- **Designs tab** – named appearance presets. Create empty designs, edit them
  with the same icon editor, and apply / copy / paste / clone / delete. The
  list is searchable and resizable.
- **Automation tab** – rules that auto-apply a design based on your current
  **main / sub job** (FFXI has a subjob, unlike FFXIV). `Any` matches any job
  in a slot; the first matching enabled rule wins.
- Correctly handles **multi-slot / full-body gear** (e.g. Kupo Suit) so hidden
  slots do not clip with the base body model.
- Neutral dark theme.

## Install

Copy the `WardrobeXI` folder into your Ashita addons directory:

```text
<Ashita>/addons/WardrobeXI/
```

Load it in game (or add it to your default load list):

```text
/addon load WardrobeXI
```

## Usage

| Command | Description |
| --- | --- |
| `/wardrobe` | Toggle the editor window. |
| `/wardrobe on` | Enable the appearance override. |
| `/wardrobe off` | Disable it and restore your real appearance. |
| `/wardrobe show` / `hide` | Show or hide the window. |

Aliases: `/wardrobexi`, `/wxi`.

In the window:

- **Actor**: toggle **Enable appearance override**, then pick a **Race**,
  **Face** and per-slot **Equipment**. Use **Copy** / **Paste** for the
  clipboard and **Add Design** to store the current set. **Apply** previews,
  **Restore** reverts to your real, currently-equipped look. The **X** beside a
  slot clears it back to "keep".
- **Designs**: **+ New** creates an empty design (everything "not set"). Select
  one to edit it with the same editor; anything left "(not set)" is unchanged
  when applied. Buttons: **Apply**, **Copy**, **Paste**, **Clone**, **Delete**.
  Drag the divider to resize the list, and the search box filters by name.
- **Automation**: enable it and **Add rule**. Each rule maps a main/sub job
  combination to a design. The active rule is highlighted while it applies.

> The **Actor** tab is a live working state: on load it always detects your
> real character (race, face, equipped gear), it is not saved. Only your
> **Designs** and **Automation** rules persist between sessions.

## How it works

WardrobeXI writes your character's model fields directly into the player entity
(`Race`, `Look.Hair`, and the eight `Look` equipment slots) and sets the model
update flag to force a refresh ("blink"). It also rewrites the incoming
appearance packets (zone-in `0x0A`, character update `0x0D`, appearance `0x51`)
so the server's periodic refreshes do not overwrite the override. This mirrors
the approach of the `sexchange` / `singlerace` addons and the Stylist plugin.

Equipment items have no model id stored in the client item resources, so
WardrobeXI ships a bundled lookup table (`data/models.lua`) that maps item ids
to equipment model values, generated from Stylist's `modelinfo.xml`. The
encoded model value follows the FFXI convention `baseModel + 0x1000 * slotIndex`
(head `0x1000`, body `0x2000`, and so on). Item icons are loaded from each
item's in-memory bitmap (`item.Bitmap`) as Direct3D textures, the same way the
`equipmon` addon renders equipment icons.

Full-body gear is handled with FFXI's "full body" rule: when the body model
number is `>= 256`, the hands, legs and feet slots are forced to the same model
number in their own ranges, matching what the client renders so the base body
does not clip through.

## Project layout

```text
WardrobeXI/
  WardrobeXI.lua    -- entry point, events, commands, automation tick
  appearance.lua    -- the engine (entity writes, packet rewrites, detection)
  designs.lua       -- designs + automation data helpers
  ui.lua            -- ImGui interface (Actor / Designs / Automation tabs)
  icons.lua         -- item icon texture loader/cache
  data/models.lua   -- bundled item id -> equipment model lookup table
```

## Compatibility

- Requires Ashita v4.
- Designed and tested on a private server (CatsEyeXI). Model ids come from the
  retail-derived Stylist table; some custom-server items may not have a model
  entry and will fall back to your live look.

## Credits

- Inspired by [Glamourer](https://github.com/Ottermandias/Glamourer) (FFXIV).
- Equipment model table derived from
  [Stylist](https://github.com/ThornyFFXI/Stylist)'s `modelinfo.xml`.
- Built on the [Ashita](https://www.ashitaxi.com/) addon framework.

## Support

If WardrobeXI is useful to you, you can support development here:

<a href="https://www.buymeacoffee.com/rockmizx" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="50" width="210"></a>

---

Created by **rockerudon**. Released under the MIT License (see `LICENSE`).
