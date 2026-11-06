# Changelog

## 0.3.1 (2026-11-06)

- Fixed a flood of Lua errors in dungeons (reported in Shadowfang Keep). Inside instances WoW hides cooldown times from addons as "secret" values, and Rank Flyout passed them straight to the cooldown swipe. Cooldowns now go through WoW's duration objects, which addons are allowed to use there. If those aren't available, the swipe is just left blank.
- The usable and range tint ignores secret answers instead of reading them.

## 0.3.0 (2026-11-06)

- Spell picker: a spellbook-style window (minimap button or `/rf spells`) with a tab per school. Click or drag a spell to put its macro on your cursor, ready for an action bar slot. Right-click an added spell to remove it. Spells can also be dropped onto the picker from the spellbook or bars.
- Minimap button: left-click opens the picker, right-click opens settings, drag to move. `/rf minimap on | off`.
- All earlier commands still work.

## 0.2.0 (2026-11-06)

- Drag a Rank Flyout button onto an action bar to drop a macro there. The slot's own hotkey casts the chosen rank, and right-clicking the slot opens the rank menu beside it.
- The slot shows the rank's icon, tooltip, cooldown and range, labelled "Rank 3".
- `/rf macro <n>` and `/rf float on | off`.

## 0.1.0 (2026-11-06)

- Secure buttons that hold one rank of a spell, with a pop-out menu for swapping ranks, even in combat.
