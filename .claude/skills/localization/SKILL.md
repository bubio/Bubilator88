---
name: localization
description: How UI strings are localized in this repository — String Catalogs, the key-is-the-English-string rule, extracting missing keys after a build, and how Bubilator88Core reports localizable errors. Use when adding, changing or translating user-facing strings.
---

# Localization

UI strings live in String Catalogs: `Bubilator88/Resources/Localizable.xcstrings`
and `InfoPlist.xcstrings`. English is the source language and has no
localization entries — it falls back to the key itself, so **the key is the
English string**. Japanese is the only translated language.

Call sites use `String(localized:comment:)`; SwiftUI views rely on
`LocalizedStringKey` literals in `Text`/`Button`/`.help`.
`scripts/strings_to_xcstrings.py` converts legacy `.strings` files if one ever
reappears.

A command-line build never fills the catalog in — only opening it in Xcode's
editor does. Use **`scripts/extract_loc_keys.py --missing`** after a build to
list keys the compiler extracted but the catalog lacks. It reads the
`.stringsdata` that `SWIFT_EMIT_LOC_STRINGS = YES` emits, so it reports the
*exact* key, including the format specifiers SwiftUI derives from interpolation
(`Text("FM \(ch + 1): muted")` → `"FM %lld: muted"`). Guessing those by hand
ships strings that silently never resolve.

Bubilator88Core itself has no localization. `Script.swift` / `ScriptPlayer.swift`
therefore raise errors carrying an English **format string plus arguments**, and
the app layer translates them through the catalog
(`ViewModel/ScriptErrorLocalization.swift`) — the format string doubles as the
catalog key.
