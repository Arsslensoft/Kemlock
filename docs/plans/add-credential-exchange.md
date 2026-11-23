# Credential Exchange import and export

Kemlock takes logins, codes, passkeys, cards, identities, notes and SSH keys
from another password manager on the same phone, through the hand-off iOS 26
and Android's Credential Manager broker, or from a Credential Exchange file.
One Dart reader serves every source, and everything goes through the same
preview, limits and duplicate step as a file import before anything is saved.
Kemlock can also hand its own items to another manager the same way, behind
an owner check and its own security review.

## Why

Passkeys can't be moved by file out of Apple Passwords, Google Password
Manager, 1Password or Dashlane. The one way out is Credential Exchange. The
owner decided on 2026-11-21 that Credential Exchange lands in the mobile app
first and in the web vault later. They also decided that cards and identities
join Kemlock before the first importer ships (Kemlock Server design doc,
Decisions table).

The format is settled. CXF 1.0 is a FIDO Proposed Standard (14 August 2025),
with errata of 9 March 2026 that correct only its example payload. Android's
transfer library reached 1.0.0-beta01 on 9 September 2026.

## What changes

- **A CXF 1.0 reader in Dart.** It reads a CXF header with its accounts,
  collections and items. It follows the format's rules for unknown fields,
  unknown enumeration values and required arrays. It has the same file,
  entry and nesting limits as the other importers, and fixtures pin it.
- **What each credential becomes.**
  - `basic-auth` and the item's scope become a login with every website:
    its URLs go into `uris` with the default rule.
  - `totp` becomes a code entry, linked to the login of the same item.
  - An ES256 `passkey` becomes a passkey. Other algorithms are skipped and
    listed.
  - `note` becomes a note, `credit-card` a card, and `ssh-key` an SSH key.
  - `address`, `person-name`, `identity-document`, `passport` and
    `drivers-license` become one identity.
  - A `custom-fields` credential goes into its item's note.
  - `file`, `wifi`, `api-key`, `generated-password`, `item-reference` and
    unknown types are skipped, each listed with its reason.
  - Collections become tags, nested ones as `Parent / Child`, as importers
    already treat groups.
- **Import from another app on the phone.**
  - iOS 26: the AutoFill extension declares `SupportsCredentialExchange`
    and version `1.0`. The app takes `ASCredentialExchangeActivity` and
    reads the data through `ASCredentialImportManager` after the vault is
    open. On iOS the export always starts in the other app, so Kemlock's
    Import sheet says where to start it.
  - Android 8 and later, store build: Import opens the system's selector
    through `ProviderEventsManager.importCredentials`, which runs on Play
    services.
  - Both paths end in the same preview as a file import, with the same
    duplicate step, before anything is saved.
- **A CXF file, everywhere.** A `.json` file holding a CXF header, such as
  one another manager wrote, opens through the existing Import sheet. Like
  every other format, it is recognised from its content. In the free build
  this is all of Credential Exchange. The F-Droid build has no Play
  services, so it offers no system hand-off, and it says so.
- **Several accounts or a shared collection.** The preview asks where each
  CXF account goes: the vault, or a new space. A collection the person
  shared with others in the old app (the format's `shared` extension) gets
  a new space preselected, as the owner decided for shared vaults.
- **Duplicates.** The rules are the one module the duplicate cleaner makes
  (`duplicate_rules.dart`), whose tasks group 1 must land first. A login
  matches on its site, username and password; one that shares only the site
  and username is imported, and the cleaner shows the pair. A code matches
  on its secret, a passkey on its relying party and credential id, and a
  card on its number and expiry. The preview offers skip, keep both or
  replace.
- **Export to another app on the phone.** On iOS 26, Kemlock answers
  `ASCredentialExportManager` as an exporter; on Android, it registers as an
  export source with Credential Manager's provider events. The person picks
  what goes (the vault or a space, and which kinds), passes the owner check
  every export takes, and the items go across as CXF. This ships only after
  its own security review (tasks group 8).
- **Nothing plain is left behind.** On Android, the transfer's temporary
  file is in Kemlock's cache. It is deleted once read, and swept on lock
  with the other scratch files.

Out of scope:

- **Other managers' files**: CSV (Chrome, Edge, Safari, Firefox, LastPass,
  NordPass), 1PUX, KDBX, Bitwarden's encrypted JSON, Dashlane, Keeper,
  Proton Pass and Enpass, the design's P1 and P2 list. They are a later
  Dart plan unless the owner wants them folded in; owner decision 2.
- The web vault's Credential Exchange, which waits for CXP's remote
  transfer.
- **Files.** Neither OS hand-off carries a file's bytes: the format sends a
  placeholder, and CXP, the protocol that would carry the bytes, is still a
  Working Draft.
- Storing what Kemlock can't use. A credential with no Kemlock kind is
  listed as skipped, not kept in `extra`.
- Autofilling cards or identities.
- Gating: none. Import and export are free, as file imports and exports are,
  and so is a new space as a destination.

## Decisions for the owner

Decided by the owner on 2026-11-21: every recommendation below, as the tasks assume.

The tasks assume the recommended option of each.

