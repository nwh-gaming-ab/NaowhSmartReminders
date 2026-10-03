# Smart Reminders localization

`enUS.lua` is the source catalog. Its keys are the English strings used by the
addon; `true` means the English key is also the displayed value.

To add a language:

1. Copy `deDE.lua` and name the copy with the WoW locale code, such as
   `frFR.lua` or `ptBR.lua`.
2. Translate the values on the right and retain every key exactly.
3. Add the file to `NaowhSmartReminders.toc` with an
   `AllowLoadTextLocale` condition.

Use `ns.L("English text")` for new player-facing text. It falls back to the
English text if the active locale has not translated that key. Keep spell and
item logic on IDs; Blizzard supplies their localized display names.
