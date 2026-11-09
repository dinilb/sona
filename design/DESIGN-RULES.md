# Sona design rules (builders: follow these, they beat your defaults)

Goal: ultra clean, minimal, native iOS 26. Looks like an Apple app, not an AI template. When unsure, do less.

## 1. The look
- Native SwiftUI only. System components first (NavigationStack, List, Form, TabView, toolbar, sheet, Menu). Build custom only when no system one exists.
- Monochrome: `.primary`, `.secondary`, `.tertiary`, system backgrounds (`systemBackground`, `secondarySystemBackground`). No brand colour. Don't set `.tint` on the app.
- System red (`Color.red` / `SonaTheme.accent`) only for recording: record button, live wave, Stop. Nowhere else, not even errors or badges. Destructive actions use the system `role: .destructive`.
- Font: SF Pro via Dynamic Type styles only. New York (`.design(.serif)`) only for a note's title. No other font, no monospace labels.
- Liquid Glass (iOS 26): comes free from system bars, tab bars, sheets and `.buttonStyle(.glass)`. Use `.glassEffect` only on floating controls over content (e.g. the record button), grouped in one `GlassEffectContainer`. Never glass on content, rows, or glass on glass. Tint glass only for the one primary action. Source: Dimillian swiftui-liquid-glass.
- Icons: SF Symbols only, one weight (regular), monochrome rendering. No emoji, no custom icon packs.
- Light and dark must both work with system colours. No hard-coded hex.

## 2. Type scale (Dynamic Type, iOS default Large sizes, pt/weight)
Large Title 34 regular (top-level screen title only) / Title 28 / Title2 22 / Title3 20 / Headline 17 semibold / Body 17 / Callout 16 / Subheadline 15 / Footnote 13 / Caption 12 / Caption2 11.
- Use `.font(.body)` etc. Never `.font(.system(size: 17))`. Must survive Accessibility sizes (test XXL): wrap, don't truncate, use `ViewThatFits` or `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` caps only for fixed chrome.
- Max 3 text levels per screen: title, body, secondary (`.secondary`, footnote). Weight for emphasis (regular/semibold only), not size or colour.
- No ALL CAPS, no tracking, no letter-spaced eyebrows. Section headers use the List/Form default.
- Numbers (durations, times): `.monospacedDigit()` so they don't jitter.

