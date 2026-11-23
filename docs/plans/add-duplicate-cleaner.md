# Duplicate cleaner

Kemlock finds the items a vault holds more than once and merges each group
into one, after the person picks what the kept item holds. Matching runs on
the phone from full 256-bit keyed hashes that never leave it, unless the
person or a space's admins let Kemlock Server group them. Import's duplicate
step moves onto the same rules, so the two can't disagree.

## Why

A vault fills up with copies:

- AutoFill saves a login a second time under another subdomain.
- An import brings back a code that's already there under another issuer
  name.
- A WebDAV space and the person's own vault both end up holding one item.

Nothing finds these copies today. Import's own check differs from kind to
kind: logins and notes match by id, codes by issuer and secret, backup
codes by service name.

The owner settled how to find copies on 21 November 2026, in the Kemlock
Server design's "Duplicate cleaner" section and its Decisions table
(https://claude.ai/artifact/2NWbdYSZaFK84mnLMWvx1Y):

- Tags stay on the device by default.
- Server matching is opt-in.
- Only the full-credential tag is uploaded.
- When a vault and a space hold one item, the merge asks, with the space's
  copy preselected.

This should be in place before the password-manager importers and
Credential Exchange (docs/plans/add-credential-exchange.md) bring in
thousands of items.

## What changes

- **Duplicate tags**:
  - Each item gets one or more 32-byte HMAC-SHA-256 tags, each over a
    combination of its normalised values. The tag kinds are `cred`,
    `account`, `secret`, `passkey`, `card`, `note`, `key`, `codes` and
    `identity`, all from `crypto.md` "Duplicate tags" and "Normalisation" in
    `../kemlock-server` (commit 38634d8).
  - No tag covers a password alone, and an item has at most 32 tags.
  - The key and the input are `crypto.md`'s:
    `HKDF(owner key, info = "kemlock dedup v1" ‖ owner (17) ‖
    u32be(key version))`, and HMAC-SHA-256 over the RFC 8785 (JCS) array
    `[name, …values]`.
  - Tags are kept in the vault's sealed store. They are rebuilt when
    missing and deleted when their key changes.
  - The server's CC0 dedup vectors, copied into `mobile/test/fixtures/server/`,
    hold the app to `kemlock-crypto`'s bytes. The app writes no cases file of
    its own.
- **A Duplicates screen**, opened from the vault health card:
  - groups with the reason each matched: the same sign-in, the same account
    with two passwords, the same code, passkey, card, note, key or backup
    codes, or "in two places";
  - Check again;
  - "Not duplicates", remembered;
  - Undo merge for 30 days.

  A group is shown only after the phone decrypts its items and compares
  the values.
- **A merge that asks first**:
  - each field preselects the newest value;
  - the kept login takes the union of the group's websites;
  - a password that isn't kept goes into the kept login's previous
    passwords;
  - logins linked to a code that goes are relinked to the code that stays;
  - the space's copy is preselected when a vault and a space hold one item.
- **One rule set for import and the cleaner.** Import's checks move out of
  `mobile/lib/features/import/import_merge.dart` into one module. Import
  skips an entry only when the vault holds the same credential. Weaker
  matches are imported and left for the cleaner. Import's behaviour changes
  in four places:
  - **Codes** match on the secret's decoded bytes, whatever the issuer. A
    held HOTP code takes the higher counter.
  - **Passkeys** match on relying party plus credential id, not credential
    id alone.
  - **Logins** match on id, or on the same site, username and password.
  - **Backup-code lists** match on id or on the same set of codes, not on
    service name. A second list for one service with other codes is now
    added, not dropped.

  Notes, keys and contacts keep their rules. Replace mode is unchanged. The
  recorded importer cases don't change: none of them checks a file against
  a vault.
- **Server matching**, as an opt-in. It waits for
  docs/plans/add-kemlock-server-sync.md.
  - A person can turn it on for their vault after a screen that says what
    the server would learn.
  - A space's admins can turn it on for their space, and every member is
    told.
  - Only `cred` tags are uploaded, as the Decisions table says ("The
    full-credential tag only"). Every other tag kind, `account` and the
    other kinds' tags included, is matched on the device only.
  - Items without tags on the server are backfilled. Turning it off
    deletes the uploaded tags.
  - Server groups are hints that the phone checks again.
- **Nothing existing changes shape.** No sync file, export, QR transfer or
  Vaultwarden item gains a key.

Out of scope:

- the card kind and website `uris`, from
  docs/plans/add-cards-identities-and-websites.md;
- the import preview's per-item skip, keep-both or replace choices, from
  docs/plans/add-credential-exchange.md;
- merging items of different kinds;
- matching across people;
- a general trash;
- syncing "Not duplicates" answers through WebDAV;
- Gating: the cleaner is free, and server matching adds no gate of its own.

## Decisions for the owner

Decided by the owner on 2026-11-21: every recommendation below, as the tasks assume.

1. **What does a vault with no Kemlock Server account derive its dedup key
   from?**
   - A, *recommended*: a random 32-byte dedup root sealed in the vault. It
     runs the same code path as server tags, so the server's vectors test
     it. If it is lost, the tags are rebuilt and nothing breaks.
   - B: HKDF from the vault's ML-KEM private key. It reuses key material,
     and every key-pair replacement changes every tag.
   - C: no key; values are compared in memory and no tags are stored. This
     is the simplest, but it goes against "tags kept in the encrypted
     store" and is a second path to test.

   The tasks assume A. WebDAV spaces use their own space key either way.
   The user key replaces the root once docs/plans/add-account-crypto.md
   lands.
2. **What do merged-away items go to, since the app has no trash?**
   - A, *recommended*: a sealed merge record kept 30 days, with Undo merge
     on the Duplicates screen.
   - B: a general trash for every kind, which is a larger plan of its own.
   - C: only the toast's Undo, which falls short of the design's 30 days.

   The tasks assume A.
3. **Should import adopt the cleaner's code rule, the secret alone?**
   - A, *recommended*: yes. A secret is per account, so "Google" and
     "google.com" with one secret are one account.
   - B: import keeps issuer and secret, and the cleaner alone uses the
     secret. The two then disagree, against the design.

   The tasks assume A. This replaces the rule add-code-imports wrote,
   "Duplicates and merging work as before".
4. **Which Unicode NFC source should the app use?** It has none today; the
   security audit noted the same gap for PINs.
   - A, *recommended*: `unorm_dart` (MIT), if its Unicode version matches
     the server's `unicode-normalization` crate.
   - B: tables generated by the project at the server's Unicode version.

   The tasks assume A, checked by the server's dedup vectors.

## Design

The current code that shapes this:

- `VaultController` holds every list decrypted after unlock. Each list is
  its own sealed value (`backmycodes_*_data`, via `saveEncryptedValue`).
- A new sealed value is re-sealed by a key-pair replacement
  (`sealedValueKeys`, replace-vault-key-pair) and deleted with its vault
  (`VaultRegistry.removeVaultData`) with no extra code.
- Spaces are entries with a `spaceId`. A WebDAV space's AES-256 key is
  `Space.target.key` in the sealed sync settings.
- Undo today is a toast that restores only into the vault the item came
  from, stamped as just changed (`_restoreAccount`).
- add-browser-extension plans to move models, crypto and site matching
  into a pure Dart `kemlock_core`, so new rule and tag code has no Flutter
  in it.

1. **A dedup root** (owner decision 1).
   - The root is made at the first match, with a random UUID beside it
     that stands in for the account id until there is one. The owner bytes
     are then `0x01 ‖ that UUID`.
   - Each WebDAV space uses its `target.key` as the owner's key. Its owner
     bytes are `0x02 ‖` the legacy-id UUID of its space id, from
     `crypto.md` "Legacy ids", so a space later moved to the server keeps
     the same owner bytes.
   - At the first Kemlock Server sign-in, the user key replaces the root
     and the account id replaces the stand-in UUID: the version goes up by
     one, the tags are made again, and the root is deleted.
   - Server spaces use their space key, from
     docs/plans/add-server-spaces.md, as `crypto.md` says ("user key or
     space key").
2. **Key and input encoding**, exactly `crypto.md` "Duplicate tags":
   - **The key:** `HKDF-SHA256(ikm = owner key, salt = absent,
     info = "kemlock dedup v1" ‖ owner (17) ‖ u32be(key version), L = 32)`.
     The owner is fixed-length, so nothing runs into the version.
   - **A tag:** HMAC-SHA256 of the JCS array `[name, …values]`, all strings,
     without whitespace. The owner and version are in the key, not the
     array.
   - **Values**, in the order of `crypto.md` "Normalisation"'s table:
     - sites as the registrable domain, or the whole host for an address or
       a shared host;
     - secrets as the decoded bytes in RFC 4648 base32, upper case, no
       padding;
     - codes trimmed, deduplicated and sorted by code point, which is the
       order of their UTF-8 bytes (Dart's `compareTo` sorts by UTF-16);
     - a card's expiry as `YYYY-MM`, or empty when it is unknown;
     - a key's fingerprint as an SSH key's `SHA256:` one or a PGP key's
       upper-case hex.
   - **`identity`**, now pinned by `crypto.md`: the array
     `["identity", full name, email]`, each trimmed, NFC and lower-cased.
     The full name is the given, middle and family names in order. It is
     matched on the device only, as every tag but `cred` is, and the web
     vault makes the same tag.
3. **Normalisation.**
   - **Sites:** `normaliseWebsite`, then the Public Suffix List, as
     `loginDomains` does. A shared host or an address stays whole.
   - **Usernames:** trimmed, NFC, and each code point's *simple* lowercase
     mapping (UnicodeData field 13), as `crypto.md` has it: no SpecialCasing
     and no final-sigma rule, so `İ` is `i`, `Σ` is always `σ`, `ẞ` is `ß`,
     and `Straße` and `STRASSE` don't match. Dart's `toLowerCase` and Rust's
     `to_lowercase` apply both, so the app lower-cases rune by rune with `İ`
     mapped explicitly. The server's `dedup-normalise.json` pins `İstanbul`,
     `ΣΑΣ`, `Straße` against `STRASSE` and a decomposed `é`.
   - **Passwords:** as typed.
   - **Notes:** NFC, `\n` line ends, the spaces and tabs at the end of each
     line removed, and blank lines at the end removed.
   - **The Public Suffix List:** `crypto.md` pins one snapshot, with its
     checksum, in the server's test-vectors, for both sides. That snapshot
     isn't published yet. Until it is, the app keeps its bundled list, so a
     site's registrable domain can differ from the server's for a host the
     two lists read differently. When it lands: bundle it, take its checksum
     as the list hash the cache records, and run its vectors.
   - **The list's version:** the tag cache records the Public Suffix List's
     hash and rebuilds when an app update changes it.
4. **Storage.** There are two new sealed values per vault:
   - `backmycodes_dedup`: the root, each owner's version and item tags
     (`{itemId: {at, tags}}`), and the list hash. All of it is a cache,
     remade whenever it's missing.
   - `backmycodes_dedup_answers`: the dismissals and the merge records. It
     isn't rebuildable, so it is kept apart from the cache.

   Neither goes into exports, QR transfers, sync files or Vaultwarden. The
   dedup key is held only while tags are made, then wiped.
5. **Matching.**
   - **Within an owner:** stored tags are bucketed by value, compared with
     a constant-time byte comparison, and joined per kind by union-find.
     Each group is then checked against the decrypted values.
   - **Across owners:** the matcher makes a temporary tag set under a key
     made for that run, for every item the phone can open, and wipes the
     key after. Nothing from this pass is stored.
   - **The reason** is the strongest shared kind (`cred` before `account`),
     or "in two places" across owners.
   - **Speed:** above 2,000 items the work runs in an isolate. That is at
     most 160,000 HMACs for 5,000 items; the time is to be measured.
   - **When it runs:** after an import, after a sync, and on Check again.
   - Alternative weighed: matching plain values in memory every time. It
     works on one device, but it can't feed server matching and isn't
     covered by the shared cases.
6. **The merge.** `VaultController.mergeDuplicates`:
   1. writes the merge record first;
   2. saves the kept item with the chosen fields, the union of websites and
      tags, and the lost password through `keepingPrevious` (as sync's
      `_keepLosingPassword` does, five kept);
   3. relinks logins whose `accountId` names a removed code;
   4. removes the others.

   Each list it touches rolls back on a failed save. Lists are separate
   sealed values, so a crash between saves can leave half a merge; the
   record written first lets Undo repair it, and the next match shows any
   copy that is left.

   **The narrower website rule** (with `uris`): never, exact, starts with,
   host, base domain, then default. Regular-expression entries stay
   separate.

   Passkeys and backup lists aren't linked by id in the app, so nothing of
   theirs moves with a merge. The mockup's "passkey moves to the kept
   login" is a web-vault link.
7. **Undo** (owner decision 2).
   - It restores the record's items, stamped as just changed, so they
     outlive the tombstones sync has shared.
   - It works only in the vault the merge was made in.
   - Records older than 30 days are pruned at unlock.
   - With Kemlock Server, the server's trash also holds the removed items,
     but the local record is what Undo reads.
8. **One rule module.** `mobile/lib/features/duplicates/duplicate_rules.dart`
   is pure Dart.
   - It holds each kind's tag inputs, a `sameCredential` predicate and the
     group reasons.
   - Import calls `sameCredential`, and the cleaner calls the tag inputs, so
     any pair import skips is a group the cleaner shows.
   - `import_merge.dart` keeps its function names, and `import_sheet.dart`
     and `qr_import_sheet.dart` change only where a rule's meaning did.
   - Credential Exchange's import preview uses this module's rules, the
     login rule included (site, username and password). Tasks group 1 is a
     hard prerequisite of its preview.
   - **A third rule stays as it is on purpose.** Sync's merge drops a
     duplicate account by `issuer::secret` (`_dropDuplicateAccounts` in
     `sync_merge.dart`). It is left unchanged: every phone on a sync file
     or space, whatever its version, must drop the same copies the same
     way, or two versions would keep deleting what the other keeps and
     ping-pong. A copy it lets through (one secret under two issuers) is
     shown by the cleaner, and merged only when the person says so.
9. **Server matching** hooks into the Kemlock Server backend's item
   writes.
   - A tag provider returns `cred` tags only, for logins. No other tag
     kind ever leaves the device: `account`, `secret`, `passkey`, `card`,
     `note`, `key`, `codes` and `identity` are matched on the device only.
   - The per-owner switch lives in that backend's sealed settings.
   - Backfill runs after each sync.
   - The space switch reads the member's role from
     docs/plans/add-server-spaces.md.

## Behaviour

### Tags

- **A tag is a full keyed hash.** It is the full 32 bytes of HMAC-SHA-256
  under the owner's dedup key, never truncated, and never over a password
  alone.
  - Logins on `alpha.example` and `beta.example` with one username and
    password share no tag.
- **A login makes `cred` and `account` per website.** It makes up to 32
  tags, for its first 16 websites that make tags. Regular-expression and
  never websites make none.
  - A login with no password makes only `account`.
  - A login with no website makes one of each with an empty site.
  - A login with 20 websites on different domains makes 32 tags.
- **Other kinds make one tag each:**
  - a code, `secret` (base32-decoded bytes);
  - a passkey, `passkey` (relying party, credential id);
  - a card, `card` (number digits, expiry);
  - a note, `note`;
  - a key or contact, `key` (identity or PGP fingerprint);
  - a backup-code list, `codes` (sorted);
  - an identity, `identity` (full name, email).
  - `JBSWY3DPEHPK3PXP` under "Google", and the same secret spaced and in
    lower case under "google.com", give equal `secret` tags.
- **Normalisation.**
  - Logins on `accounts.larkspur.example` and `mail.larkspur.example` with
    one username and password give equal `cred` tags.
  - Logins on `alpha.okta.com` and `beta.okta.com` don't.
  - ` Sam@Example.org` and `sam@example.org` match.
  - `Hunter2` and `hunter2` give different `cred` tags and equal `account`
    tags.
- **The key is per owner and version.**
  - One login held in the vault and in a space gives different stored
    tags.
  - Going from version 1 to 2 changes every tag.
- **Tags stay sealed.**
  - A locked vault's storage holds no tag, root or key outside a sealed
    value.
  - An export holds none.
- **Rebuilt and dropped.**
  - A missing cache gives the same groups at the next match.
  - A changed password gives new `cred` tags.
  - A deleted item's tags go with it.
- **Shared cases.** Every case of the server's dedup vectors reproduces
  byte for byte. Until they are published, the tests build their cases in
  code; the app writes no fixture of its own.
- **Constant time.** Tag bytes are compared with a comparison whose time
  doesn't depend on where they differ.

### Finding and merging

- **On the device by default.** With server matching off, Duplicates works
  offline and makes no network request.
- **Values are checked before a group is shown.**
  - A server group of two logins with different passwords isn't shown as
    the same sign-in.
  - A group left with one item isn't shown.
- **A group says why and holds one kind.**
  - Two logins with one site and username but two passwords show as the
    same account with two passwords.
  - A key and a contact with one fingerprint aren't grouped.
- **Across the vault and its spaces.** A Netflix login in the vault and one
  in a WebDAV space, with the same site, username and password, show as one
  group "in two places".
- **From the vault health card.** After an import adds a same-account
  login, the Duplicates row counts one group.
- **The newest value is preselected.** "Proton Mail", changed yesterday, is
  preselected over "proton.me", changed in August, and either can be
  picked.
- **Websites are kept.** Merging logins on `proton.me` and
  `account.proton.me` keeps both. One address with two rules keeps the
  narrower.
- **No password is lost.** The password not kept becomes the kept login's
  first previous password, unless it is already there. Five are kept.
- **Links follow.** A login linked to "AWS root account" is relinked to
  "Amazon Web Services" when the first is merged into the second.
- **The space's copy is preselected.** When the person can't change the
  space's copy, only removing the vault's copy is offered.
- **Undo for 30 days.**
  - Undo merge six days later brings both logins back as they were.
  - After 30 days it is no longer offered and the record is gone.
  - The toast also offers Undo.
- **"Not duplicates" is remembered.** A dismissed pair of notes stays
  hidden on Check again. It returns when a third note with that text
  joins.

### Import

- **One rule set.** Any pair the cleaner shows as "the same code" counts as
  a duplicate in a merging import.
- **Codes.**
  - A held "Google" and an imported "google.com" with one secret keep one
    copy.
  - An imported HOTP counter of 12 raises a held 9 to 12.
- **Passkeys.** A passkey with a held relying party and credential id isn't
  added again.
- **Logins.**
  - A new-id login on `mail.larkspur.example` matching a held
    `larkspur.example` login in username and password is skipped.
  - One that matches in site and username only is added and grouped by the
    cleaner.
- **Backup codes.** A GitLab list with other codes than the held GitLab
  list is added.
- **Unchanged rules.**
  - A new-id note with a held note's text is added, and the cleaner shows
    the two.
  - An imported login linked to a skipped code is linked to the vault's
    copy.
  - Replace mode takes the import whole.

### Server matching

- **Off until turned on.** It's only offered for an owner synced with
  Kemlock Server. A first sign-in uploads nothing, and a WebDAV or
  Vaultwarden vault sees no switch.
- **The explainer comes first.** Cancelling it uploads nothing.
- **Space admins decide.**
  - A member who isn't an admin sees the switch's state but can't change
    it.
  - When an admin turns it on, every member sees a notice at their next
    sync.
- **Only `cred` leaves the device.** A login with two websites writes two
  `cred` tags and no `account` tag. A code, note, card, passkey, key,
  backup-code list or identity writes no tag at all.
- **Backfill.** A login changed through the Bitwarden API gets its `cred`
  tags with `PUT /kem/v1/items/{id}/tags` and `If-Match`. A stale revision
  is retried at the next sync.
- **Hints only.** A server group whose passwords differ isn't shown, and
  nothing merges on the server's word.
- **Shared dismissals.** "Not duplicates" on one phone, through
  `POST /kem/v1/duplicates/dismissals`, hides the group on the other phone
  after its next sync.
- **Off deletes.** `DELETE /kem/v1/duplicates/tags` removes the owner's
  tags, and on-device matching keeps working.
- **Rotation re-tags.** After a member leaves and the space key rotates,
  each re-wrapped item's write carries tags of the new version.

## Tasks

Coding agents don't run builds, tests, CI or `pub get`. Each "Verify" names
the test that the single build-and-test pass after merging runs. The scope
is `vault`, with `import` for tasks group 1.

### 1. One rule set for import (a hard prerequisite of Credential Exchange's preview)

- [x] 1.1 Add `mobile/lib/features/duplicates/duplicate_rules.dart`, in pure
  Dart, with each kind's `sameCredential` (design 8). Verify with
  `test/features/duplicates/duplicate_rules_test.dart`, which covers every
  kind, and that the file imports no Flutter package.
- [x] 1.2 Make `import_merge.dart`'s `isSameAccount`, `mergeImport`,
  `countImport`, `newPasskeys` and `newLogins`, and the backup-list check,
  call the module. Raise a held HOTP counter to the import's when it is
  higher. Update `import_merge_test.dart` to the new rules. Leave
  `_dropDuplicateAccounts` in `sync_merge.dart` unchanged (design 8). Verify
  that `import_merge_test.dart`, `import_items_test.dart`,
  `importers_cases_test.dart`, `import_sheet_test.dart` and the sync merge
  tests pass, with the recorded cases unchanged.

### 2. Tags

- [x] 2.1 Add the NFC dependency (owner decision 4) in its own `chore(deps)`
  commit with the lockfile. Verify in the single pass after merging that
  `flutter pub get --enforce-lockfile` resolves, and that
  `tool/build/use_free.sh` still resolves. Already in the lockfile since
  56027839 (`normalizePassword` uses it), so this run adds nothing.
- [x] 2.2 Add the normaliser:
  - sites, through `normaliseWebsite`, the Public Suffix List and the
    shared-host rule;
  - usernames;
  - note text;
  - base32 secrets;
  - codes sorted by code point;
  - card number and expiry, once the card kind exists.

  Verify with unit tests per rule, including `İ`, `Σ`, `ẞ` and a decomposed
  `é`.
- [x] 2.3 Add the RFC 8785 encoder for arrays of strings, the HKDF dedup key
  over the 17-byte owner and the HMAC tag (design 2), and a constant-time
  comparison. This is the tag builder other plans call. Verify against
  RFC 8785's escaping examples and RFC 5869's vectors.
- [x] 2.4 Make each kind's tags, `identity` included, with the 32-tag cap.
  Regular-expression and never websites make no tags once `uris` exist;
  until then every website makes tags. Verify with `dedup_cases_test.dart`:
  cases built in test code (every kind, the 2.2 edge cases, two owners, two
  versions) until the server's dedup vectors are copied into
  `mobile/test/fixtures/server/`, then every server case byte for byte. No
  cases file is written by the app.

### 3. Where tags live

- [x] 3.1 Add the sealed values `backmycodes_dedup` and
  `backmycodes_dedup_answers` (design 4). Make the root at the first
  match, and rebuild the cache when it's missing, unreadable or the list's
  hash changed. Verify with tests:
  - a locked vault's storage holds no tag, root or key outside a sealed
    value;
  - `unknown_sealed_value_test.dart` passes, with both values re-sealed by
    a key-pair replacement;
  - deleting the vault removes both;
  - an export holds neither.
- [x] 3.2 Make tags incrementally by each item's change time:
  - drop the tags of deleted items;
  - drop an owner's tags when its key or version changes;
  - use each WebDAV space's `target.key`, with its legacy-id owner bytes;
  - tag items moved by docs/plans/move-off-vaultwarden-sync.md like any
    other change.

  Verify with tests: an edited password gives new `cred` tags; leaving a
  space drops its tags; a cleared cache gives the same groups.

### 4. Finding groups

- [x] 4.1 Add the matcher (design 5): buckets per owner, union-find per
  kind, the strongest reason, the check against values, and the
  cross-owner pass under a run key wiped after. Use an isolate above 2,000
  items. Verify with tests for each reason, "in two places" with a WebDAV
  space, a forged tag that leaves no group, and a key and a contact that
  make none.
- [x] 4.2 Count groups after an import, after a sync and on Check again, and
  show the Duplicates row on the vault health card. Verify with a widget
  test: an import adding a same-account login shows one group.

### 5. Screens

- [x] 5.1 Build the Duplicates screen after the mockup `Duplicates.dc.html`
  (https://claude.ai/artifact/4wvdwScsMsGu6NMSj6ptPo), in the app's sheets
  and theme:
  - filters for All, Logins, Codes, Notes and In two places;
  - each group's reason and its items' place and date;
  - Review, Not duplicates, Check again and Undo merge;
  - the "Found on this device" line.

  Add the strings in every shipped language. Verify with widget tests in
  light, dark and French, and that every new key is in every `i18n` file.
- [x] 5.2 Build the merge sheet after `DuplicateMerge.dc.html`:
  - rows for the fields that differ, with the newest preselected;
  - the websites with their rules;
  - the linked code;
  - the password-history note;
  - the space's-copy preselection and its read-only case;
  - Merge, Not duplicates and Cancel.

  Verify with widget tests: the newest is preselected; another pick
  changes the summary; "in two places" preselects the space's copy.

### 6. Merging

- [x] 6.1 Add `VaultController.mergeDuplicates` (design 6): write the record
  first, then the kept item, the relinks and the removals, with roll-back
  on failure. Verify with tests for each kind's merge, no lost password, a
  relinked login, a failed save that leaves the vault as it was, and the
  toast's Undo.
- [x] 6.2 Add Undo merge from the record (only in the vault it came from,
  stamped as just changed), pruning past 30 days at unlock, and "Not
  duplicates", which returns only when a new item joins. Verify with
  tests:
  - Undo after six days restores both items;
  - a 31-day-old record is gone;
  - a dismissed group stays hidden until a third match joins;
  - after a WebDAV sync, an undo reaches the other phone.

### 7. Server matching (waits for docs/plans/add-kemlock-server-sync.md, and docs/plans/add-server-spaces.md for spaces)

- [x] 7.1 Add the tag provider to item writes: `tags` and `tagVersion` on
  `PUT /kem/v1/items/{id}` and `items:batch`, with `cred` tags only. The
  move's batches (docs/plans/move-off-vaultwarden-sync.md) go through the
  same provider. Verify against the server's OpenAPI spec, and with
  fake-server tests that a login write carries no `account` tag and that a
  code, card or note write carries no tag. (`km_dedup.dart`: `KmCredTags` is
  the one place a tag for the server is made, `kmWriteTags` gives a batch's
  tags to `KmApi.batchTagged`, and the sync run and `KmMoveServer` both call
  it. Verified in `km_dedup_test.dart`, run after merging, which also fails if
  any tag but a `cred` one reaches a request.)
- [x] 7.2 Add the vault switch with its explainer, the space admin switch
  with the member notice, and turning off with
  `DELETE /kem/v1/duplicates/tags`. Verify with widget and fake-server
  tests: cancel uploads nothing; a member can't change the space switch;
  turning off deletes the tags and on-device matching still works.
  (`kemlock_matching_section.dart` in the Kemlock sheet,
  `kemlock_matching.dart` for the calls, the space list and the notice.
  The account has no server spaces in the app yet, so
  `kemlockDedupSpacesProvider` is empty until add-server-spaces fills it; the
  space switch and the notice are built on it and tested with an override.
  Tests are in `kemlock_matching_test.dart`, run after merging.)
- [x] 7.3 Backfill after each sync with `PUT …/tags` and `If-Match`,
  skipping stale revisions. Read `GET /kem/v1/duplicates` as hints checked
  on the device. Share dismissals through `POST` and `DELETE
  /kem/v1/duplicates/dismissals`. Verify with fake-server tests:
  - a Bitwarden-written item is backfilled;
  - a stale revision is retried;
  - a server group with different passwords isn't shown;
  - a dismissal hides the group on the other device.
  (`kmBackfill` in `km_dedup.dart` runs at the end of each sync run and reads
  `GET /duplicates` into `kemlockHintsProvider`; `duplicate_server.dart` checks
  the hints against the items and reads a group the server leaves out as
  answered. `DuplicatesController.dismiss` shares a same-sign-in dismissal and
  `restore` takes it back. Tests are in `km_dedup_test.dart` and
  `duplicates_server_test.dart`, run after merging.)
- [x] 7.4 Re-tag in the rotation batches when a user-key or space-key
  rotation bumps the version. Verify with a fake-server test that every
  re-wrapped write carries new-version tags.
  (The server's key replacement takes no tags in its batch, so the re-tag is
  the backfill of 7.3 under the new version: see "Agreed with the server".
  Tested in `km_dedup_test.dart`, run after merging.)

### 8. Integration

- [ ] 8.1 After merging, the main session runs one pass, with the owner on
  an emulator:
  1. Import a file with a same-secret code and a same-account login.
  2. See both groups.
  3. Merge each.
  4. Undo one.
  5. Sync with WebDAV to a second emulator and see both changes arrive.

  Verify that `flutter analyze` is clean and the whole `flutter test` suite
  passes in that one run, and record the result in this plan.

## Agreed with the server

`crypto.md` "Duplicate tags" and "Normalisation" (kemlock-server commit
38634d8) fix the key, the JCS input, the tag names, `identity` included, and
how every value is normalised. The code follows them: the simple lowercase
mapping, base32 secrets, the `identity` input, each tag's value order, note
text and backup codes. Still open on the server's side:

- the Public Suffix List snapshot and its checksum in test-vectors, which
  both sides will use (design 3 says what the app does until then);
- `dedup-normalise.json`, once published: copy it to
  `mobile/test/fixtures/server/` and run it in `dedup_cases_test.dart`;
- the `tags` and `tagVersion` fields and the `/kem/v1/duplicates` routes,
  for `cred` tags only. They are built on the server (`build/vertical-slice`,
  `crates/kemlock-api-kem/src/routes/duplicates.rs`); where its code differs from
  what this plan first said, the code wins, and the app follows it:
  - **The fields.** `tags` (base64url, 32 bytes each, at most 64 an item) and
    `tagVersion` sit inside the item object of `PUT /kem/v1/items/{id}` and
    of each write of `items:batch`, beside the ciphertext, and come together
    or not at all. With matching off for the owner, or a `tagVersion` that
    isn't the owner's current one, the item is written and the tags are
    dropped (`tagsStored`, or `tags[].stored` in a batch's answer, says
    which). A write without tags clears the item's tags, through any API, so
    a tag always belongs to the revision it was made for.
  - **The version isn't the phone's.** The server holds each owner's dedup key
    version, starting at 1, and `GET /duplicates/settings` says it. The phone
    makes the upload tags under `HKDF(user key, owner = user:<account id>,
    that version)`, a key of its own, and keeps the cache's root for what stays
    on the device. Design 1's swap of the root for the user key at the first
    sign-in is not done: no task asked for it, and the upload tags don't need
    it.
  - **Switches.** `PUT /duplicates/settings?owner=` takes `{enabled}`; `DELETE
    /duplicates/tags?owner=` is the same with `enabled` false and deletes the
    owner's tags. `GET` says `changedBy` and `changedAt`, which is all a
    member's notice has to go on. Only a space's owners and admins may change a
    space's switch (403 otherwise).
  - **Hints.** `GET /duplicates?owner=` gives groups of item ids and `waiting`,
    a count of every live item without tags, codes and notes included, so it
    never reaches 0 for a vault that holds one. It isn't a list of the items to
    backfill: the phone keeps, per cached item, the key version and revision it
    has tags stored for.
  - **Dismissals.** `POST /duplicates/dismissals` takes `{owner, items}` (two
    to 500 ids) and answers with an id; `DELETE /duplicates/dismissals/{id}`
    takes it back. There is no list: `GET /duplicates` leaves out a group a
    dismissal covers, so another device learns of one by the group's absence.
  - **Backfill.** `PUT /items/{id}/tags` answers 409 for three reasons, told
    apart by the problem's type: `stale-revision`, `server-matching-off` and
    `stale-dedup-version` (with `currentTagVersion`).
  - **Rotation.** Replacing a space key bumps the space's version on the server
    and deletes its tags (`replace_keys.rs`), and the replacement's re-wrapped
    writes take no `tags`. So no tag rides in a rotation's batch: the version
    moves, and the next sync of each device finds it moved (it reads the
    settings at the start of a run) and gives the tags again under the new
    version through the backfill, which marks tags by version and revision
    (task 7.4). The server has no route for the user key's bump yet, and the
    app has no rotation of its own.

## Dependencies

- **docs/plans/add-cards-identities-and-websites.md:** the card kind, for
  `card` tags, and website `uris` with match rules, for skipping regular
  expression and never websites and for keeping the narrower rule. The
  device-only cleaner ships without them, and logins then use their hosts.
- **docs/plans/add-account-crypto.md:** the user key that replaces the
  dedup root, and the key versions a rotation bumps.
- **docs/plans/add-kemlock-server-sync.md:** item writes, sync and backfill
  for server matching (tasks group 7). Its routes, and the `tags` and
  `tagVersion` fields, are agreed with `../kemlock-server`.
- **docs/plans/move-off-vaultwarden-sync.md:** if this plan has landed, items
  moved into `kem1` are tagged on the device by task 3.2, as any change is,
  and their `cred` tags go with the move's batches through task 7.1 when
  server matching is on. Nothing here waits on it.
- **docs/plans/add-server-spaces.md:** space and collection keys as owner
  keys, members' roles for the admin switch, and space-key rotation for
  7.4.
- **docs/plans/add-credential-exchange.md:** builds its import preview
  (skip, keep both, replace) on this rule module. Tasks group 1 is a hard
  prerequisite of its preview task.
- **Earlier work this rests on:** add-passwords (logins, previous passwords,
  `loginDomains`), add-code-imports (whose code rule this replaces),
  replace-vault-key-pair (re-sealing new values), and add-browser-extension
  (the planned `kemlock_core` the rule and tag code must stay movable
  into).
