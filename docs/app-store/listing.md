# Apple App Store listing — Task Monster (submission pack)

Status: **resubmitted for review 2026-08-06** ("Waiting for Review"). The
2026-07-19 submission was rejected 2026-07-29 under Guideline 2.3.6 — resolved
by setting the Age Rating In-App Controls to None (see walkthrough step 8).
Adapted from the Play submission pack
([`../play-store/listing.md`](../play-store/listing.md)).

- App Store name: **Task Monster: Chore Rewards** ("Task Monster" was taken;
  home-screen name stays "Task Monster")
- App Store Connect app ID: 6792448899
- Bundle ID: `com.darumatic.taskMonster`
- Team: DARUMATIC PTY LTD — Team ID `76UL6RCLTT`
- Version to submit: 0.0.19 (build 19), iOS deployment target 15.0
- Developer: Darumatic — hello@darumatic.com — https://darumatic.com
- Price: Free, no ads, no in-app purchases

---

## App Store Connect — App Information

| Field | Value |
|---|---|
| Name (max 30 chars) | Task Monster |
| Subtitle (max 30 chars) | Real tasks. Epic monsters. |
| Primary language | English (U.S.) |
| Primary category | Lifestyle |
| Secondary category | Productivity |
| Content rights | Does not contain third-party content |
| Age rating | 4+ (all questionnaire answers "No"/"None" — incl. In-App Controls: Parental Controls = None, Age Assurance = None; see step 8) |
| Kids Category | **Do not opt in** (see note below) |

**Kids Category note:** the app is family-friendly, but Apple's Kids Category
(Guideline 1.3) prohibits transmitting device identifiers to third-party
analytics. The app uses Google Analytics for Firebase (anonymous app-instance
ID), which is fine for a general 4+ app but risky inside the Kids Category.
Stay out of the Kids Category unless Firebase Analytics is removed.

## Promotional text (max 170 chars)

> Finish a real-life task, press the big button, and watch your mystery
> monster evolve! No ads, no accounts — a joyful reward app for families.

## Description (max 4000 chars)

Same copy as the Play full description (works unchanged):

> **Turn everyday tasks into an adventure!**
>
> Task Monster is a simple, joyful reward app for kids and families. Finish a
> real-life task — homework, tidying up, brushing teeth — then press the big
> button and watch your monster evolve with a burst of animation and sound.
>
> **🥚 Every egg is a surprise**
> Your monster starts as a mystery egg. Nobody knows what's inside! It might
> grow into a mighty dragon, a blazing phoenix, a deep-sea leviathan, a
> thundering dinosaur, or a cosmic alien — each with 15 evolution stages, from
> adorable hatchling to epic final form.
>
> **⭐ Prestige and start again**
> Reach the final stage and earn a Prestige star — then a brand-new egg
> appears with a different creature inside.
>
> **👨‍👩‍👧‍👦 Made for families**
> • A profile for each child, with their own monster and progress
> • Optional parent lock: evolutions need a grown-up's 4-digit PIN (or
>   Touch ID/Face ID) — so rewards stay honest
> • A one-minute cooldown between evolutions stops button-mashing
>
> **🔒 Private by design**
> No accounts, no sign-up, no ads. All progress is stored on your device.
>
> Task Monster is free and ad-free, made with ❤️ by Darumatic.

## Keywords (max 100 chars)

> kids,chores,rewards,tasks,family,monster,evolve,habit,children,parenting,motivation,tamagotchi

## URLs

| Field | Value |
|---|---|
| Support URL | https://task-monster.ink |
| Marketing URL (optional) | https://task-monster.ink |
| Privacy Policy URL | https://task-monster.ink/privacy.html |

## App Review Information

- Contact: Adrian Deccico, hello@darumatic.com
- Sign-in required: **No** (no accounts; parent PIN is user-created on-device)
- Notes for review: "All functionality is available without credentials. The
  optional parent lock PIN is created on-device by the user. The only external
  link (developer site) sits behind a parental gate as required for apps used
  by children. The iOS build contains no donation link or donation prompt of
  any kind. No ads, no purchases, no data collection beyond anonymous Firebase
  Analytics events."

## App Privacy (privacy "nutrition label")

Data collection: **Yes**, minimal — mirror of the Play data-safety form:

