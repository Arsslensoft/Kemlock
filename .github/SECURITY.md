# Security policy

Kemlock keeps people's one-time codes, passwords, passkeys and keys, sealed on their phone. If
you find a way to read a vault without its password, to forge or tamper with one without being
noticed, to get codes or logins out of AutoFill or the clipboard where they shouldn't go, or to
make a release differ from its source, please tell us privately first.

## Report a vulnerability

Open a private report with **GitHub security advisories** at
<https://github.com/Arsslensoft/Kemlock/security/advisories/new>. It isn't public until a fix is
out, it keeps the report, the discussion and the fix in one private place, and it lets us ask for
a CVE.

Please don't open a public issue, a pull request or a discussion for a vulnerability, and don't
post it anywhere before it is fixed.

Include what we need to reproduce it: the version (Settings, About) and the build (store or free),
the phone and its system version, and the steps. A vault file, export or QR made only for the
report helps; a real person's data does not.

If you can't use GitHub, write to [MAINTAINER EMAIL] and ask for a way to send the details
encrypted.

## Supported versions

Security fixes are made for the latest release only. Older versions get none: update first.

| Version | Supported |
| --- | --- |
| The latest release (1.1.x) | Yes |
| Anything older | No |

The Kemlock apps from before November 2026, which were called BackMyCodes, are the same line of
vaults: a flaw in how they sealed one, which Kemlock still opens, is in scope.

## What is in scope

- **The app**: the lock screen, the auto-lock and the wrong-password limit, how keys and secrets are
  kept in memory and on disk, the clipboard, screenshots and backups, AutoFill on Android and iOS,
  passkeys, deep links and the QR codes it reads.
- **The formats**: the vault, exports, QR transfers, sync files, invites and Recovery Kit pieces,
  the Kemlock account protocol and the sync it speaks to a WebDAV folder, Vaultwarden or Kemlock
  Server. This includes the cryptography itself (ML-KEM-1024, AES-256-GCM, scrypt, Argon2id, OPAQUE,
  the OpenPGP and SSH code) and any way of making a file the app accepts that it should not, or of
  making it open a vault wrongly. These formats must stay byte for byte what past versions wrote,
  so a fix may have to be a new format version that the old one refuses, not a change to the old one.
- **The builds**: a release APK that can't be rebuilt from its tag into the same file, as
  [docs/reproducible-builds.md](../docs/reproducible-builds.md) describes, the release workflow, and
  anything in the repository's CI that could change what is released.

## What is not in scope

- A phone that is rooted, jailbroken or already controlled by the attacker, and a vault whose
  master password is weak: offline guessing against a copy of the files is limited only by the
  password, as the README says.
- Flaws in Flutter, Android, iOS, a mail app or a password manager Kemlock talks to, with no
  Kemlock part in them: report those to their projects.
- Flaws in a particular Kemlock Server or Vaultwarden operator's server: report to that operator.
  Flaws in the Kemlock Server software go to its own
  [security policy](https://github.com/Arsslensoft/Kemlock-Server/security/policy), and the browser
  extension's to [its repository](https://github.com/Arsslensoft/Kemlock-browser/security/policy).
- Reports from automated scanners with no demonstrated effect, missing hardening headers on sites
  Kemlock doesn't run, and denial of service by a person who has the phone in hand.

## What to expect

| When | What we do |
| --- | --- |
| Within 3 business days | We answer: we have the report, whether we can reproduce it, and who is looking. |
| Within 14 days | We tell you whether it is a vulnerability, how serious, and when to expect a fix. |
| Within 90 days | We release a fix and publish an advisory that names you, unless you ask us not to. |

If a fix needs longer than 90 days, we tell you why before the 90 days are up and agree a date with
you. If the flaw is being used against people, we release as soon as there is a fix, even if the 90
days are not over. If you don't hear from us in 3 business days, write again: a report that went
astray is our fault, not yours.

## Safe harbour

We will not take legal action against, or ask anyone to take it against, research that is done in
good faith to find and report a vulnerability in Kemlock, that is done against your own phones,
vaults and servers and never against other people's data, and that stops once you have shown the
flaw: no copying, changing or deleting data you aren't entitled to, and no disclosure before we
have had the time above.
