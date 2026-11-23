# Governance

Kemlock is a small project with one maintainer, who is accountable for what ships. This page says how
decisions are made, so that they are predictable and so that the project can grow past one person.

## Roles

- **Owner and maintainer**: [@Arsslensoft](https://github.com/Arsslensoft). Reviews and merges pull
  requests, decides what goes in, owns the release signing keys, and enforces the
  [Code of Conduct](CODE_OF_CONDUCT.md) and the [security policy](.github/SECURITY.md).
- **Contributors**: anyone who opens an issue, a pull request, or helps another user. They follow
  [CONTRIBUTING.md](CONTRIBUTING.md).
- **Maintainers (more than one)**: the owner may invite regular, trusted contributors with write
  access. They review and merge, and answer for what they merge; they never hold the signing keys.

## How decisions are made

- **Pull requests** are merged by a maintainer when CI passes, the commit rules are followed, and
  review is done. The owner reviews, or a maintainer the owner has named reviews, every change to the
  cryptography, the vault, the released formats, the native code, the build and the release (see
  [CODEOWNERS](.github/CODEOWNERS)).
- **Larger changes** (a feature, a new format, a new dependency, a change to how the app is built) are
  agreed in an issue first, and plans are kept in [`docs/plans`](docs/plans).
- **Disagreement** is settled by discussion on the issue or pull request, looking for what is best for
  people who keep their secrets in the app. If it isn't settled, the owner decides, and says why.
- **What never changes without the owner's explicit decision**: the licence; what past versions of a
  format wrote and what the app must keep opening; the rule that the free build holds only free
  software; and the absence of telemetry.

## Releases

The owner makes releases. [release-please](https://github.com/googleapis/release-please) proposes the
next version and the changelog from the Conventional Commits; the owner merges its pull request, the
free build is built twice in CI and compared byte for byte, and the owner signs the unsigned APKs away
from any build machine
([docs/reproducible-builds.md](docs/reproducible-builds.md)).

## Becoming a maintainer

Contributors who have had several changes merged, reviewed others' work well, and kept to the rules
here may be invited by the owner. A maintainer who is inactive for a year, or who doesn't keep to the
Code of Conduct, loses write access, with thanks.

## Changing this page

By a pull request the owner approves.
