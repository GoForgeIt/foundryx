# DESIGN.md — FoundryX (Grain design system, Swift platform)

Source of truth is the Grain package (`../grain/platforms/grain-swift`), consumed
as tokens + components. This file maps them for design work. All colors are
dynamic (light/dark follow the iOS system setting).

## Color
- Surfaces: `GrainColor.surface` / `surfaceSunken` / `surfaceElevated` /
  `surfaceOverlay` (paper-warm neutrals, brand-tinted; never #fff/#000).
- Ink: `ink` / `inkEmphasis` / `inkSecondary` / `inkTertiary`; muted text via
  `textMuted` / `textFaint`.
- Brand accent: `forgeBlue` (+ `forgeBlueBg`, `forgeBlueBorder`, `forgeBlueVivid`).
  Strategy: RESTRAINED in product surfaces (accent ≤10%); COMMITTED on brand
  islands (onboarding/sign-in may let forgeBlue carry the moment).
- Support: `sage` (success/voice), `amber` (attention), `dangerRed` (destructive),
  agent palette (`agentOrchestrator` lavender, `agentSpecialist` pink,
  `agentWorker` mint) — used for speaker identity colors.

## Typography
- `grainTextStyle(.title/.body/.caption)`; families via GrainFont (sans default,
  serif + mono available). Dynamic Type respected (`relativeTo`).
- Hierarchy by scale + weight; body measure stays phone-narrow.

## Spacing / radius
- `GrainSpacing`: x1=4 x2=8 x3=12 x4=16 x6=24 x8=32 x12=48 x16=64 x24=96.
  NO x5. Vary rhythm; don't equal-pad everything.
- `GrainRadius`: sm/md/lg/pill; continuous corners on containers.

## Motion (GrainMotion)
- `fast` / `normal` / `slow` with `standard` easing; `enter` uses decelerate.
- House rules: exponential ease-outs, no bounce/elastic, respect Reduce Motion
  (`accessibilityReduceMotion`) with cross-fades as fallback.
- Signature moves: the resting-breath pulse (~4s, BreathingMark), live-transcript
  words fading in, speaker-accent underlines. Spring only for physical gestures.

## Components
- GrainButton (variants: filled / tonal / outlined / text / ghost; sizes sm/regular).
- GrainTextField, GrainSheetContainer, grainBackground().
- Speaker palette maps slot → (accent, tint) pairs (SpeakerTranscriptView).

## Surfaces of note
- Capture screen: live transcript + level meter (hero).
- Conversation detail: turns, speaker tags, Listen.
- Onboarding flow (brand island): full-screen, breathing mark, read-aloud card.
- Settings: List-based, honest captions under every control.