- **Usage Data → Product Interaction** (anonymous analytics events via Google
  Analytics for Firebase): Collected, **not** linked to identity, **not** used
  for tracking.
- **Identifiers → Device ID** (Firebase app-instance ID only; no IDFA):
  Collected, **not** linked to identity, **not** used for tracking.

Tracking (ATT): **No** — the app does not track users across apps/websites;
no App Tracking Transparency prompt needed. IDFA is never accessed.

Everything the child enters (names, stages, PIN hash) stays on device.

## Screenshots

Apple requires 6.9" iPhone screenshots (1320×2868 or 1290×2796); iPad 13"
(2064×2752) required because the app targets iPad (`TARGETED_DEVICE_FAMILY = 1,2`).

Generated in this directory from the Play captures (framed to Apple sizes):

| File | Size | Source |
|---|---|---|
| `iphone-69-1-mystery-egg.png` | 1320×2868 | screenshot-1-mystery-egg.png |
| `iphone-69-2-evolved-dragon.png` | 1320×2868 | screenshot-2-evolved-dragon.png |
| `iphone-69-3-profiles.png` | 1320×2868 | screenshot-3-profiles.png |
| `iphone-69-4-parent-lock.png` | 1320×2868 | screenshot-4-parent-lock.png |
| `ipad-13-1-mystery-egg.png` | 2064×2752 | screenshot-1-mystery-egg.png |
| `ipad-13-2-evolved-dragon.png` | 2064×2752 | screenshot-2-evolved-dragon.png |
| `ipad-13-3-profiles.png` | 2064×2752 | screenshot-3-profiles.png |

App icon: taken automatically from the build (1024×1024 in the asset catalog).

## Export compliance

Uses only standard HTTPS/ATS encryption → answer "None of the algorithms
mentioned above" / exempt. `ITSAppUsesNonExemptEncryption = NO` is set in
`ios/Runner/Info.plist` so the question is auto-answered per build.

---

## Submission walkthrough (App Store Connect) — done 2026-07-19

1. [x] **Certificates/profile**: automatic cloud signing with Team `76UL6RCLTT`.
2. [x] **Bundle ID registered** implicitly by cloud signing.
3. [x] **App record created**: "Task Monster: Chore Rewards", SKU
       `task-monster`, app ID 6792448899.
4. [x] **Build uploaded**: 0.0.19 (19) via `xcodebuild -exportArchive`
       destination=upload (`scripts/release_ios.sh --upload`).
5. [x] **App Information** (Lifestyle/Productivity, content rights: no
       third-party content), **Pricing** ($0.00, 175 countries), **App
       Privacy** published per this doc.
6. [x] **Version page**: description (note: Apple rejects multi-codepoint
       emoji like 👨‍👩‍👧‍👦/❤️ — use plain text), keywords, URLs, 4×
       iPhone 6.5" + 3× iPad 13" screenshots, review contact, age rating 4+.
7. [x] **Submitted for review** ("Waiting for Review"). Reviews take up to
       ~48 hours typically.
8. [x] **Rejection resolved** (rejected 2026-07-29, resubmitted 2026-08-06):
       Guideline 2.3.6 Accurate Metadata — the questionnaire declared
       "Parental Controls = Yes" under In-App Controls, but the reviewer
       couldn't find the opt-in app-bar parent lock on the review iPad (its
       tooltip never renders on touch), and the app has no Age Assurance.
       Fix per Apple's suggested path: Age Ratings questionnaire → Parental
       Controls → **None** (Age Assurance already None; every other answer
       untouched; calculated rating stays 4+), then version page → "Update
       Review" → "Resubmit to App Review" — same build 19, no new binary.
       Note: the reply thread closes once resubmitted, so any reply to App
       Review must be sent *before* resubmitting. The in-app parent lock
       stays (and stays in the description); it just isn't declared as an
       In-App Control.

Remaining follow-ups:

- [ ] **EU Digital Services Act trader status** (App Information → App Store
      Regulations & Permits → Set Up): must be provided/verified by the
      Account Holder or EU distribution can be blocked. User action.
- [ ] After approval: verify the store listing renders correctly; consider
      native (simulator-captured) screenshots to replace the framed Play
      captures.
