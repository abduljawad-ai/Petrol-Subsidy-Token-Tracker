# FuelToken Tracker

Offline-first Android app for the Pakistan 9771 petrol subsidy tokens.

- Flutter + SQLite (sqflite), single-device storage, Google Drive appDataFolder backup (compressed snapshot, changed-only traffic).
- OCR: Gemini key is never shipped with the app — the user pastes their own key in Settings.
- Weekly token cycle: stores tokens, reads them, marks used at the pump, and tells you (in-app + local notification) when a vehicle is again eligible for a new token.

## Layout
- `lib/screens/` — screens (home/tokens, history, OCR scan, paste SMS, add token, detail, settings)
- `lib/services/` — sync engine (Drive), backup codec, renewal logic, token expiry notifications, OCR, SMS parser, plate formatter, sync config
- `lib/db/` — SQLite layer (`database_helper.dart`)
- `lib/widgets/`, `lib/theme/` — shared UI + palette registry (`#006400 #FFD700 #E8F5E9 #12341C #1565C0`, white)
- `assets/` — delivered design system (`fueltoken_icons/{svg,png}`, `fueltoken_anim/{anim,svg}`)
- `packages/android_gsi_no_ui/` — vendored `google_sign_in_android` patch: the app never shows Google UI on its own; the credential prompt only runs inside an explicit user gesture
- `archive/` — delivered briefs, old UI snapshots, OCR test images (not part of the build)
- `test/` — unit + widget tests (66)

## Build
`flutter build apk --release` → `build/app/outputs/flutter-apk/app-release.apk`
