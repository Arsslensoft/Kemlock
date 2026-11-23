# Cards, identities and logins with several websites

Kemlock gains two vault kinds, cards and identities, so the importers and
Credential Exchange of Kemlock Server have somewhere to put them. Logins
and codes also gain Bitwarden's match rules for each website. Nothing
released changes shape: an item, file or vault that doesn't use these
features stays byte for byte what this version writes today.

## Why

Kemlock Server's importers and Credential Exchange bring cards,
addresses and identity documents out of every mainstream password
manager. Kemlock has nowhere to put them, so they would be dropped or
pushed into notes. The owner decided on 2026-11-21 that card and identity
kinds join Kemlock before the first importer ships (design doc
https://claude.ai/artifact/2NWbdYSZaFK84mnLMWvx1Y, Decisions, "Cards and
identities").

A login also fills only on the base domain of each host it keeps. A
company sign-in used on `example.co` and on `example-co.okta.com`, or a
login that must not fill on one subdomain, can't be described today. The
same decision record allows Bitwarden's six match rules, with regular
expressions under Advanced, a test box and a warning ("Regular-expression
rules"). The design doc's "Logins with several websites" section says how
that stays readable by older builds. Mockups: "Item · several websites"
(`ItemWebsites.dc.html`), "New item" and "Item" on the canvas
https://claude.ai/artifact/4wvdwScsMsGu6NMSj6ptPo.

## What changes

- **Cards as vault items.** A new kind beside logins, codes, backup
  codes, keys, notes and passkeys. A card has a name, the cardholder, the
  number, a brand, the expiry month and year, the security code, a PIN, a
  "valid from" month, a note and tags. The number shows its last four
  digits until revealed. The security code and PIN are secrets, shown and
  copied as a password is. A card past its expiry says so. Cards get a
  "Cards" filter on the Vault tab, a sheet, and an entry in the add button.
- **Identities as vault items.** A person's name parts, company, email,
  phone, username, birth date, one postal address, and a list of identity
  documents: passport, driver's licence, ID card, tax or social security
  number, or other. Each document has its number, issuing country and
  authority, and its issue and expiry dates. Document numbers are secrets.
  Identities get an "Identities" filter, a sheet, and an entry in the add
  button.
- **Both new kinds travel where logins do.** They are stored sealed in
  the vault under their own keys, sync through WebDAV in the vault and its
  spaces, and go into encrypted and plain exports and back through import.
  Older versions keep them, untouched, as later lists. They stay out of QR
  transfers and out of Vaultwarden sync, which counts what it doesn't
  carry, as it does for logins. Nothing fills them yet.
- **Websites with match rules.** Logins and OTP accounts gain an optional
  `uris` list beside `websites`. Each entry is an address and an optional
  rule: Default (today's behaviour), Base domain, Host, Starts with,
  Exact, Regular expression or Never. The rules are Bitwarden's
  `UriMatchStrategy` numbers, so a rule crosses between Kemlock and
  Bitwarden formats unchanged. `websites` keeps holding the hosts, so
  older builds fill as before. They carry `uris` in `extra`, and a newer
  build reconciles the two lists on reading.
- **AutoFill follows the rules on phones.** Phones see only a host, so
  Host, Starts with and Exact fill on their host alone, Base domain on its
  registrable domain, and Regular expression and Never nowhere. The
  autofill copy keeps its version 1 shape, because each rule maps onto the
  `domains` it already has. The browser extension matches whole addresses
  through one Dart matcher.
- **Starts with and Regular expression sit under Advanced.** They carry
  Bitwarden's warning. A regular expression also gets a test box: type an
  address and see whether the rule fills there. Patterns are matched by a
  linear-time matcher with length limits, so no pattern can hang the app
  or the extension.
- **Vaultwarden keeps a code's websites in its item.** A plain code's
  Bitwarden item lists the code's own websites after the 2FA directory's,
  with their rules. For codes with websites of their own, a second
  checksum over the URIs, in the `Kemlock` field's `extra`, brings edits
  made in a Bitwarden app back to the code. A code without websites of its
  own writes exactly what it writes today, `uriSum` included: it gets none.
  A write never drops a URI a Bitwarden app added.

Out of scope:

- AutoFill of cards and identities on Android, iOS or the extension.
- Importers and Credential Exchange (`add-credential-exchange.md`),
  duplicate tags (`add-duplicate-cleaner.md`), and Kemlock Server sync
  (`add-kemlock-server-sync.md`). This plan gives them the kinds and fields
  to map to.
- Custom fields on items, Bitwarden's equivalent domains, a global default
  rule setting, and Android app matching by Digital Asset Links.
- Cards and identities as Bitwarden card (3) and identity (4) ciphers,
  unless the owner picks that in question 2.
- Changing what the Swift or Kotlin autofill readers parse.

## Decisions for the owner

Decided by the owner on 2026-11-21: every recommendation below, as the tasks assume.

1. **What shape does an identity take?**
   - (a) A structured `address` and a `documents` list, each document with
     its own type, number, country and dates. **Recommended**: CXF carries
     several documents with their own dates and countries, and Bitwarden's
     three numbers (passport, licence, SSN) map onto three entries.
   - (b) Bitwarden's flat identity fields (`address1-3`, `passportNumber`,
     `licenseNumber`, `ssn`). It is simpler, but it drops a second
     document and every document's dates.

   The tasks assume (a).
2. **What does Vaultwarden sync do with cards and identities?**
   - (a) Keep them on the phone, never written to an item, counted on the
     sync sheet, as logins are. **Recommended**: Amethystora leaves those
     types alone, and `move-off-vaultwarden-sync.md` moves this data to
     `kem1` items anyway.
   - (b) Seal them in a sealed home only. Older builds would carry two
     kinds they skip.
   - (c) Write them as Bitwarden card and identity ciphers in plain homes,
     so Bitwarden apps see them. This needs two new plain-field kinds and
     their codec.

   The tasks assume (a).
3. **Where does "Base domain" fill on a host anyone can open a site under
   (okta.com, slack.com) or on an IP?**
   - (a) On that host only, whatever the rule. **Recommended**: otherwise
     one rule picked in good faith fills a password on every Okta tenant.
   - (b) On the whole shared domain, as Bitwarden does.

   The tasks assume (a).

## Design

### Context

- **Vault items** follow the pattern of the `add-vault-items` and
  `add-passwords` plans (git history before 5ba88b42). A new kind is a
  model with `extra` that implements `VaultEntry`
  (`lib/models/vault_entry.dart`). It gets a sealed per-vault list under
  its own storage key, saved through `saveEncryptedValue`, and an
  `_ItemList<T>` in `VaultController` that stamps, saves, rolls back and
  offers Undo. Its key is deleted with the vault by suffix
  (`VaultRegistry.removeVaultData`) and re-sealed on a key-pair
  replacement through `sealedValueKeys`, pinned by
  `test/vault/unknown_sealed_value_test.dart`.
- **Sync** names every kind in `Lists` (`ids`, `toJson`, `==`,
  `hashCode`), in `SyncDoc.fromJson` and the set of keys it keeps out of
  `extra`, and in `combineKeyCopies`, `mergeScope`, `sameDoc`,
  `scopeLists` and `applyScope` (`lib/features/sync/sync_merge.dart`).
  `vw_sync.dart` keeps `keyAccounts` and `logins` on the phone at lines
  331 and 829, and leaves them out of `scopeSum`. Frozen merges in
  `test/compat/before_vault_items`, `before_key_accounts` and
  `before_logins` prove older phones pass later lists through.
- **Websites today.** `Login.websites` and `OtpAccount.websites` are lists
  of hosts from `normaliseWebsite` (`lib/core/websites.dart`).
  `loginDomains` (`lib/features/logins/login_sites.dart`) turns each into
  its registrable domain, or `=host` for an IP or a host under
  `sharedHosts`. `autofillDomains` (`lib/features/autofill/autofill_copy.dart`)
  adds an account's websites as typed, which fills on that host and its
  subdomains. The autofill copy's `domains` and the `=` prefix are all the
  Swift and Kotlin readers know.
- **Vaultwarden.** Logins are never written to an item (the
  `add-passwords` plan, decision 7). A plain code's item is a Bitwarden
  login whose `uris` hold one entry, the 2FA directory's website, with
  `match: null` (`VwWriter.create`, `vw_codec.dart:504`). A passkey's item
  holds `https://<rpId>`. An update starts from the item as the server
  gave it and replaces only Kemlock's own values, so `uris` go back
  untouched today. The `Kemlock` field's plain JSON (`PlainField`,
  `vw_formats.dart`) keeps unknown keys in `extra`, and its `entry` is the
  account's whole JSON, so `uris` already ride inside it.
- **The browser extension** matches in Dart, in the core (the
  `add-browser-extension` plan, decision 8; its task 7.6 isn't built
  yet). Its tasks 2.3 to 2.5 will move `lib/models`, `lib/core` and the
  sync merge into `packages/kemlock_core`.
- The mockups are the web vault's, at 1,440 points wide. The phone sheets
  take their content and rules, laid out as the app's existing sheets.

**Core package check (task 0.1), made at 7ee88deb.** `packages/kemlock_core`
doesn't exist yet: `mobile/packages` holds only `kemlock_ports`,
`parts_free` and `parts_store`, and `lib/models`, `lib/core` and the sync
merge are where they were. The new files therefore go in the app, at
`lib/models/payment_card.dart`, `lib/models/identity.dart`,
`lib/models/website_rule.dart` and `lib/core/website_rules.dart`, free of
Flutter imports, so task 2.3 of the `add-browser-extension` plan can move
them with the rest.

**Owner's answers (task 0.2), 2026-11-21.** Question 1 (a), question 2 (a)
and question 3 (a): every recommendation, as the tasks assume.

### 1. `Card` and `Identity` models

```text
Card      id, name, cardholder?, number? (digits), brand?,
          expMonth? (1-12), expYear? (yyyy), code?, pin?,
          validFromMonth?, validFromYear?,
          note?, tags?, pinned?, spaceId?, source?,
          addedAt, updatedAt?

Identity  id, name, title?, givenName?, middleName?, familyName?,
          company?, email?, phone?, username?, birthDate? (yyyy-mm-dd),
          address?: { lines?: [<=3], city?, region?, postalCode?, country? },
          documents?: [{ id, type, number, issuingCountry?,
                         issuingAuthority?, issuedOn?, expiresOn? }],
          note?, tags?, pinned?, spaceId?, source?,
          addedAt, updatedAt?
```

- Both implement `VaultEntry`, keep unknown keys in `extra` (the
  `address` and each document too), write optional fields only when set,
  and compare by JSON, as `Login` does. Both may sit in a space.
- `document.type` is one of `passport`, `driversLicence`, `idCard`,
  `taxNumber`, `other`. An unknown value reads as `other` and is written
  back as it was read, so a later type survives.
- `brand` is stored, not derived, because Bitwarden and CXF carry one
  that may not match the number's prefix (co-branded cards). The sheet
  offers one from the IIN ranges of Visa, Mastercard, Amex, Discover,
  Diners, JCB, UnionPay and Maestro.
- Calendar dates are `yyyy-mm-dd` strings, and month and year are
  integers. Epoch ms stays for timestamps. A CXF `yyyy-mm` expiry becomes
  two integers, without a day the person never gave.
- *Alternative: Bitwarden's flat identity.* Weighed in owner question 1.
- *Alternative: an `Address` kind of its own*, as CXF has. Rejected for
  now: Bitwarden folds it into identities, and one address per identity
  covers both. A CXF address with no person becomes an identity named
  after it (`add-credential-exchange.md`).

### 2. Storage keys and the controller

`backmycodes_card_data` and `backmycodes_identity_data` (the `backmycodes_`
prefix every vault key keeps) are sealed lists per vault, loaded at `open`.
`_cards` and `_identities` are `_ItemList`s with their toasts. Both keys
join the rotation and unknown-value tests and the deletion-by-suffix test.
Nothing is written until the first card or identity exists, so a vault
without them has the same storage keys it has today.

### 3. Sync and export transport

- `Lists` and `SyncDoc` gain `cards` and `identities` in every place the
  Context lists. `toJson` writes them only when non-empty, after `logins`.
  Before the change, today's merge is frozen as
  `test/compat/before_cards/sync_merge.dart`. The later-lists tests sync
  both kinds through it.
- Merging is the default "changed last wins": a card has no field like a
  password that must never be lost. Both follow accounts into spaces.
- Exports: `cards` and `identities` join `_items` in the sealed and plain
  payloads, only when non-empty. Import adds those whose id is new. The
  export sheet's chips and the "older versions read the rest" line gain
  both. The plain export's warning names card numbers and document
  numbers. QR transfers stay codes-only, and their "not included" line
  names both.
- Vaultwarden: both kinds are kept local next to `logins` at both places
  in `vw_sync.dart`, left out of `scopeSum`, and counted on the sync
  sheet. A test holds that a run writes no cipher for either and keeps
  both.
- *Alternatives:* sealed-home items, or Bitwarden card (3) and identity
  (4) ciphers. Weighed in owner question 2.

### 4. Secrets on screen

The card number shows `•••• 1111` until revealed. The security code, PIN
and document numbers show dots. Each reveal goes through the "Ask before
showing a secret" gate the security audit added. Each copy goes through
`secret_clipboard.dart`, marked sensitive. Number, code and PIN fields
turn off keyboard learning and suggestions (`enableSuggestions: false`,
`autocorrect: false`), as the audit asked of secret fields. Search
indexes the last four digits only.

### 5. `uris`: one optional list beside `websites`

```text
WebsiteRule  uri, match? (0 base domain, 1 host, 2 starts with,
                          3 exact, 4 regular expression, 5 never;
                          absent = default)
Login and OtpAccount gain  uris?: [WebsiteRule]
```

- `match` is Bitwarden's `UriMatchStrategy` number, so a `bw` item's
  `login.uris[]` maps one to one and back. A number this version doesn't
  know reads as "fills nowhere", is kept, and shows as "Unknown rule".
  *Alternative: rule names as strings*, as the mockup's code uses. Rejected:
  every crossing to and from Bitwarden would need a table.
- `uri` keeps what the rule needs:
  - Default, Base domain, Host and Never: the host as `normaliseWebsite`
    gives it, with a port for Host if one was typed.
  - Starts with and Exact: the address with its scheme and host in
    lowercase and its host in ASCII form.
  - Regular expression: the pattern as typed.
  - A URI read from a Bitwarden item is kept exactly as read.
- **Written only when needed.** A model writes `uris` only when some entry
  isn't a bare host on Default, so an item that uses only Default
  websites writes exactly today's JSON. In memory, `uris` is always the
  full list: entries from `uris`, reconciled with `websites`.
- **Writing `websites`.** On every write, `websites` is the list of hosts
  of the entries whose rule isn't 4, 5 or unknown, without duplicates, in
  `uris` order.
- **Reading, reconciled with older builds.** Older builds carry `uris` in
  `extra` and edit only `websites`. A newer build reads them in three
  steps:
  - Each host in `websites` with no `uris` entry of that host joins at
    the end on Default.
  - A `uris` entry that should have its host in `websites` but doesn't
    was removed there, and goes too.
  - Entries on 4, 5 or unknown aren't in `websites`, so they stay.

  An item with no `uris` reads as its `websites` on Default, as today.
- The one gap, as the design doc says: until an older build updates, it
  fills a Host website by the default rule, more widely. The sheet's
  "What other apps see" lines say so.

### 6. One matcher, in pure Dart

`lib/core/website_rules.dart` holds two entry points, with no Flutter
import:

- `phoneDomains(rules, kind)` maps the rules onto the autofill copy's
  `domains`. For logins: Default keeps `loginDomains`' rule, Base domain
  gives the registrable domain, Host, Starts with and Exact give `=host`,
  and 4, 5 and unknown give nothing. For accounts: Default keeps the host
  and its subdomains, as `autofillDomains` adds websites today, and the
  others map as for logins. On every rule, a host under `sharedHosts` or
  an IP becomes `=host` (owner question 3). `loginDomains` and
  `autofillDomains` call it, so the copy keeps version 1 and the native
  readers don't change.
- `fillsOn(rule, address)` answers for a whole address, for the extension
  and the test box. Host compares host and port, with default ports by
  scheme. Starts with is a prefix test, and Exact an equality test, both
  after lowercasing the scheme and host. Regular expression is a search,
  ignoring case, as Bitwarden's `new RegExp(uri, "i").test(url)`.

### 7. Regular expressions: a linear-time engine, not `RegExp`

Dart's `RegExp` backtracks, on the VM and when compiled to WebAssembly for
the extension, where it becomes the browser's own engine. Neither can be
cancelled mid-match without an isolate or a worker per call.
`lib/core/website_rules.dart` therefore parses the pattern into a small
syntax tree and runs it as a Thompson NFA (Pike VM), whose time is
O(pattern × address).

- **Supported:** literals and escapes, `.`, classes with ranges and
  negation, `\d \w \s` and their negations, `^ $`, groups and
  non-capturing groups, alternation, `* + ?`, lazy forms (treated as
  greedy, which changes no yes-or-no answer), and `{m}`, `{m,}`, `{m,n}`
  up to 100.
- **Refused, with a reason:** back-references, lookahead and lookbehind,
  `\b` (shown as unsupported rather than matched wrongly), Unicode
  property escapes, and flags inside the pattern.
- **Bounds:** a pattern over 256 characters is refused. An address over
  2,048 characters never matches. A pattern whose NFA would exceed 4,096
  states is refused, since `{m,n}` expands.
- A pattern read from a Bitwarden item that the engine refuses is kept as
  written, fills nowhere, and is marked "Can't be checked".
- *Alternative: `RegExp` with static checks for nested quantifiers.*
  Rejected: it catches `(a+)+` but not `(a|a)*` or `.*.*.*x`, which are
  polynomial and still hang on 2,048 characters.
- *Alternative: `RegExp` in an isolate with a deadline.* Rejected: the
  extension has no isolates, and two engines could answer differently.
- Cases go in `mobile/test/fixtures/websites/rules.json`: rule, saved URI,
  address and expected answer, including Bitwarden's own examples. The app
  and the extension, both in this repo, are held to it. It is offered to
  the kemlock-server session for the web vault; if the server publishes
  website-rule vectors of its own, the app reads those as well, and where
  the two disagree the server session and the owner settle it.

### 8. The sheets

- The login and account sheets' website list becomes rows of address and
  rule, as `ItemWebsites.dc.html` draws them. The rule picker lists
  Default, Base domain, Host, Exact and Never. Starts with and Regular
  expression sit under an "Advanced" group of the same picker. The
  mockup's "More rules" group is renamed to the decision's word.
- Each row shows its hint ("Fills on …", "Browser: … Phones: …"). The
  sheet ends with "AutoFill on phones: …" and the "What other apps see"
  lines.
- Starts with and Regular expression show the warning. Regular expression
  adds the test box: an address field, and a line that updates as the
  person types, "Matches this address" or "Doesn't match", using
  `fillsOn`.
- The account sheet keeps the 2FA directory's website first and fixed, as
  the `add-passwords` plan's account websites require. Its own websites
  get rules.
- The Vault tab gains Cards and Identities in `VaultFilter` and
  `VaultItemKind`, and the add button lists both. The card and identity
  sheets follow the login sheet's layout.

### 9. A code's websites in its Vaultwarden item

- **Create:** a plain code's `login.uris` is the directory's website, as
  today, then each of the code's own websites as
  `{uri, uriChecksum, match}`. A code with no websites of its own writes
  exactly today's single entry, so `formats.json` and `vault-items.json`
  don't change.
- **Update:** on its own items (`own: true`), Kemlock touches the URIs
  after the first only when the code's own websites changed on the phone
  since the last write, and then only as a patch:
  - a website added on the phone is appended as a URI;
  - a website removed on the phone removes the URI with that address;
  - a website whose rule changed updates that URI's `match`;
  - every other URI after the first, including any a Bitwarden app added
    that Kemlock never took in, is kept exactly as read, in place.
  The first URI stays first. Linked and picked-up logins (`own: false`) are
  the person's own Bitwarden logins, and their URIs are never written.
- **A second sum, only for codes with websites of their own.**
  `PlainField.extra` gains `uriSum` on an item whose code has at least one
  website of its own, and on no other. It is the first 16 bytes of SHA-256
  over the canonical JSON of the URIs after the first, as Kemlock last saw
  them after its write (decrypted `uri` and `match`), base64, made as
  `valuesSum` is. Older builds keep it, because `PlainField` passes `extra`
  through.
  - On reading an item whose revision changed and which carries `uriSum`,
    the reader decrypts its URIs.
  - If their sum differs, they were edited in another app, and the URIs
    after the first replace the code's own websites. A `uri` that
    `normaliseWebsite` can't read is kept only for rules 2, 3 and 4.
  - An item without `uriSum` (a code with no websites of its own, or one
    written before this change) takes nothing in, and gains `uriSum` only
    when the person gives the code a website on the phone. So the `Kemlock`
    field of every plain code without websites stays byte for byte what
    `formats.json` pins.
- Sealed homes need nothing: the account's JSON, `uris` included, is
  inside the seal.

### 10. Sequencing with the core package

The `add-browser-extension` plan's tasks 2.3 to 2.5 move `lib/models`,
`lib/core`'s matching and the sync merge into `packages/kemlock_core`
with `git mv`. Each old path keeps a one-line `export`. This plan keeps
every new model and `website_rules.dart` free of Flutter imports. If it
lands first, task 2.3 there moves the new files with the rest. If the
move lands first, the new files go straight into the core, and the app
imports them through the old paths' exports. Task 0.1 checks which case
applies. The UI and `vw_codec.dart` stay in the app either way.

### 11. Fixtures, written once

- `mobile/test/fixtures/cards/`: a vault storage dump with both keys, an
  encrypted and a plain export, and a sync document with cards and
  identities in the own scope and a space, plus a `README.md` saying how
  they were written.
- `mobile/test/fixtures/logins/sync-with-uris.json`: a login and an
  account with every rule, and the same entries as the previous version
  writes them back (`uris` in `extra`).
- `mobile/test/fixtures/websites/rules.json` (decision 7).
- `mobile/test/fixtures/vaultwarden/code-websites.json`: a plain code's
  item with websites, and the same item after a Bitwarden-side edit.
- Existing fixtures are only read, never rewritten.

### 12. Free, and the commit scopes

Cards and identities are free, as logins are, on every backend. Commits use these
scopes (`sync` is added to `CLAUDE.md` by the main session before building
starts):

- `vault`: the models and storage;
- `passwords`: website rules on logins;
- `accounts`: rules on codes;
- `autofill`: the domain mapping;
- `extension`: the matcher's use there;
- `sync`: transport;
- `export`: exports.

### Risks

- [An older build fills a Host website on its base domain] → The sheet
  says so under "What other apps see". The gap closes as builds update,
  and it never fills on a site outside the saved domain.
- [The regex engine answers differently from Bitwarden's on an exotic
  pattern] → Unsupported constructs are refused, never approximated.
  `rules.json` holds Bitwarden's own examples. A refused pattern fills
  nowhere rather than somewhere wrong.
- [Two lists, `websites` and `uris`, drift apart] → One function writes
  both, and one reads and reconciles. Property tests generate random
  edits from an "older build" that touches only `websites`, and check the
  invariants after each read.
- [A Bitwarden-side edit of a code's URIs is lost to a concurrent Kemlock
  edit] → The usual `lastKnownRevisionDate` check makes the Kemlock write
  fail and re-read first, as for every plain value today. And a write only
  patches the URIs the phone's change touched, so a URI added elsewhere
  is never dropped.
- [Card numbers on screen] → They are masked by default, reveals are
  gated, `FLAG_SECURE` and the iOS snapshot cover are already in place,
  and the full number can't be searched.

### Migration

Nothing to migrate: no stored value changes until the person adds a card,
an identity or a non-default website. Rolling back to the previous build
keeps all of them, as later lists and `extra` keys. The previous build
then fills Host websites by the default rule, as the Risks say.

## Behaviour

### Cards

**A card holds a payment card's details.** A card has a name, and a
number, a cardholder or both. It may have a brand, an expiry month and
year, a security code, a PIN, a "valid from" month and year, a note, tags,
a pin and a space. Cards are free.
- When the person adds "Everyday Visa" with a number, the cardholder,
  expiry 05/2029 and the code 123, it is listed under Cards and stays after
  the vault is opened again.
- When only a name is filled in, Save is unavailable, and the sheet says a
  card needs a number or a cardholder.
- When a person adds a fifth card, it saves with no prompt.

**A card number is kept as its digits.** Spaces and dashes are dropped,
and 8 to 19 digits are accepted. A number failing the Luhn check saves
after a warning. A brand is offered from the leading digits, and the
person may change it.
- When the person pastes "4111-1111 1111-1111", the card keeps
  4111111111111111, and Visa is offered.
- When the person enters 4111 1111 1111 1112, the sheet warns, and Save
  still works.
- When the person enters "4111 abcd", the sheet says a number holds only
  digits, and Save is unavailable.

**The expiry is a month and a year.** The month runs from 1 to 12 and the
year has four digits. Either may be missing, and a two-digit year reads as
20xx. A card whose expiry month has ended is marked expired.
- When the person types "05/29", the card keeps month 5 and year 2029.
- When the Cards filter is opened on 1 June 2029, a card expiring 05/2029
  shows "Expired".

**Cards are listed under the Cards filter.** Pinned cards come first, each
row showing its name, brand and last four digits. Search finds a card by
its name, cardholder, brand, tags or last four digits, and never by its
full number, code or PIN.
- When the person searches "1111", "Everyday Visa" shows as "Visa · 1111".
- When the person searches "11111111", no card is found by its number.

**A card's secrets show only when asked.** The number is masked but for
its last four digits, and the code and PIN are hidden. Each reveal goes
through "Ask before showing a secret", and each copy through the clipboard
that clears itself, marked sensitive.
- When the person taps the number, it shows grouped in fours and hides
  again when the sheet closes.
- When the person copies the code, the clipboard holds 123 until the
  timeout clears it.

**Deleting a card can be undone.** A confirmation comes first, then a
toast with Undo.
- When the person deletes a card and taps Undo, it is back with every
  field.

**Cards are stored encrypted with the vault.** They are sealed under
their own storage key, deleted with their vault, and re-sealed when the
key pair is replaced.
- When a locked vault's storage is read, no card name, cardholder, number,
  code or PIN appears in it.
- When the person deletes the vault, its cards leave storage with it.

**Cards sync through WebDAV, in the vault and its spaces.** The copy
changed last wins.
- When one phone adds a card and the other syncs, the other lists it.
- When a card moves into "Family" and another member syncs, the member
  sees it in "Family".

**Older versions pass cards through untouched.** A file without cards is
byte for byte what this version writes today.
- When a phone on the previous version renames an account and writes a
  sync file that holds cards, the cards are still in it, unchanged.
- When a vault with no cards syncs, the sync file has no `cards` key.

**Exports carry cards, and QR transfers don't.** Import adds the cards
whose id is new. The export sheet counts them and says that a plain export
shows numbers and codes.
- When a vault with two cards is exported and imported into an empty
  vault, both cards arrive with every field.
- When the QR transfer sheet is opened, it lists cards among what isn't
  included.

**Vaultwarden sync leaves cards on the phone and says so.**
- When a vault with two cards syncs with Vaultwarden, no item is written
  for them, both stay, and the sheet says two cards stay on this phone.

### Identities

**An identity holds a person's details.** It has a name for the list and
at least one detail. The details may be a title, given, middle and family
names, a company, an email, a phone, a username, a birth date, one
address, documents, a note, tags, a pin and a space. Identities are free.
- When the person adds "Me" with a name, an email and a London address,
  it is listed under Identities and stays after the vault reopens.
- When only "Me" is filled in, Save is unavailable, and the sheet says an
  identity needs at least one detail.

**An address has up to three lines, a city, a region, a postal code and a
country.** A country picked from the list is kept as its ISO 3166-1
alpha-2 code, and a typed one as typed.
- When the person picks "United Kingdom", the identity keeps "GB" and
  shows "United Kingdom".

**An identity holds documents.** Each document has a type (passport,
driver's licence, ID card, tax or social security number, or other) and a
number. It may have an issuing country and authority, and issue and expiry
dates. A document past its expiry date is marked expired.
- When the person adds a passport 123456789 from GB expiring 2031-03-14,
  it lists as "Passport · GB · expires 14 Mar 2031".
- When a licence expired yesterday, it shows "Expired".

**Document numbers show only when asked.** They are hidden until tapped,
under the reveal gate. They are copied through the self-clearing
clipboard, and search never finds them.
- When the person taps the passport number, it shows, and hides when the
  sheet closes.
- When the person searches "123456789", no identity is found.

**Identities are listed under the Identities filter.** Each row shows its
name and the person's full name or email. Search finds an identity by its
name, the person's names, the company, the email or the tags.
- When the person searches "ada@example.org", "Me" is among the results.

**Identities are kept and carried as cards are.** That means sealed
storage under their own key, deletion with the vault, re-sealing, WebDAV
in the vault and its spaces, and both exports. They stay out of QR
transfers, stay on the phone with Vaultwarden, pass through older versions
untouched, and Undo works after a delete.
- When a locked vault's storage is read, no name, address, email or
  document number appears in it.
- When an older phone writes a sync file holding identities, they are
  still in it, unchanged.
- When an identity with two documents is exported and imported into an
  empty vault, it arrives with both.
- When a vault with an identity syncs with Vaultwarden, no item is written
  for it, and the sheet says one identity stays on this phone.

### Websites and their rules

**Each website of a login or code has a rule.** The rules are Default,
Base domain, Host, Exact and Never, plus Starts with and Regular
expression under Advanced. A new website starts on Default. A login or
code whose websites all use Default behaves and is stored as before.
- When "Example Co SSO" gets example.co (Default) and example-co.okta.com
  (Host), both are listed with their rules.
- When a login has github.com on Default, it is stored exactly as today.

**The sheet says where each rule fills, on phones and in the extension.**
It also says which hosts the whole login fills on with phone AutoFill.
- When example-co.okta.com is set to Host, the sheet says it fills there
  only.
- When https://intranet.example.co/login is set to Exact, the sheet says
  the browser fills that address only and phones fill on
  intranet.example.co only.

**Phone AutoFill fills by host.** Default keeps today's rule. Base domain
fills on the registrable domain and every host under it. Host, Starts with
and Exact fill on their host only. Regular expression and Never don't fill.
A code's websites follow the same rules, with Default keeping a code's
rule: the host and its subdomains.
- When a login has accounts.larkspur.example on Base domain, it is
  suggested on mail.larkspur.example.
- When a login has example-co.okta.com on Host, it isn't suggested on
  other-co.okta.com.
- When a login's only website, wiki.example.co, is on Never, it isn't
  suggested there and still lists the website.

**Shared hosts and IP addresses stay exact.** A website under a host
anyone can open a site under, or an IP address, fills on itself only,
whatever its rule (owner question 3).
- When example-co.okta.com is on Base domain, the login fills there and
  not on other-co.okta.com, and the sheet says why.

**The browser extension matches whole addresses.** Host compares the host
and its port. Starts with fills an address that begins with the saved
one, and Exact only that address. Regular expression fills an address the
pattern finds a match in, ignoring case. Scheme and host compare in
lowercase; the path, query and fragment compare as written.
- When https://intranet.example.co/login is on Starts with, the extension
  offers it on …/login?next=/home, and not on …/admin.
- When nas.home.example:5001 is on Host, the extension doesn't offer it on
  port 8080.

**Advanced rules carry a warning.** Starts with and Regular expression
appear only under Advanced, with Bitwarden's warning that the rule is
dangerous if used carelessly.
- When the person picks Starts with, the warning shows under the website.

**A regular expression has a test box.** As an address is typed, the
sheet says whether the pattern matches. It also says that phones never
fill this website, and only the browser extension does.
- When `^https://([a-z]+\.)?example\.co/` is tested on
  https://shop.example.co/cart, the sheet says it matches.
- When it is tested on https://example.co.evil.test/, the sheet says it
  doesn't.

**A regular expression can't hang the app.** A pattern is refused when
it is over 256 characters, or uses back-references, lookarounds or a
repeat over 100, and the sheet says which. Matching takes time linear in
the address's length. An address over 2,048 characters never matches.
- When the person enters `(a)\1`, the sheet says back-references aren't
  supported, and Save is unavailable.
- When `(a+)+$` is tested on 2,000 letters "a" and a "!", the test box
  answers at once that it doesn't match.
- When a code's Bitwarden item holds a pattern the matcher refuses, the
  website is kept, marked "Can't be checked", and fills nowhere.

**Older versions keep filling on the hosts.** `websites` keeps the hosts
of every website not on Regular expression or Never, and older versions
keep the rules when they write the entry back.
- When an older phone syncs a login with example.co (Default),
  example-co.okta.com (Host) and wiki.example.co (Never), it fills on the
  first two only.
- When the older phone renames the login and both phones sync, the login
  keeps its three websites and their rules.

**Websites changed on an older phone are taken in.** A host added there
joins on Default. A website whose host was removed there goes too, unless
it is on Regular expression or Never, which that version doesn't show.
- When the older phone adds example.org, the login gets example.org on
  Default, after its other websites.
- When the older phone removes example-co.okta.com, it goes, and
  wiki.example.co stays on Never.

**A code's websites travel in its Vaultwarden item.** A plain-synced code
lists its own websites in the item's URIs with Bitwarden rules, after the
2FA directory's website, which stays first. Edits made in a Bitwarden app
come back at the next sync. A code without websites writes the item
exactly as before.
- When a GitHub code has github.example.org on Host, its URIs are
  github.com with no rule, then github.example.org with rule 1.
- When that rule is set to Exact in the Bitwarden app and Kemlock syncs,
  the code's website has the rule Exact.
- When a code has no websites of its own, its item is byte for byte what
  this version writes today.

**A Never website doesn't link a code.** Offering a login's code by
website skips Never websites, on both sides.
- When a code's only website, example.co, is on Never, a new login for
  example.co isn't offered that code by its website.

## Tasks

Cards and identities (groups 1 to 4) come before any importer of
`add-credential-exchange.md`. Website rules (groups 5 to 8) don't depend
on them and may be built in a worktree of their own. Coding agents don't
run builds, tests, CI or `pub get`. Each "Verify" names the test that the
single build-and-test pass after merging runs, from the main session, or a
check the owner makes on a device.

### 0. Before starting

- [x] 0.1 Check whether the `add-browser-extension` plan's tasks 2.3 to 2.5 have moved `lib/models`, `lib/core` and the sync merge into `packages/kemlock_core`. Record which paths the new files take under Design decision 10 of this plan. Verify that the note names the commit the check was made at.
- [x] 0.2 Get the owner's answers to the three Decisions for the owner. Update this plan to the answers before group 1. Verify that the plan records the answers and the date.

### 1. Card and identity models

- [x] 1.1 Add `PaymentCard` (`lib/models/payment_card.dart`) per decision 1. It implements `VaultEntry` and keeps `extra`. It writes optional fields only when set and compares by JSON. It keeps a digits-only `number`, `expMonth` from 1 to 12 and a four-digit `expYear`, and has `isExpired(now)`. Verify with model tests for round trips, unknown keys, a pasted number, two-digit years, and expiry on the last day of the month.
- [x] 1.2 Add `Identity` (`lib/models/identity.dart`) with `address` and `documents`, each keeping its own `extra`. An unknown document `type` reads as `other` and is written back as read. Verify with model tests, including a document type from a later version surviving a round trip.
- [x] 1.3 Add the card brand from IIN ranges and the Luhn check (`lib/features/cards/card_number.dart`). Verify with tests on each brand's test numbers and a failing Luhn number.

### 2. Storage and the controller

- [x] 2.1 Store cards under `backmycodes_card_data` and identities under `backmycodes_identity_data` through `VaultStore`, with `_ItemList`s in `VaultController`: load at open, add, update, delete with Undo, and `applySynced`. Write nothing until the first one exists. Verify with controller tests, `storedText` showing no number, code, PIN or document number in the clear, and both keys listed in the rotation, unknown-value and deletion tests.
- [x] 2.2 Write `mobile/test/fixtures/cards/vault-with-cards.json` (a storage dump with both keys) once, with a `README.md`. Verify that a test opens it with its password and lists its cards and identities. (Written in 153dec7f; `cards_fixtures_test.dart` opens it, verified 2026-11-22.)

### 3. Transport

- [x] 3.1 Freeze today's merge and models as `test/compat/before_cards/`, before touching `sync_merge.dart`. Verify that the frozen copy compiles in the test suite and its own tests pass.
- [x] 3.2 Add `cards` and `identities` to `Lists` and `SyncDoc` in every place decision 3 lists, written only when non-empty, after `logins`. Verify with sync tests that a vault without them writes byte for byte what the frozen merge writes, and that a sync file and a space file holding them survive a write through `before_cards`.
- [x] 3.3 Write `mobile/test/fixtures/cards/sync-with-cards.json` (own scope and a space) once. Verify that it reads and merges in a test. (Written in 153dec7f; `cards_fixtures_test.dart` reads and merges it, verified 2026-11-22.)
- [x] 3.4 Add both kinds to the encrypted and plain export payloads and to import, for new ids only. Add the export sheet's chips, the "older versions" line, and the plain export's warning naming card and document numbers. Add both to the QR sheet's "not included" line. Verify with round-trip tests, a frozen copy of today's `_payload` opening the new file for its codes, and widget tests of both sheets.
- [x] 3.5 Write `mobile/test/fixtures/cards/export-with-cards.json` and `export-with-cards-plain.json` once. Verify that the import test opens both. (Written in 153dec7f; `cards_fixtures_test.dart` opens both, verified 2026-11-22.)
- [x] 3.6 Keep both kinds on the phone in `vw_sync.dart` beside `logins` (both places), out of `scopeSum`, and count them on the Vaultwarden sheet. Verify with a test that a run writes no cipher for them and keeps them, and that the sheet shows the count.

### 4. Card and identity screens

- [x] 4.1 Add `cards` and `identities` to `VaultFilter` and `VaultItemKind`. Card rows show the name, "Visa · 1111" and "Expired"; identity rows show the name and the full name or email. Search uses only the fields Behaviour allows. Verify with `vault_items_test.dart` cases for each search scenario, including a full card number and a document number finding nothing.
- [x] 4.2 Add the card sheet and its new and edit form, following the login sheet. It has the masked number, the code and PIN hidden behind the reveal gate, copies through `SecretClipboard`, keyboard learning off on secret fields, the Luhn warning, and Delete with Undo. Verify with widget tests using `FakeSensitiveClipboard`, and a flow test that adds, edits and deletes a card.
- [x] 4.3 Add the identity sheet and its form. It has name parts, contact details, the address with the country picker (ISO 3166-1 codes), documents with type, dates and expiry, and the reveal gate on numbers. Verify with widget tests and a flow test that adds an identity with two documents.
- [x] 4.4 Add "New card" and "New identity" to "Add to vault", and the `en.json` and `fr.json` copy for groups 3 and 4. Verify with `test/i18n/messages_test.dart`, and a widget test that the add sheet lists both.

### 5. Website rules in the models

- [x] 5.1 Add `WebsiteRule` (`lib/models/website_rule.dart`) and `uris` on `Login` and `OtpAccount` per decision 5. On read, reconcile with `websites`. On write, derive `websites` from the rules, and write `uris` only when some entry isn't a bare host on Default. Keep an unknown `match` number. Verify with model tests for each reconciliation case in Behaviour, and that every login and account in the existing fixtures round-trips byte for byte.
- [x] 5.2 Add property tests that alternate random "older build" edits (models from `test/compat/before_cards`, which carry `uris` in `extra`) touching only `websites` with new-build reads. Verify that after each read `websites` equals the hosts of the fill rules, and that no Regular expression or Never entry is lost.
- [x] 5.3 Write `mobile/test/fixtures/logins/sync-with-uris.json` once, with every rule and the older build's write-back. Verify that it reads into the expected rules. (unverified: written by hand; the single pass after merging runs the test)

### 6. The matcher

- [x] 6.1 Write `mobile/test/fixtures/websites/rules.json` once. Each case has a rule, a saved URI, an address, the expected answer and the expected phone domains. Include Bitwarden's documented examples, shared hosts, IPs, ports, and the scenarios in Behaviour. Add a README saying it is never regenerated. Verify that the file and README exist.
- [x] 6.2 Implement the pattern engine in `lib/core/website_rules.dart` per decision 7: the parser, refusals with reasons, length and state bounds, and Pike VM matching ignoring case. Verify with every regex case of `rules.json`, a test that each refused construct gives its reason, and a step-count test: the engine counts the state steps a match takes, and `(a+)+$` against 2,000 letters and a "!" stays under the bound of NFA states × (address length + 1), with no wall-clock timing.
- [x] 6.3 Implement `fillsOn` and `phoneDomains`, and make `loginDomains` and `autofillDomains` call `phoneDomains`. Verify with every case of `rules.json`, every existing `autofill_copy_test.dart` and `login_sites_test.dart` expectation unchanged, and the copy still at version 1.
- [x] 6.4 Skip Never websites in `offeredAccount`, on both sides. Verify with a test of the "A Never website doesn't link a code" scenario.
- [ ] 6.5 Hold the extension to the same cases when its matching lands (the `add-browser-extension` plan's task 7.6): add `rules.json` to its Dart core tests run with `dart test -p chrome -c dart2wasm`. Verify in the single build-and-test pass after merging that the run passes, or leave this task open with a pointer in that plan's tasks. Not started: the extension has no Dart core yet and the `add-browser-extension` plan is not in this tree, so there is nothing to hold to the cases. `mobile/test/fixtures/websites/rules.json` carries the `registrable` table and the phone domains it needs, and `lib/core/website_rules.dart` has no Flutter import, so its move into `packages/kemlock_core` is a `git mv`.

### 7. The website editor

- [x] 7.1 Replace the login sheet's website list with rows of address and rule (`ItemWebsites.dc.html`). It has the five rules, the Advanced group with Starts with and Regular expression, each row's hint, the warning, "AutoFill on phones" and "What other apps see". Verify with widget tests of the "sheet says where each rule fills" and "Advanced rules carry a warning" scenarios.
- [x] 7.2 Add the regex test box and the refusal messages. Save is unavailable on a refused pattern, and a refused pattern read from elsewhere shows "Can't be checked". Verify with widget tests of the three regex scenarios.
- [x] 7.3 Give the account sheet's own websites rules, keeping the directory's website first and fixed. Verify with a widget test, and that the `add-passwords` account-websites tests still pass.
- [x] 7.4 Add the `en.json` and `fr.json` copy for groups 5 to 7. Verify with `test/i18n/messages_test.dart`.

### 8. Vaultwarden

- [x] 8.1 On create, write a code's own websites after the directory's URI. On update, patch them only for `own: true` items whose websites changed on the phone, keeping every other URI, per decision 9. Verify with codec tests that a code without websites matches `formats.json` and `vault-items.json` byte for byte, `Kemlock` field included, that linked logins' URIs are never written, and that a URI a Bitwarden app added to a code without websites survives a Kemlock edit of the code's issuer.
- [x] 8.2 Add `uriSum` to `PlainField.extra` only for codes with websites of their own, and take in the URIs of a changed revision whose sum differs. Verify with tests against `test/fake_vaultwarden.dart`: a Bitwarden-side rule change reaches the code; an item without `uriSum` takes nothing in and gains none on a write that adds no website; an older build's `PlainField` (a frozen copy) passes `uriSum` through.
- [x] 8.3 Write `mobile/test/fixtures/vaultwarden/code-websites.json` once, holding the item and the item after a Bitwarden edit. Verify that the codec tests read it.

### 9. Integration

- [x] 9.1 After merging, the main session runs `dart format`, `flutter analyze` and the whole `flutter test` suite once from `mobile/`. Verify that all three pass, and record the counts in this plan. (2026-11-22 at b4674433: `dart format` leaves nothing to change, `flutter analyze` finds no issues, and `flutter test` passes 9,143 with 474 skipped.)
- [ ] 9.2 The owner, on an Android phone and an iPhone, adds a card and an identity, reveals and copies their secrets, and syncs them through WebDAV to a second phone, then fills a login with a Host website and one with a Never website. Record what passed in this plan. (code done; verify after merge)

## Dependencies

- `docs/plans/add-credential-exchange.md` maps Bitwarden, CXF and the
  Dart importers onto cards, identities and `uris`, so groups 1 to 4 land
  before its first importer.
- `docs/plans/add-duplicate-cleaner.md` makes `card` tags from the number
  and expiry, `identity` tags, and one `cred` and `account` tag per
  website. It skips Regular expression and Never websites, and merges
  `uris` by taking the union, with the narrower rule kept for an address
  with two rules.
- `docs/plans/move-off-vaultwarden-sync.md` maps a `bw` login's
  `login.uris[]` one to one onto `uris`, keeps the first URI first, and
  moves cards and identities kept on the phone into `kem1` items.
- `docs/plans/add-kemlock-server-sync.md` carries both kinds and `uris`
  inside the encrypted `kem1` item, under the kinds `card` and `identity`
  that the server's `crypto.md` already names. The server sees neither.
- `docs/plans/add-server-spaces.md` puts cards and identities in spaces
  as other kinds are, through `spaceId`.
- `docs/plans/add-account-crypto.md`: no dependency. Nothing here needs
  the account keys.
- Outside this set: the `add-browser-extension` plan's move into
  `packages/kemlock_core` (decision 10) and its matching task 7.6 (task
  6.5 here). The `add-passwords` plan (git history before 5ba88b42) is
  the base for logins and account websites.
