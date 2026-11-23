## What and why

<!-- What was wrong or missing, and how this fixes it. Link the issue: "Closes #123". The title of this
pull request is a Conventional Commit, `type(scope): what the change does`: see CONTRIBUTING.md. -->

## Checklist

- [ ] **Signed off.** Every commit has `Signed-off-by` with its author's name and email (`git commit -s`;
      `git rebase --signoff main` adds it to the ones you made), certifying the
      [DCO](https://developercertificate.org).
- [ ] **Conventional commits, one change each.** `type(scope): description`, lowercase, no period, and
      the title of this pull request follows the same rule. AI-assisted commits end with
      `Assisted-by: <model> via <tool>`, and no `Co-Authored-By`.
- [ ] **Tests.** A fix has its regression test in the same commit; other tests are in their own
      `test(scope)` commit. `flutter analyze` and `flutter test` pass, and so does
      `dart format --output=none --set-exit-if-changed lib test packages tool/build tool/release`.
- [ ] **Fixtures untouched.** I did not edit or regenerate anything in `mobile/test/fixtures`, and no
      format that other versions or people read (the vault, exports, QR transfers, sync files,
      invites, Recovery Kit pieces) changed byte for byte; or this pull request says why, and adds
      a new version of the format that the old one still opens.
- [ ] **Both lockfiles.** If a dependency changed: `mobile/pubspec.lock` and `mobile/pubspec.free.lock`
      both moved, `android/gradle/verification-metadata.xml` too for an Android one, and the free
      build still holds no closed or store-only code. (Not applicable: no dependency changed.)
- [ ] **Licences.** New third-party code or data is under a licence GPL-3.0-or-later can carry, with an
      annotation in `REUSE.toml` and a credit in the README. (Not applicable: nothing new.)
- [ ] **Nothing secret** is in the code, the tests, the logs or this description.

## Notes for the reviewer

<!-- Anything that needs a closer look: crypto, formats, native code, a migration. Screenshots of the
change on a phone are welcome, with no real codes or logins on them. -->
