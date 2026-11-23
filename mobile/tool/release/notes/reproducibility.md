# Two builds of one tag, in the release container

Task 4.3 of `add-fdroid-release`, 2026-11-17. A scratch tag `v1.1.0` on f9b53539, in a
clone made for it, built with `build.sh` twice, each in a fresh container from the image of
this folder's Containerfile, with as much changed between the two as one machine allows:

| | First | Second |
|---|---|---|
| Finished (UTC) | 11:18:47 | 11:28:22 |
| CPUs | 16 | 4 |
| Host name | `builder-one` | `another-machine` |
| `TZ` | `UTC` | `Pacific/Auckland` |
| `LANG` | `C.UTF-8` | `fr_FR.UTF-8` |

Both built the three APKs with Gradle's dependency verification on, and `check_free.dart`
passed each. The two `SHA256SUMS` are the same:

```text
2829142d6b3656d7a3e1502c4dc67ab91670919f842120b3bf3e99b2ef29a99e  kemlock-1.1.0-arm64-v8a-unsigned.apk
84f43b8f5b805113c632c30e20836d26d31bea91e45ff2995ec9b1b0cf1def5c  kemlock-1.1.0-armeabi-v7a-unsigned.apk
bde03363df9866bcfc11f795173e9a440269c17c36973192447046e147ef643a  kemlock-1.1.0-x86_64-unsigned.apk
```

Version codes 1002, 2002 and 4002, version name 1.1.0.

## What each setting fixed

The baseline (`baseline.md`) differed only in `libapp.so` and `libdartjni.so`, both from the
build's path; `build.sh`'s fixed path removes both. So none of the settings decision 7 of
the design lists was needed, and none was added to `android/app/build.gradle.kts`:

- `dependenciesInfo` off: the dependency block goes into the APK's signing block, which an
  unsigned release build has none of; nothing to remove. F-Droid's scanner, not run here,
  is the check that would ask for it.
- PNG crunching off: the PNGs were the same in both builds already.
- Baseline profiles off: the free build's APKs hold none.
- Version-control info stays on: both builds come from the same clean tagged commit.

## Not checked here

- Two machines. Both builds ran on one Windows machine under Docker; `release.yml` builds
  each tag on two separate runners, and F-Droid's own build is a third machine.
- A day apart. The two builds were ten minutes apart; nothing the build reads holds the
  date, which the same checksums at two times and in two time zones support.