1. **Ship Credential Exchange export with import, as asked, or defer it?**
   - *Ship it with import (the owner's ask; the tasks assume it).* Export is
     tasks group 8, built after import's groups. It is a larger security
     surface than import: an exported Android activity with caller and nonce
     checks, an export entry registry, an iOS export sheet, and the audit's
     "every export asks first" rule for a flow that sends every secret to
     another app. So group 8 ends with a security review (task 8.6) that
     must pass before a release turns export on; until then export is built
     but switched off.
   - *Defer it* to a follow-up plan. Import ships sooner and alone; the
     encrypted and plain exports, and the server's
     `GET /kem/v1/account/export`, serve GDPR portability meanwhile.
2. **Other managers' files: a separate plan, or folded in?**
   - *Separate (recommended; the tasks assume it).* The P1 list becomes one
     Dart plan, `add-manager-imports`, after this one. It covers the Chrome,
     Edge, Safari, Firefox, LastPass and NordPass CSVs, 1PUX, KDBX 3.1 and 4
     with key files, Bitwarden's password-protected JSON, Dashlane's CSV
     ZIP, Keeper's JSON and Proton Pass's ZIP. On phones, CXF already
     covers Apple, Google, 1Password, Bitwarden and Dashlane, and KDBX
     alone is a project.
   - *Folded in.* One import plan, much larger, with every format's
     fixtures to collect first.
3. **The free build: a CXF file only, or the bare `providerevents` library
   without Play services?**
   - *A CXF file only (recommended; the tasks assume it).* It keeps the free
     build's "no Play services" check clean for certain.
   - *The bare library.* It keeps the check clean only if the library has no
     Play services classes, and nothing documents a selector on phones
     without Play services. Task 5.5 checks this at no cost to the plan.

## Design

### Where things stand

- **Importers.** `lib/features/import/importers.dart` (982 lines)
  recognises a file from its text and returns a `ForeignImport`: accounts,
  passkeys and a skipped count. `import_merge.dart` turns a preview into
  the vault's lists. Accounts match on issuer and secret, passkeys on
  credential id, and logins only by id.
- **add-code-imports** (not built yet) adds `detectFile(bytes, {name})`
  and one file per format under `formats/`. It also adds
  `formats/limits.dart` (32 MiB a file, 10,000 entries, ZIP and KDF
  limits) and `skippedEntries`, with a reason for each. This plan builds on
  all of those and lands after them.
- **The kinds.**
  - Cards, identities and `uris` come from
    `docs/plans/add-cards-identities-and-websites.md`
    (`lib/models/payment_card.dart`, `identity.dart`, `website_rule.dart`).
  - Kemlock has tags, not folders, so a collection becomes a tag, as Aegis
    and 2FAS groups do today.
  - SSH keys are `VaultKey`s of kind `ssh`, with the private half in
    PKCS#8 DER, the encoding CXF uses.
  - Passkeys keep a PKCS#8 private key in base64, with COSE algorithm `-7`,
    as the Bitwarden import makes them (`_bitwardenPasskey`).
- **The format.**
  - It is JSON. A `Header` holds `version {major, minor}`, the exporter's RP
    id and name, a timestamp, and `accounts`.
  - Each `Account` holds `collections` and `items`. Collections nest, and
    link items by id.
  - Each `Item` holds a title, an optional `scope {urls, androidApps}`,
    `credentials`, `tags` and `extensions`. Values sit in
    `EditableField {fieldType, value, label?}`, and byte strings are
    base64url.
  - Unknown fields are ignored. An unknown enumeration value in an optional
    field counts as absent; in a required field it drops the structure.
    Required arrays are always present.
  - A `file` credential is only a placeholder; the format leaves its bytes
    to the transfer protocol.
- **iOS.**
  - From iOS 26. The credential provider extension declares
    `SupportsCredentialExchange` and `SupportedCredentialExchangeVersions`
    `["1.0"]`.
  - The exporting app starts the transfer. The system then launches the
    importer with an `NSUserActivity` of type
    `ASCredentialExchangeActivity`. Its `userInfo` holds a UUID under
    `ASCredentialImportToken`.
  - `importCredentials(token:)` returns `ASExportedCredentialData`. That
    type and its accounts, items and credentials are `Codable`, documented
    as CXF's own entities, with dates in seconds since 1970.
  - Kemlock's AutoFill extension already declares passwords, passkeys,
    codes and generation (`ios/AutoFill/Info.plist`). Runner and the
    extensions target iOS 15.5 and 18.0.
- **Android.**
  - The library is `androidx.credentials.providerevents:providerevents` and
    `providerevents-play-services`, 1.0.0-beta01, for Android 8 (API 26)
    and later.
  - The importer starts the transfer.
    `ProviderEventsManager.importCredentials(activity,
    ImportCredentialsRequest(credentialTypes, knownExtensions))` opens the
    system's selector. It returns the exporter's package and
    `responseJson`, a CXF string.
  - The guide's sample predates beta01 and gives the older coordinates,
    `androidx.credentials:providerevents`.
  - The transfer runs through a FileProvider URI backed by temporary cache
    files, because a vault can exceed Binder's 1 MB. On Play phones, the
    selector is Google Play services (`com.google.android.gms`).
  - The app already has `androidx.credentials` 1.6.0 for its passkey
    provider, `minSdk` 24 and `compileSdk` 37.
- **The free build** (add-fdroid-release). It swaps `kemlock_parts` for
  `packages/parts_free`, and its check (decision 9 there) refuses any class
  under `com.google.android.gms` in the APK. So nothing that pulls in Play
  services may sit in the app module.
- **The audit** (`plans/security-audit-2026-11-21.md`, merged in
  28724703).
  - Imports have limits that are checked before any work: a37170d8 bounded
    a QR claiming a billion codes, and 4b27b549 bounded Aegis's scrypt per
    slot.
  - Plain copies in the cache are swept on lock (`app/scratch_sweep.dart`).
  - Every export asks first.
- **Mockups.** The canvas's "Import and export" page
  (`ImportExport.dc.html`) is the web vault's. It has a "From" list, a drop
  zone, and an "Into" choice of vault or space. The app has no Credential
  Exchange mockup, so this plan adds rows to the app's existing Import
  sheet, and task 6.1 asks for a canvas page.

### Decisions

1. **The platforms give Dart CXF JSON, and Dart does all the reading.** On
   iOS, Swift encodes the `ASExportedCredentialData` it receives back into
   CXF JSON, with `JSONEncoder` and `dateEncodingStrategy =
   .secondsSince1970`. Android hands over CXF JSON already. Either way the
   bytes go to Dart over a method channel, and `formats/cxf.dart` reads
   them as it reads a file.
   - *Rejected: mapping `ASImportable*` to Kemlock's kinds in Swift, and
     CXF in Kotlin.* That is three readers to keep equal, and Swift and
     Kotlin can't reach the vault's models or the duplicate rules. Apple's
     types also drop what they don't model.
   - *Still to check on a device (task 4.3):* whether re-encoding keeps
     every credential type. Apple's enum lists basic auth, passkey, TOTP,
     note and credit card, plus address and API key structs. CXF defines
     more.
2. **Read into neutral records, then map.** `cxf.dart` works in two steps.
   - It parses into small immutable records: `CxfHeader`, `CxfAccount`,
     `CxfCollection`, `CxfItem`, a sealed `CxfCredential` with one class
     per type, and `CxfUnknown`. This step applies the format's version and
     unknown-value rules, and the limits.
   - A mapper turns the records into a `ForeignImport` of Kemlock's kinds.
     The mapping table is the format behaviour below.
   - Both steps are pure Dart with no Flutter. They move into
     `kemlock_core` with the other importers when add-browser-extension
     makes it. The FIDO example fixture is the spec's own and may be read by
     the server's web vault too; `cases.json` stays the app's own test
     cases, not a vector shared with the server.
   - *Rejected: mapping straight from `Map<String, Object?>`.* The
     unknown-value cascade ("drop the parent that needs it") is easy to get
     wrong without a typed middle step.
3. **Recognising CXF.** A JSON object with `version.major`, `exporterRpId`
   and an `accounts` array is CXF. `detectFile` checks for it before the
   Bitwarden JSON check, since neither format's keys appear in the other.
   `ImportSource.cxf` joins the enum, and the sheet names the source after
   the header's `exporterDisplayName`.
4. **Mapping details.**
   - *Logins.*
     - Every `scope.urls` entry goes into `uris` with the default rule
       (`match: null`), and `websites` follows from the reconciliation in
       `docs/plans/add-cards-identities-and-websites.md`.
     - `scope.androidApps` aren't kept. Kemlock matches an app by what was
       picked in it, and a package name without its certificate would be a
       trap (CXF makes the certificate optional).
     - `source` is `exporterDisplayName`. `creationAt` and `modifiedAt`
       become `addedAt` and `passwordChangedAt`, or the import time when
       absent, as the format advises.
   - *Several credentials in one item.* CXF lets an importer split an item.
     One `basic-auth` and one `totp` make a login linked to its code
     (`accountId`), and two `basic-auth` make two logins. Passkeys stay
     separate passkeys.
   - *Passkeys.*
     - The PKCS#8 `AlgorithmIdentifier` decides. `id-ecPublicKey` with
       `prime256v1` is ES256, and is kept. Ed25519, RSA and P-384 are
       skipped as "passkey type Kemlock can't use yet".
     - The credential id and user handle are decoded from base64url and
       stored as the model stores them.
     - A passkey with `fido2Extensions` is kept, but its `hmacCredentials`,
       `credBlob` and `largeBlob` aren't, because Kemlock's authenticator
       doesn't serve them. The summary says so for each.
   - *Identities.* An item's `person-name`, `address`,
     `identity-document`, `passport` and `drivers-license` credentials
     merge into one identity:
     - the name parts;
     - one address, the first, with any others going to the note;
     - one document for each document credential, typed passport,
       driver's licence or ID card.

     Country codes stay ISO 3166.
   - *Cards.* `expiryDate` and `validFrom` are `year-month` (`YYYY-MM`),
     stored as month and year. `cardType` becomes the brand, as given.
   - *Custom fields* add `label: value` lines to the note of what the item
     became. A concealed field is added too, since it is the person's data,
     but marked "(secret)" so they can move it.
   - *Tags* come from collections, with the path joined by " / ", and from
     the item's `tags`. They are deduplicated and capped as `_tags` caps
     them today.
5. **Duplicates through the shared rules.** The preview calls the rule
   module from `docs/plans/add-duplicate-cleaner.md` (its tasks group 1, a
   hard prerequisite of task 3.2 here), so import and the cleaner can't
   disagree:
   - a login matches on its id, or on the same site, username and
     password; one that shares only site and username is imported, and
     the cleaner shows the pair;
   - a code on its secret;
   - a passkey on relying party and credential id;
   - a card on its digits and expiry.

   No matcher of this plan's own goes into `import_merge.dart`. Replacing a
   login keeps the old password in `previousPasswords`, as sync's merge
   does.
6. **Destinations, account by account.** Each `CxfAccount` is one row of
   the preview's "Into" choice: this vault, or a new space. Spaces are
   WebDAV spaces today, and server spaces after
   `docs/plans/add-server-spaces.md`.
   - A collection carrying the `shared` extension, with any accessor other
     than the owner, gets a new space named after it preselected.
   - An item lands where its first collection lands, or else where its
     account lands.
   - Where spaces aren't available, the vault is the only choice, and the
     preview says why.
7. **iOS: keep the token, open the vault, then fetch.**
   - `SceneDelegate` gets the activity: on a cold start in
     `scene(_:willConnectTo:)`, on a warm one in `scene(_:continue:)`. It
     gives the UUID to Dart through `CredentialExchangeChannel`.
   - Dart routes to the import flow, which asks which vault (if there are
     several) and for its unlock. Only then does Dart call back for
     `importCredentials(token:)`. The JSON comes back over the channel,
     never through a file.
   - Runner keeps iOS 15.5 as its deployment target, with this code behind
     `if #available(iOS 26, *)`. The extension's two keys go into its
     `Info.plist`, and `NSUserActivityTypes` with
     `ASCredentialExchangeActivityType` goes into Runner's.
   - *Rejected: fetching at once and holding the data until unlock.* The
     plain payload would sit in memory while the vault is locked, and a
     lock promises that nothing readable is left.
   - *Fallback,* if task 4.4 shows the token expires before a slow unlock:
     fetch at once, into memory only, keep it at most 5 minutes, and drop
     it on any lock.
8. **Android: a plugin that only the store build pulls in.**
   - A new Flutter plugin package, `packages/credential_transfer`, holds a
     small Kotlin class over `ProviderEventsManager`, and the two
     `providerevents` 1.0.0 dependencies.
   - `packages/parts_store` depends on it, and implements a new
     `CredentialTransfer` port in `kemlock_ports`:
     `Future<String?> importCredentials(Set<String> types)`, which returns
     null when the person cancels.
   - `parts_free` implements the port by throwing `NotInThisBuild`. The
     free APK then holds no Play services class, and add-fdroid-release's
     check passes unchanged.
   - The request asks for `basic-auth`, `passkey`, `totp`, `note`,
     `credit-card`, `address`, `person-name`, `identity-document`,
     `passport`, `drivers-license`, `ssh-key` and `custom-fields`, and for
     the `shared` extension (`person-name` and `passport` are added to the
     first list, since the identity mapping keeps them). It doesn't ask for
     types Kemlock can't keep, so the exporter sends less.
   - After `importCredentials` returns, the Kotlin side deletes the
     transfer's cache file if the library left it (task 5.3).
     `platform/scratch.dart`'s sweep also covers the library's directory,
     so a killed import is cleaned at the next start or lock.
   - The row shows only on API 26 and later, and only when the store build
     reports the API available. If
     `ImportCredentialsProviderConfigurationException` says the phone can't
     do it, for want of Play services or with an old one, the sheet says
     so.
   - *Rejected: a Gradle flavour in the app module.* The free build is
     chosen by Dart dependency overrides, not by flavours, and the app
     module can't take a dependency that only one build has.
   - *To check: the bare `providerevents` library in the free build*
     (owner decision 3, task 5.5).
9. **Limits.**
   - `formats/limits.dart` gives the 32 MiB payload limit, checked on the
     string's length before `jsonDecode`, and the 10,000-item limit.
   - This plan adds 32 credentials an item, 64 URLs a scope, collections
     nested at most 8 deep (read without recursion), 4,096 characters a
     field and 64 KiB a note.
   - A passkey key over 2 KiB and an SSH key over 16 KiB are skipped.

   These keep one item from dwarfing the rest, as a37170d8 kept one QR from
   doing so.
10. **Licence and provenance.**
    - The app never ports, translates or copies Bitwarden's importer code
      (GPL-3.0), and never links the server's `kemlock-import` (AGPL-3.0).
    - The reader is written from the CXF specification and from Apple's and
      Google's documentation. Bitwarden's open-source code may be read for
      facts, such as field names and what an exporter really sends, as the
      server design does, and each parser task names its sources.
    - CXF fixtures come from the specification's own example, which the
      FIDO Alliance publishes for implementers, and from exports made with
      test accounts on test devices.
11. **Export: one writer, the same mapping in reverse, behind an owner
    check.**
    - `formats/cxf_writer.dart`, pure Dart, writes the vault's items as a
      CXF 1.0 header: logins with their `uris` as scope URLs, linked codes
      as `totp` in the login's item, ES256 passkeys, notes, cards,
      identities and SSH keys. Collections are made from tags. Kinds CXF
      has no type for (backup codes, PGP keys, contacts) are left out and
      listed on the export sheet.
    - A round trip through the reader gives back the same entries, which
      the tests hold.
    - **iOS 26:** the app offers "Export to another app" and hands the JSON
      to `ASCredentialExportManager`, decoded into Apple's types in Swift
      with the same re-encoding the import uses.
    - **Android, store build:** the app registers as an export source with
      `ProviderEventsManager.registerExport` (an `ExportEntry` per vault,
      naming no secret), and answers the importer's request in an exported
      activity. That activity checks the calling package and the request's
      nonce, opens nothing until the person picks Kemlock and unlocks, and
      returns only what the person chose. The free build has no export
      hand-off, as it has no import one.
    - **Every export asks first,** as the audit ruled: the owner check runs
      before any secret is read, whatever "Ask before showing a secret"
      says, and the sheet names the receiving app.
    - **A space's "no export" policy** (`docs/plans/add-server-spaces.md`)
      leaves that space's items out, and the sheet says so.
    - Nothing plain is written to disk: the JSON lives in memory, and
      Android's transfer file is the library's, deleted after the answer
      and swept on lock.

### Risks

- *Kemlock may not be listed as a destination on iOS.* A search result for
  an Apple developer forum thread
  (https://developer.apple.com/forums/thread/819382) reports a manager with
  both keys that never appears in Passwords' list. The page refused
  automated access, so this is unconfirmed. Mitigation: test on an iPhone
  with iOS 26 first (task 4.5). If Kemlock doesn't appear, check Apple's
  entitlement and App Store requirements before building the rest of iOS.
- *Android's library is beta, and its guide lags its releases.* Pin
  1.0.0-beta01 behind the port, and move to 1.0.0 stable in a `chore(deps)`
  commit when it ships.
- *Apple's re-encoded JSON may differ from raw CXF*, in the types it
  doesn't model, field casing or dates. Fixtures of real iOS hand-offs
  (task 7.2) catch this, and the reader ignores what it doesn't know.
- *Passkeys moved with their private keys are only as safe as the
  hand-off.* The OS brokers it on one phone, Kemlock never writes the
  payload to disk, and a payload that fails part-way saves nothing.
- *Ed25519 and other passkeys don't come across.* Each is listed by name,
  so the person keeps it in the old app until Kemlock supports it.
- *Large imports on old phones.* The limits apply, and items are saved in
  batches, as the vault controller already saves.
- *Files don't come across.* Each is listed with its item, with the advice
  to export the file by hand.

### Rollout

Nothing migrates. The vault gains entries through its existing lists and
the new card and identity kinds, and no stored format changes. Rolling back
means removing the rows: anything already imported stays as ordinary
entries.

### Open questions

1. Does `providerevents` alone, without `-play-services`, bring any
   `com.google.android.gms` class? Does it do anything on a phone without
   Play services? The answer changes only which package the plugin sits in
   (task 5.5).
2. How long does an iOS import token stay valid? The answer picks decision
   7 or its fallback (task 4.4); the flow is the same either way.
3. Which credential types does each real exporter send today? Collected
   with the fixtures of task 7.2.

## Behaviour

### Reading the format

**Only CXF major version 1 is read.** A payload with `version.major` 1 is
read, whatever its minor version. Any other major version, or a payload
without a version, is refused before any account is read, and the refusal
names the version found.

- A payload with version 1.3 holding `basic-auth` → the login is read as it
  would be from 1.0.
- A payload with version 2.0 → nothing is read, and the import says "This
  export uses Credential Exchange version 2.0, which this version of Kemlock
  can't read."

**Unknown values are passed over, as the format says.** Unknown fields are
ignored. An unknown value in an optional field counts as absent. A
structure whose required field holds an unknown value is left out, and so
is a parent that needs that structure. A credential of an unknown type is
skipped and listed.

- An item with a field `"color": "blue"` → read as if the field weren't
  there.
- A `totp` credential with `"algorithm": "sha3-256"` → the code is skipped
  as "algorithm Kemlock can't generate", and the item's login is still
  imported.
- A credential of type `"loyalty-card"` → listed with its item's title as
  "a kind of item Kemlock doesn't have", and the item's other credentials
  are imported.

**Limits are checked before the work they bound.**

| Limit | What happens over it |
| --- | --- |
| 32 MiB payload | Refused before parsing |
| 10,000 items | Only the first 10,000 are offered |
| 32 credentials an item | The rest are skipped |
| 64 URLs a scope | The rest are dropped |
| Collections 8 deep | Deeper collections give no tags |

The preview always says what was cut.

- 40 MiB of JSON → nothing is parsed, and the import says the export is
  larger than Kemlock reads.
- 12,000 items → the preview offers 10,000 and says 2,000 were left out
  because of the limit.
- Collections nested 500 deep → reading stops at depth 8 without running
  out of stack.

**A password credential becomes a login.** A `basic-auth` credential
becomes a login named after its item's title, with its username and
password. Every URL of the item's scope becomes a website with the default
rule, in order, and the login's source is the exporter's name.

- "Larkspur Mail", with three scope URLs → one login with the three
  addresses as websites.
- Two `basic-auth` credentials in one item → two logins, each with the
  item's websites.

**A code becomes a code entry, linked to its login.** A `totp` credential
becomes a code entry with its secret, period, digits, algorithm, issuer and
username. When the same item holds a `basic-auth` credential, the login is
linked to the code. A code Kemlock can't generate is skipped and listed.

- "GitHub" with `basic-auth` and `totp` → a code entry and a login, the
  login linked to that code.
- A `totp` credential without an issuer, in an item titled "Fastmail" → a
  code entry with the issuer "Fastmail".
- A secret that isn't Base32 → skipped as "unreadable secret".

**An ES256 passkey becomes a passkey.** A passkey whose private key is a
P-256 key in PKCS#8 is kept, with its credential id, relying party, user
handle, user name and display name exactly as given. Any other algorithm,
or a missing or undecodable field, is skipped and listed.

- A P-256 passkey for larkspur.example → the passkey signs a test challenge
  that verifies under its public key.
- An Ed25519 passkey → skipped as "passkey type Kemlock can't use yet".
- A P-256 passkey with `hmacCredentials` → imported, and the summary says
  that sites that used its extra secret (PRF) may ask the person to set it
  up again.

**Notes, cards, identities and SSH keys become their own kinds.**

- "Visa" with a number, cardholder, expiry "2029-04", security code and PIN
  → a card expiring April 2029.
- `person-name`, `address` and `passport` in one item → one identity with
  the name parts, the address and one passport document.
- An `ssh-key` of type "ssh-ed25519" → an SSH key, its public half derived
  from the private key.
- `custom-fields` holding "Account number: 12345" on a login's item → the
  login's note ends with that line.

**What can't be kept is skipped and named.** `file`, `wifi`, `api-key`,
`generated-password` and `item-reference` credentials are skipped, and so
are items left with nothing Kemlock keeps. Each is listed with its item's
title and a reason the person can act on.

- A `file` named "passport-scan.pdf" → "files don't come across in this
  kind of transfer; export it from the other app by hand".
- An item holding only `wifi` → listed, and nothing is made for it.

**Collections become tags.** An item linked from "Banking" inside
"Finance", with its own tag "personal", gets the tags "Finance / Banking"
and "personal".

**No imported value is logged.** A payload's values stay in memory only
while it is read and previewed. They are never logged or put in error text,
and they are written only to the vault's sealed storage.

- A payload malformed part-way through an item → the error names the item's
  position and the problem, and none of its secrets.

### Receiving an export

**On iOS 26 and later, Kemlock is an export destination.** Choosing Kemlock
in another app's export opens it on an import screen that names that app.
On earlier versions of iOS nothing changes.

- Exporting from Passwords and picking Kemlock → "Import from Passwords",
  ready for the vault to open.
- On iOS 18 → no Credential Exchange row, and Kemlock is offered nowhere as
  a destination.

**On iOS, the Import sheet says where an export starts.** iOS gives Kemlock
no way to start a transfer itself. A row, "From another app on this
iPhone", says that the transfer starts in the other app's export, and gives
the steps for Passwords.

**On Android, Kemlock asks another app for its export.** In the store
build, on Android 8 and later, "From another app on this phone" opens the
system's list of apps that can export. It asks only for the kinds Kemlock
keeps.

- Picking Google Password Manager and confirming there → the preview of
  what Google handed over.
- No app can export → Kemlock says so, and suggests a file export.
- The person closes the list → back to the Import sheet, with no error.

**The free build has no system transfer.** It has no row for it. The help
says that the transfer needs Google Play services, and that a Credential
Exchange file can be chosen like any other export.

**A CXF file opens like any other export.** It is recognised from its
content in every build. Picking `export.json` holding a CXF 1.0 header with
40 items → "Credential Exchange file from <exporter>", and its preview.

**The vault opens before anything is read.** A transfer that arrives while
the vault is locked asks for its unlock first.

- If unlocking is abandoned, nothing is read and the transfer ends.
- With two vaults on the phone, Kemlock first asks which vault to import
  into.

### The preview

**The preview shows what comes and what doesn't.** Before saving, it
counts what will be added of each kind, shows the matches with the vault,
and lists every skipped credential with its reason. Nothing is saved until
the person confirms.

- A transfer of 120 logins, 14 codes, 9 passkeys (2 of them Ed25519), 3
  cards and a Wi-Fi network → 120 logins, 14 codes, 7 passkeys and 3 cards
  to add, and 3 entries skipped, with their names and reasons.
- Leaving the preview without confirming → the vault is unchanged.

**Duplicates follow the vault's one rule set.** For each group of matches,
the person chooses skip, keep both or replace.

- A login for larkspur.example with the username "ada" and the same
  password, already in the vault → shown as a match, with skip selected.
- The same login with another password → imported, and the cleaner later
  shows the two as the same account with two passwords.
- Replace → the vault's login takes the imported password, and its old
  password goes into its previous passwords.
- A code "Google" with the same secret as the vault's "Gmail" → shown as a
  match.

**Each exported account goes where the person chooses.** The vault is
preselected for the first account. A collection shared with others in the
old app gets a new space preselected.

- Accounts "Personal" and "Family", where "Family" has a shared collection
  → the vault for "Personal", and a new space "Family" for the shared
  collection. Both choices can be changed.

### What's left afterwards

**No plain copy outlives the import.** Any file the transfer wrote is
deleted as soon as it is read, and swept when the vault locks and when the
app starts.

- An import that finishes or is cancelled on Android → no file holding the
  transferred data remains in Kemlock's cache or files.
- Kemlock killed during the preview → the next start sweeps what the
  transfer left, and nothing was added to the vault.

**The other app learns nothing more of the vault.** Kemlock's Android
request names only the credential types and the `shared` extension it
reads. Kemlock answers no transfer that no person started.

### Exporting to another app

**Export is offered only after its review.** Until task 8.6's security
review passes, the export rows don't show in any build.

**Every export asks first.** The owner check runs before anything is read,
and the sheet names the app receiving the items and what goes.

- Exporting the vault to 1Password on Android → the sheet says "Send 120
  logins, 14 codes, 7 passkeys and 3 cards to 1Password", and nothing is
  read until biometrics pass.
- The person cancels the check → nothing is sent, and the other app gets a
  cancel.

**Only what the person picked goes, and only to the app that asked.**

- An Android request whose caller isn't the package the system named, or
  whose nonce doesn't match → refused, and nothing is read.
- A space whose policy forbids export → its items are left out, and the
  sheet names the space.

**What goes comes back the same.** An export read back by Kemlock's own
reader gives the same entries.

- Backup codes, PGP keys and contacts → listed as "not part of Credential
  Exchange", and left out.

**On iOS 26, export starts in Kemlock.** "Export to another app" opens the
system's sheet of importers. On earlier versions there is no row.

## Tasks

Each task names the test or check that proves it. Coding agents don't run
builds, tests, CI or `pub get`: each "Verify" is run in the single
build-and-test pass after merging, by the main session, or on a device by
the owner.

### 1. The format reader (Dart)

- [x] 1.1 Write `lib/features/import/formats/cxf.dart`'s records and parser:
  the version rule, unknown fields and values with their cascade, required
  arrays, and the limits of design decision 9, read without recursion.
  Sources: the CXF 1.0 Proposed Standard and its errata only. Verify with
  `test/features/import/cxf_reader_test.dart`, which runs every case in
  `fixtures/import/cxf/cases.json` (task 2.2).
- [x] 1.2 Map the records to a `ForeignImport` as design decision 4 says,
  skipped credentials becoming `skippedEntries` with their reasons.
  Sources: the same, plus `docs/plans/add-cards-identities-and-websites.md`
  for the card and identity fields. Verify with a mapping test per
  credential type over `fido-example.json`, which checks each mapped field.
- [x] 1.3 Read a passkey's PKCS#8 `AlgorithmIdentifier`: keep P-256, skip
  every other algorithm, and drop the FIDO2 extensions with a note. Verify
  that an imported P-256 fixture key signs a challenge that verifies under
  its public key, and that Ed25519, RSA and P-384 keys are skipped as their
  cases say.
- [x] 1.4 Derive an SSH key's public half from its PKCS#8 private key, for
  Ed25519, ECDSA P-256 and RSA, with the code the key import already uses.
  Verify that each case's public key equals the one `ssh-keygen -y` printed
  for the same key, recorded in the case.
- [x] 1.5 Recognise CXF in `detectFile`, before Bitwarden JSON, and add
  `ImportSource.cxf`. Verify that `fido-example.json` is recognised as CXF,
  and that `importers_cases_test.dart` and the Bitwarden fixtures still
  pass unchanged.

### 2. Fixtures

- [x] 2.1 Add `mobile/test/fixtures/import/cxf/fido-example.json`, Appendix
  A of the 9 March 2026 errata byte for byte, with a `README.md` naming its
  source, its date and what it holds: one credential of each of 15 types,
  one nested collection. Verify that the test reads it and finds 15
  credential types.
- [x] 2.2 Add `cases.json`, cases written from the example, each with its
  expected result. They cover version 1.3 and 2.0, a missing version,
  unknown fields, an unknown enum in an optional and in a required field,
  an unknown type, each limit, 500-deep collections, a malformed payload,
  and two `basic-auth` in one item. Verify that each case passes in 1.1's
  test.

### 3. The preview and merge (Dart)

- [x] 3.1 Give `ForeignImport` and `ImportPreview` logins, cards,
  identities, keys and per-account destinations, keeping `skipped` as a
  count. Verify that the existing importer and import-sheet tests pass
  unchanged.
- [x] 3.2 After `docs/plans/add-duplicate-cleaner.md`'s tasks group 1 has
  landed (a hard prerequisite), call its `duplicate_rules.dart` for logins
  (site, username and password), codes by secret, passkeys by relying party
  and credential id, and cards. Then add skip, keep both and replace.
  Verify with tests: a login replaced keeps its old password first under
  previous passwords; a login with the same site and username but another
  password is imported, not matched; "Google" and "Gmail" with one secret
  match; keep both adds a second copy.
- [x] 3.3 Choose a destination per account, with the shared-collection
  preselection and the case where spaces' gate keeps a space from being
  offered. Verify with tests over a
  two-account case.
- [x] 3.4 Build the import flow, `lib/features/import/credential_exchange.dart`:
  choose the vault when there are several, unlock first, fetch after
  unlocking, then the preview. Add the Import sheet's rows for iOS, Android
  and the free build. Verify with widget tests using a fake
  `CredentialTransfer` and a fake iOS channel: nothing is fetched before
  unlock; an abandoned unlock fetches nothing; a cancel shows no error; the
  free build shows the help and no row.
- [x] 3.5 Add the strings in English and French to `messages.dart`. Verify
  with the i18n tests, which find every key in both languages.

### 4. iOS

- [x] 4.1 Add `SupportsCredentialExchange` and
  `SupportedCredentialExchangeVersions ["1.0"]` to
  `ios/AutoFill/Info.plist`, and `NSUserActivityTypes` with
  `ASCredentialExchangeActivityType` to `ios/Runner/Info.plist`. Verify
  in the single pass after merging that the iOS build passes on CI's macOS
  job, since this laptop has no Xcode.
- [x] 4.2 Take the activity in `SceneDelegate` (cold and warm starts), and
  add `CredentialExchangeChannel.swift`: the token goes to Dart, and the
  import runs on Dart's call, behind `#available(iOS 26, *)`, encoding the
  result as CXF JSON. Verify with an XCTest that decodes `fido-example.json`
  into `ASExportedCredentialData`, encodes it back, and gives JSON that the
  Dart reader reads to the same entries (compared through a recorded
  expectation file).
- [ ] 4.3 On an iPhone with iOS 26, check that re-encoding keeps every type
  that Passwords sends. Record the result in this plan's Design section.
- [ ] 4.4 On the same phone, measure how long a token stays valid while the
  unlock screen waits. Keep design decision 7, or switch to its fallback,
  and record which.
- [ ] 4.5 Do this first among the iOS tasks: check on an iPhone with iOS 26
  that Kemlock is listed in Passwords' "Export data to another app" once
  4.1 is built. If it isn't, stop the iOS tasks and bring Apple's
  requirements to the owner.

### 5. Android

- [x] 5.1 Add the plugin package `packages/credential_transfer`, its Kotlin
  over `ProviderEventsManager`, and
  `androidx.credentials.providerevents:providerevents` and
  `providerevents-play-services` 1.0.0-beta01. Add it as a dependency of
  `parts_store` only, in the same commit as the lockfiles. Verify in the
  single pass after merging that the store build compiles, and that the
  free build's APK check finds no `com.google.android.gms` class.
- [x] 5.2 Add the `CredentialTransfer` port to `kemlock_ports`, with the
  store implementation, and a free one that throws `NotInThisBuild`. Verify
  with Dart tests of both, and that `parts_free`'s tests pass.
- [ ] 5.3 Delete the transfer's cache file after reading it, and add the
  library's directory to `platform/scratch.dart`'s sweep. Verify with a
  unit test of the sweep's paths. On a phone, check that no transfer file
  remains after an import, after a cancel, or after the app is killed and
  started again, and record which directory the library used. (Code done;
  verify on a device. The library's `import_export_filepaths.xml` names
  `<cache>/import_export_temp/`, which the plugin deletes and the sweep
  takes; the phone is to confirm that no other file is left.)
- [x] 5.4 Map the library's exceptions (cancel, no export option, provider
  configuration, invalid JSON, system, unknown caller) to the sheet's
  messages. Verify with Kotlin unit tests of the mapping, and Dart tests
  with the fake port.
- [ ] 5.5 In the single pass after merging, the main session reads the free
  build's Gradle dependency report with the bare `providerevents` library
  added on a local scratch branch, and records in Open questions whether
  it brings Play services classes. Verify by the report itself; nothing
  ships from this task.

### 6. Design and documentation

- [ ] 6.1 Add an app page to the design canvas: the Import sheet's
  Credential Exchange rows on iOS, Android and the free build, and the
  preview with destinations and skipped entries. Verify by the owner's look.
- [x] 6.2 Add a Credential Exchange section to the README: what comes
  across, what is skipped, that files don't come across, the platform
  minimums, and the free build. Verify that every skipped type in the
  Behaviour section is named there.
  (The README's "Credential Exchange" section, under Features, names every skipped type of Behaviour's "What can't be kept is skipped and named" (`file`, `wifi`, `api-key`, `generated-password`, `item-reference`, unknown types) and the other skips (a passkey that is not ES256, a code Kemlock can't generate, an item left with nothing), the platform minimums (iOS 26, Android 8), the store-build-only hand-off and the free build's file, the limits, what goes out with export switched off until task 8.6 and the device checks, and the cache file's deletion and sweep, and lists the device checks still pending: 7.1 to 7.3 and 8.7.)

### 7. On devices

- [ ] 7.1 On an Android 14 phone with Play services, import with test
  accounts from Google Password Manager, 1Password, Bitwarden and Dashlane.
  Then check a phone without Play services, or the free build. Record what
  passed in this plan.
- [ ] 7.2 Collect real hand-offs made with test accounts, never anyone's
  own data. Sources: Apple Passwords on iOS 26, and Google, 1Password,
  Bitwarden and Dashlane on Android. Each goes into
  `mobile/test/fixtures/import/cxf/<app>/`, with a `README.md` giving the
  app, its version, the platform, the date and what was set up. Verify
  that a test reads each one into the expected entries.
- [ ] 7.3 On an iPhone with iOS 26: import from Passwords into a locked
  vault, into one of two vaults, and with the unlock abandoned. Record what
  passed in this plan.

### 8. Export (after groups 1 to 7; owner decision 1)

- [x] 8.1 Write `formats/cxf_writer.dart` (design decision 11): every kind
  CXF carries, collections from tags, and the left-out kinds listed.
  Sources: the CXF 1.0 Proposed Standard and its errata only. Verify with a
  round-trip test: a vault with one of each kind, written and read back by
  1.1's reader, gives the same entries; and the output reads as valid
  against every structural rule `cases.json` checks. (The round trip and
  the reader's reading the output with no skip or cut are tested; running
  the output through each structural case of `cases.json` is not yet.)
- [x] 8.2 Add the export sheet: the vault or a space, the kinds, the
  left-out list, the receiving app's name, the owner check before anything
  is read, and a space's "no export" policy. Keep it behind a build-time
  switch, off, until task 8.6 passes. Verify with widget tests: cancelling
  the owner check reads nothing; a forbidden space is left out and named;
  the switch off shows no row. (Built as `credential_export_sheet.dart`,
  with `credentialExportBuilt`, the build-time switch, off unless built with
  `--dart-define=KEMLOCK_CREDENTIAL_EXPORT=true`. The sheet exports the open
  vault: spaces have no "no export" rule yet, so `blockedExportSpacesProvider`
  is empty until add-server-spaces 7.4 fills it, and a blocked space's items
  are left out and the space named. The sheet lists what Credential Exchange
  has no type for before the owner check, from kinds alone, never from
  a secret.)
- [x] 8.3 iOS 26: hand the JSON to `ASCredentialExportManager` through
  `CredentialExchangeChannel.swift`, decoded into Apple's types. Verify
  with an XCTest that the decoded data re-encodes to the same JSON, run in
  the single pass after merging on CI's macOS job. (The channel's `export`
  call opens the system's sheet with `requestExport(for: nil)`, decodes the
  payload at the version it answers, and gives it to `exportCredentials`; the
  person closing the sheet is `cancelled`. The names `requestExport(for:)`,
  `ExportOptions.formatVersion` and `ASAuthorizationError.canceled` as the
  cancel are from Apple's pages and unconfirmed on a build.)
- [x] 8.4 Android store build: `registerExport` with an `ExportEntry` per
  vault naming no secret, and the exported activity that checks the caller
  package and nonce, waits for the person's pick and unlock, and answers
  only what was chosen. Verify with Kotlin unit tests of the caller and
  nonce checks (a wrong package and a wrong nonce are refused before any
  Dart call) and Dart tests with a fake port. (Built in three parts: the
  plugin's `ExportActivity`, `ExportCheck` and `ExportNonces`, with the
  secret ids made and kept hashed in Kotlin so Dart never sees one; the app's
  `ExportRequestActivity`, the screen on the shared engine, started for a
  result by the exported activity; and Dart's `CredentialExport` port, its
  fakes and `android_export.dart`. The entry names the vault and the
  credential types Kemlock writes. The exported component is also disabled by
  the plugin's `credential_export_enabled` resource, which flips with the Dart
  switch of 8.2. The library's names are from the Android reference pages for
  1.0.0-beta01 and unconfirmed on a build.)
- [ ] 8.5 Delete the export's transfer file after answering, and cover it in
  the sweep. Verify with the sweep's path test; on a phone, the owner checks
  that no file remains after an export, a cancel and a kill. (Code done;
  verify on a device. The export's data goes through the importer's own cache
  file, which Kemlock can't delete; what the library leaves of it in
  Kemlock's `import_export_temp` is deleted by the exported activity when it
  ends, answered or cancelled, unless an import of Kemlock's own is running,
  and the sweep at start and lock covers the folder as it did for imports.)
- [ ] 8.6 Security review of the export path, by a review agent on Opus
  separate from the builders, over the activity, the caller and nonce
  checks, the owner check, the policy and the transfer file. Record its
  findings and their fixes in this plan. Turn the switch of 8.2 on only
  when every finding is fixed or the owner accepts it.
  Not done: the review has not run, and the switch stays off. Both halves of
  it flip together, and only when this task passes: Dart's
  `credentialExportBuilt` (`--dart-define=KEMLOCK_CREDENTIAL_EXPORT=true`) and
  the plugin's `credential_export_enabled` resource, which decides whether the
  exported activity exists at all. Switching export off again after a release
  that had it on needs `clearExports` called once (nothing calls it while the
  switch is off), or the selector keeps listing Kemlock.

  What the review must look at, from the builders' notes:
  - **The exported Android activity** (`ExportActivity`). It is exported, so
    any app can start it. Check: that `getCallingPackage()` equal to
    `com.google.android.gms` is enough (the selector is Play services' alone,
    so a phone without it can't export, which the sheet doesn't say); that
    `requireContentUriPermissionFromCaller` only applies from Android 15 (API 35; see the review notes), and
    what stops a forged start before that beyond the hashed secret id; that
    the activity reuses the incoming intent for its result; what happens on
    process death, a second request, and a request left waiting (the Dart
    timer is five minutes, the Kotlin side has none); and that `FLAG_SECURE`
    and the obscured-touch refusal on `ExportRequestActivity` cover the screen
    that shows what will go.
  - **Who may receive the export.** Kemlock names the app by its label from
    `PackageManager` for the package the system gives as the importer, and has
    no allowlist: a look-alike label is the person's to catch. iOS names no
    app before the data is handed over, because Apple tells the exporter only
    the format version. Decide whether an allowlist, or the package name next
    to the label, is wanted; and whether a request for a vault other than the
    open one is refused cleanly (the sheet does, the vault stays locked).
  - **What leaves the phone.** Every secret of the kinds picked, in the
    clear: passwords, codes, passkeys' and SSH keys' private keys, card
    numbers and codes. Check: a login's note and linked code ride in its item
    even when the importer didn't ask for `note` or `totp` (only whole kinds
    are filtered); the writer's ids (`kemlock`, item UUIDs, `collection-0`)
    are plain strings where CXF's identifiers are base64url, which Apple's
    types read as bytes, so check on a device that they survive (task 8.7);
    the vault's name is given to Play services as the entry's account name;
    the JSON and the Kotlin and Swift copies of it are strings that can't be
    wiped, and the Dart one is dropped, not zeroed; nothing is logged, and
    errors carry codes only.
  - **What the caches hold afterwards.** Android: `import_export_temp` (the
    library's, if it leaves anything on Kemlock's side; the importer's copy is
    its own), the hashed secret ids in the app's preferences (`allowBackup` is
    on, so they may be restored with nothing registered, which is harmless),
    and the engine's memory. iOS: Apple says nothing is written to disk. Check
    the sweep at lock and start covers each, and task 8.5's phone check.
  - And the owner check: that every path to `send` goes through it (the sheet
    does, before `writeCxf`), and that a space's "no export" rule is the
    chain's, once add-server-spaces 7.4 fills `blockedExportSpacesProvider`.

  **Review notes (the security review of November 2026, and what fixed each
  finding).** The review's findings are fixed on `build/cxf-export-hardening`;
  the switch stays off until the main session has built and run the tests and
  the owner has passed 8.7. Nothing here was built or run where it was
  written.
  - **M1** The sheet sent the plan it drew in `build`, after an owner check
    that can take as long as the person likes. `_send` now reads the vault, the
    hidden passwords and the blocked spaces again once the check passes,
    refuses a vault that is locked or is not the one the target named, and
    sends only that, cut to the kinds the person saw (eb01db90). On iOS it
    runs after the system's sheet, as the payload is made then (f4d9deb0).
  - **L5** `_busy` is set before the owner check, so two quick taps start one
    check and one export (32c111eb).
  - **M2** `blockedExportSpacesProvider` is still empty, to be filled by
    add-server-spaces 7.4, but every item of a shared server space is now left
    out until that policy exists (the owner's decision): an item with a space
    id that is not a WebDAV space of the vault's settings, or any id while the
    settings are not read. The sheet says how many are not included
    (c049a55f). 7.4 replaces this rule with the space's policy.
  - **M3** The caller must be `com.google.android.gms` and a system app
    (`FLAG_SYSTEM` or `FLAG_UPDATED_SYSTEM_APP`), so an app that took the name
    on a phone without Play services is refused (eb2439f9). The plugin's
    manifest names the package in `<queries>` for Android 11's package
    visibility.
  - **L1** The caller is checked before the intent is parsed, and the parse and
    the reads of its result are in a try/catch that refuses (956769f3).
  - **L2** A request whose URI is not a `content` URI, or whose authority is
    one of Kemlock's own providers, is refused (e1a07354).
    `requireContentUriPermissionFromCaller` is API 35 (Android 15), as the
    reviewer thought: it is absent from the android-34 platform's attributes
    and present in android-35's. The manifest's `tools:targetApi` said 34 and
    the comment said Android 14; both now say 35. Before Android 15 the system
    does not check the caller's right to write the URI at all, so the
    activity's own checks (system selector, secret id, own-provider refusal)
    are all there is. 8.7 should include an Android 15 phone as well as 14.
  - **L3** The sheet shows the receiving app's package name under its label
    (08b64005). An allowlist is not added: the package name next to the label
    is what the person can check.
  - **L4** A kind is offered only when its main type was asked (an identity's
    is `person-name`), and the writer drops every credential of a type the
    importer did not ask for, so a login's note and linked code, and the
    notes of the other kinds, go only to an app that asked for them
    (6df548fa).
  - **L6** iOS: Swift opens the system's sheet first and asks Dart for the
    JSON (`exportJson`) only after the person goes on (f4d9deb0). Android: a
    request's five minutes now run on while the sheet holds it, and stop when
    it sends or cancels (8310dfc7).
  - **L7** `import_export_temp` is deleted in `onDestroy` too (a78de509). The
    plugin's `credential_export_enabled` resource is made by its
    `build.gradle.kts` from the `KEMLOCK_CREDENTIAL_EXPORT` define that the Dart
    switch reads (9489d7fd), so turning export on is the one define; the XML
    file is gone. While export is off, the app asks once to clear the lists if
    any entry is registered (12606e37).
  - **L8** Each vault's own id is the account id (5cea7c0e), and a passkey
    whose algorithm is not ES256 is left out and listed (ce72452c).
  - **S1** The encoding of a TOTP secret in the iOS hand-off (what Apple's
    types carry for a one-time-code secret, and whether the reader and the
    writer agree on it) is not confirmed. Left for a device check in 8.7; do
    not turn export on for iOS before it.
  - Not fixed here, for the owner to accept or schedule: the JSON and the
    Kotlin and Swift copies of it are strings that can't be wiped; the
    hashed ids in the app's preferences come back with a restored backup (and
    are harmless); an allowlist of receiving apps.
- [ ] 8.7 On devices: the owner exports from Kemlock to Apple Passwords on
  iOS 26, and to 1Password and Bitwarden on Android 14 and on Android 15 (where the system also checks the caller's
  right to write the URI), with test accounts, and the S1 check of the review notes.
  Record what passed in this plan.

## Sources

Opened on 21 November 2026:

- FIDO Alliance, [Credential Exchange Format 1.0, Proposed Standard, 14 August 2025](https://fidoalliance.org/specs/cx/cxf-v1.0-ps-20250814.html)
- FIDO Alliance, [CXF 1.0 errata, 9 March 2026](https://fidoalliance.org/specs/cx/cxf-v1.0-ps-errata-20260309.html)
- FIDO Alliance, [Download Credential Exchange Specifications](https://fidoalliance.org/download-credential-exchange-specifications/) (CXP still a Working Draft)
- Apple, [ASCredentialImportManager](https://developer.apple.com/documentation/authenticationservices/ascredentialimportmanager)
- Apple, [ASCredentialExportManager](https://developer.apple.com/documentation/authenticationservices/ascredentialexportmanager)
- Apple, [ASExportedCredentialData](https://developer.apple.com/documentation/authenticationservices/asexportedcredentialdata), [ASImportableAccount](https://developer.apple.com/documentation/authenticationservices/asimportableaccount), [ASImportableItem](https://developer.apple.com/documentation/authenticationservices/asimportableitem), [ASImportableCredential](https://developer.apple.com/documentation/authenticationservices/asimportablecredential)
- Android Developers, [Credential transfer](https://developer.android.com/identity/sign-in/credential-transfer)
- Android Developers, [credentials-providerevents release notes](https://developer.android.com/jetpack/androidx/releases/credentials-providerevents) (1.0.0-beta01, 9 September 2026)
- Kemlock Server design doc, [Import from other password managers, and Decisions](https://claude.ai/artifact/2NWbdYSZaFK84mnLMWvx1Y)
- Design canvas, [Import and export page](https://claude.ai/artifact/4wvdwScsMsGu6NMSj6ptPo)

Not opened (it refused automated access), and cited only as unconfirmed:
[Apple developer forum thread 819382](https://developer.apple.com/forums/thread/819382).

## Dependencies

- `docs/plans/add-cards-identities-and-websites.md`: must land first. It
  provides the card and identity kinds, and `uris` with its reconciliation
  into `websites`.
- `docs/plans/add-duplicate-cleaner.md`: the shared duplicate rules. Its
  tasks group 1 is a hard prerequisite of task 3.2 here; this plan adds no
  matcher of its own.
- `docs/plans/add-server-spaces.md`: "a new space" means a server space for
  accounts on Kemlock Server. Until then, and without the server, a WebDAV
  space. Its "no export" policy limits the export of group 8.
- `docs/plans/add-kemlock-server-sync.md`: no code dependency. Imported
  items are ordinary vault entries, which that plan's sync uploads.
- `docs/plans/add-account-crypto.md`: no code dependency. Items get their
  item keys when the server sync writes them, not at import.
- `docs/plans/move-off-vaultwarden-sync.md`: none. Cards and identities
  stay out of Vaultwarden sync, as the cards plan says.
- Earlier plans, in git history before 5ba88b42: add-code-imports
  (`detectFile`, `formats/limits.dart`, `skippedEntries`; must land
  first), add-fdroid-release (the parts split and the free build's check),
  add-passwords (logins and `previousPasswords`), and add-browser-extension
  (`kemlock_core`, where the reader moves later).