## 3. Spacing and shape (4pt grid)
- Scale: 4, 8, 12, 16, 24, 32, 48. Nothing else.
- Screen edge margin 16pt (use the system default; don't set your own on List/Form). Related items 8, groups 24, sections 32.
- Minimum tap target 44x44pt. Primary full-width button height 50, corner = capsule or system `.borderedProminent`.
- Radius: use system shapes (`.rect(cornerRadius: .containerConcentric)`, `Capsule`, `ConcentricRectangle` where available). One radius family per screen. No 20-24pt on everything.
- Respect safe areas. Bottom primary actions sit in the toolbar or safe-area inset, not a hand-positioned floating pill.
- Top-align data screens. Centre only empty states and onboarding.

## 4. AI-slop tells: banned, with the fix
- Gradients, glows, blurred blobs, coloured shadows, neon accents (orange, purple, indigo, acid green). Fix: flat system colours. Zero shadows except system ones.
- Cards in cards, grey background with white rounded cards, identical card grids, "three feature cards". Fix: grouped `List`/`Form`, whitespace, hairline `Divider`.
- Emoji anywhere (icons, greetings, empty states, copy). Fix: SF Symbols or nothing.
- Everything centred, hero + stat triplet on home. Fix: left-aligned content, lead with the notes list.
- Tinted rounded-square icon chip on every row. Fix: bare symbol or none.
- Pills and "NEW"/badge confetti. Max one status mark per row and only for real state.
- Chevrons on rows that don't push a screen. Custom back button duplicating the system one. Hamburger menus. Hand-rolled modals (use `.sheet`).
- Blur on everything, material-on-material, full-width floating CTA at a fixed offset.
- Entrance animations on every element, hover/press effects as decoration, haptics on every tap. Motion only answers a tap (sheet, expand, confirm); use system springs (`.snappy`, `.smooth`), respect Reduce Motion.
- One word in a headline bolded/coloured; spaced-em-dash labels ("WORD — thing"); middle-dot strings ("A · B · C"); arrows on button text.
- Spinner-only loading (use placeholders/redacted), missing empty/error states, dead settings (a toggle must be read somewhere).
- Fake data: invented stats, placeholder names, lorem ipsum. Use real content or show nothing.
Sources: draftbit/mobile-taste-skill (42 tells), wwewtech/anti-slop-design.

## 5. Onboarding (first run)
What Apple-style flows do: 1 to 3 screens, under 30 seconds, value first, skippable, no account wall, no feature tour.
- Screen 1 (the only required one): "Welcome to Sona". App icon (or one SF Symbol) top, large title, 2 to 3 feature rows (SF Symbol left, bold short title, one grey line) left-aligned in the middle, one prominent `Continue` button pinned to the bottom. This is the pattern Apple uses in Stocks, Journal and What's New sheets.
- Screen 2 (microphone): permission priming. One sentence on why ("Sona needs the microphone to record. Audio stays on your phone."), one button `Allow microphone`, which triggers the system prompt only on tap. Never fire system prompts on launch. Ask other permissions (notifications, speech) at the moment they're needed, not in the flow.
- If denied: app stays usable, plain line plus `Open Settings`. Never nag.
- Layout: one primary button (`.borderedProminent`, monochrome tint, 50pt, full width, 16pt margins). Secondary action is plain text (`Not now`), never a second filled button.
- Motion: none beyond the system push/sheet transition. No confetti, no looping animation, no parallax. No page dots carousel.
- After the last step land directly on the real empty state with one record action. Don't show a "you're all set" screen.
- Ask nothing you can infer. No name, goals or survey questions.

## 6. Copy
- Sentence case everywhere. No Title Case Buttons, no ALL CAPS.
- Short, plain, concrete. Buttons are verbs ("Record", "Stop", "Delete note"), same word through the whole flow.
- No exclamation marks, no emoji, no em dashes, no hype or filler: banned words: seamless, effortless, powerful, supercharge, unlock, magic, smart, intelligent, AI-powered, "your all-in-one", delightful, "get started", "let's go".
- Don't greet ("Welcome back, Alex!"). Don't narrate ("Here's what's new").
- Empty states say what to do: "No notes yet. Tap Record to start." Errors say what happened and the fix, no apology ("Couldn't save. Check storage and try again.").
- Say what users get, not how it's built ("Notes", not "transcript objects").

## 7. Check before you report done
Screenshot light + dark + XXL Dynamic Type + Reduce Motion. Count colours (should be greys + red during recording only). Count accent uses of red. Search the diff for `LinearGradient`, `.shadow`, `.blur`, emoji, hex colours, `.font(.system(size:`.

## 8. Sources, reusable resources, licences
Further reading:
1. draftbit/mobile-taste-skill, MIT: https://github.com/draftbit/mobile-taste-skill (42 mobile tells in `skills/_shared/references/tells.md`; written for React Native, but most of it applies to SwiftUI). Related, also MIT: https://github.com/wwewtech/anti-slop-design (12 banned tropes).
2. Dimillian's SwiftUI Liquid Glass notes: https://github.com/Dimillian/Skills/blob/main/swiftui-liquid-glass/SKILL.md (glass API rules and a review checklist; no licence file seen, so read only).

Resources:
- Apple Design Resources (iOS/iPadOS 26 and newer 27 kits, Figma + Sketch, free): https://developer.apple.com/design/resources/ (Apple licence: for designing apps for Apple platforms only, don't redistribute).
- SF Symbols app (free, Apple licence, use in apps for Apple platforms only): https://developer.apple.com/sf-symbols/
- HIG: Typography, Materials (Liquid Glass), Onboarding, Privacy / requesting permission, Color: https://developer.apple.com/design/human-interface-guidelines/
- Open-source SwiftUI glass helpers, MIT, optional: https://github.com/metneo/LiquidGlass, https://github.com/muhittincamdali/LiquidGlassKit. Prefer plain system APIs; add a dependency only if it saves real work.

Check type sizes and the onboarding and Liquid Glass guidance against the HIG on developer.apple.com before relying on exact numbers.
