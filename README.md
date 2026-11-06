# Rank Flyout

Action buttons for **WoW Forever** that hold one rank of a spell, with a pop-out menu for
swapping ranks, including during combat.

## Spell picker and minimap button

Click the **minimap button** (book icon), or type `/rf spells`, to open the spell picker.
It looks like the spellbook: one tab per spell school, two columns of spells, with pages.

- **Click or drag a spell**: Rank Flyout makes its macro and puts it on your cursor. Click an
  action bar slot to place it. Spells you've added get a green tick and their button number.
- **Right-click** an added spell to remove it, along with its macro.
- **Drop a spell** from Blizzard's spellbook or your bars onto the picker to do the same.
- **"Only spells with more than one rank"** hides spells that have a single rank.
- The bottom bar has the **Floating buttons**, **Lock** and **Menu opens** settings.

Minimap button: left-click opens the picker, right-click opens settings, and dragging moves it
around the minimap. `/rf minimap off` hides it.

## Using it

1. Type `/rf add Frostbolt` (or `/rf add` and drop a spell from your spellbook onto the new button).
2. **Drag the button onto any action bar slot.** That drops a macro there, so the slot's
   normal hotkey casts it. No extra key bindings needed.
3. On the bar slot (or the floating button):
   - **Click or hotkey** casts the chosen rank.
   - **Right-click** opens the rank menu beside the slot.
     - Left-click a rank: use that rank from now on.
     - Right-click a rank: cast that rank once, without changing the choice.
4. `/rf float off` hides the floating buttons once your macros are on bars.
5. **Shift-drag** moves a floating button. `/rf lock` stops moving.

The bar slot shows the chosen rank's icon, tooltip, cooldown and range, and its label reads
"Rank 3". If you swap ranks during combat, the cast changes straight away, but the slot's
icon, label and tooltip catch up when combat ends (WoW blocks editing macros in combat).

Each button uses one per-character macro (it falls back to an account macro if your 30
character slots are full). `/rf remove` deletes it.

If you choose the highest rank, the button moves up to new ranks as you learn them.
If you choose a lower rank, it stays on that rank.

| Command | Does |
|---|---|
| `/rf spells` | Open or close the spell picker |
| `/rf minimap on\|off` | Show or hide the minimap button |
| `/rf add [spell]` | New button (up to 12) |
| `/rf macro <n>` | Put button n's macro on your cursor, to click into a bar slot |
| `/rf float on\|off` | Show or hide the floating buttons |
| `/rf set <n> <spell>` | Change what button n holds |
| `/rf remove <n>` | Remove button n |
| `/rf list` | List buttons and their chosen ranks |
| `/rf lock` / `/rf unlock` | Stop or allow Shift-drag moving |
| `/rf dir up\|down\|left\|right` | Which way the menu opens |
| `/rf scale <0.5-2>` | Button size |
| `/rf reset` | Move buttons back to the middle of the screen |

Adding, removing and moving buttons only work out of combat. Choosing ranks works anywhere.

## How it works

- The bar macro is:
  ```
  #showtooltip Frostbolt(Rank 3)
  /click [btn:2] RankFlyoutButton1 RightButton; RankFlyoutButton1
  ```
  Forever's `/click` calls `button:Click(mouseButton, down)` once, with `down = false`
  unless the macro says otherwise. The buttons set `useOnKeyDown = false` so that single
  click casts whatever the "cast on key down" option is.
- The menu is parented to `UIParent` and, out of combat, anchored beside the bar slot that
  holds the button's macro (Blizzard bars, Bartender4 and Dominos), or else the floating
  button. A macro slot reports either the macro index or (subType `"spell"`) the spell it
  shows, so a slot only matches on our macro index, or on one of our rank IDs plus our
  macro's name.
- "Hidden" floating buttons stay shown at alpha 0 with the mouse off, so `/click` and key
  bindings still reach them.
- Each button is a `SecureActionButtonTemplate` button with `type = "spell"` and the rank's
  spell ID in `spell`. Blizzard's `SECURE_ACTIONS.spell` casts a numeric value with `CastSpellByID`.
- Rank choice is changed by secure snippets wrapped onto `OnClick` (`SecureHandlerWrapScript`),
  so it works under combat lockdown. The menu is a protected frame the snippets show and hide.
- Ranks come from a scan of the player spellbook: every learned, non-passive entry with the same
  name. Lower ranks are real spellbook items; Blizzard's spellbook only hides them unless the
  `ShowAllSpellRanks` option is on (`C_SpellBook.IsSpellBookItemLowRank`).
- The spellbook is rescanned on `SPELLS_CHANGED` and `LEARNED_SPELL_IN_SKILL_LINE`. If that
  happens in combat, the rescan waits until combat ends.
- Cooldowns: `isActive` (never secret) decides whether to show one. Plain times go to
  `SetCooldown`, as in 0.2.0. In instances the start and duration times are secret, and
  `SetCooldown` rejects secret values from addon code (it is `AllowedWhenUntainted`), so
  those go through `C_Spell.GetSpellCooldownDuration` and `SetCooldownFromDurationObject`.
  An unexpected error clears the swipe and is reported once per session, not on every event.
- The usable/range tint checks `issecretvalue` and leaves the icon white for secret answers.

## Target and evidence

- Target: Forever only, interface `16001`.
- Source checked: Gethe/wow-ui-source `forever` branch at
  `eac30af597e5aaa43a60f6675ef5fdcea100375f` (1.60.1.70790, the installed build on 2026-11-06).
- Every widget method and spell/spellbook API the addon calls is declared in that commit's
  generated API documentation.

## Checks

| Check | Result |
|---|---|
| Lua 5.1 parse (luaparse 0.3.1), including the three secure snippets | Pass |
| Smoke test `tests/rankflyout_smoke.lua` (fengari, stubbed API, including secret values) | 91 of 91 passed (0.3.1); the 0.3.0 code fails the 3 secret-value checks |
| In the Forever client | 0.2.0 reported working by the user (2026-11-06). 0.3.0 gave a flood of errors in Shadowfang Keep (player report, no error text). 0.3.1's fix not yet run in an instance |

The user's report was overall ("works great"). The individual points below weren't
reported one by one, so recheck any that look off:

1. Secure snippets run on this build (early Forever betas had a bug here, reported fixed in 70009).
2. Casting a lower rank's spell ID casts that rank, not the highest one.
3. Rank swapping in combat.
4. The button textures (`ButtonHilight-Square`, `UI-Quickslot-Depress`, `CheckButtonHilight`,
   `Arrow-Up-Up`) exist in the Forever client.
5. Key bindings, and Shift-drag moving.
6. The bar macro: hotkey casts, right-click opens the menu beside the slot, and
   `#showtooltip Frostbolt(Rank 3)` shows that rank's icon and tooltip.
7. Dragging the floating button picks up the macro (and doesn't also cast).
8. 0.3.0 spell picker: the window, tabs, class portrait, paging, dropping spells on it,
   and that a picked spell's macro lands on the cursor ready for a bar slot.
9. 0.3.0 minimap button: the book icon, the right-click settings menu, and dragging.
10. 0.3.1: fight in a dungeon with `/console scriptErrors 1` (or BugSack). There should be no
    errors, and the cooldown swipe should still show on the bar slot and floating button.
