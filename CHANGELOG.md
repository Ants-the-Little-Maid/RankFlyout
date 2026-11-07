# Changelog

## 0.4.1 (2026-11-07)

- **Buttons are now saved per character.** Each character has its own 12 buttons, with their own spells, ranks and positions, so a rank chosen or a button removed on one character no longer changes another's. Menu direction, scale, lock, floating buttons and the minimap button stay shared.
  - Coming from 0.4.0: the first character you log in with keeps all of 0.4.0's buttons. Each other character keeps the ones its bar macros and key bindings use.
- Right-clicking a bar slot opens the menu beside that slot, even when the same macro is on more than one slot. (In combat the menu can't move, so it opens where it last was.)
- Moving over from Rank Flyout:
  - Spells with brackets in their name, such as Faerie Fire (Feral), now move correctly.
  - Two old buttons for the same spell (say Rank 1 and Rank 4) stay as two buttons instead of being merged.
  - Key bindings move only with their button's macro, so a key never lands on a button holding a different spell.
- A button keeps its chosen rank while the spellbook doesn't list its spell.
- Macro names cut to 16 characters no longer split a letter in non-English clients, and a macro that WoW stores slightly differently is edited once instead of over and over.
- Less repeated work: a rebuild updates each button and macro once, and a burst of macro changes is checked once.

## 0.4.0 (2026-11-07)

- Renamed from Rank Flyout to **Rank in File**. The addon folder is now `RankInFile`, and `/rankinfile` replaces `/rankflyout`. `/rf` is unchanged.
- Moving over: on each character, Rank in File finds Rank Flyout's bar macros and turns each one back into a button, keeping its rank. The macros stay in the same bar slots and now click the new buttons. Rank Flyout key bindings move across too. Other settings (positions, menu direction, scale) start fresh, and floating buttons start hidden (`/rf float on`). If Rank Flyout is still enabled, nothing moves until it is disabled.

## 0.3.1 (2026-11-06)

- Fixed a flood of Lua errors in dungeons. Inside instances WoW hides cooldown times from addons as "secret" values, and Rank Flyout passed them straight to the cooldown swipe. Cooldowns now go through WoW's duration objects, which addons are allowed to use there. If those aren't available, the swipe is just left blank.
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
