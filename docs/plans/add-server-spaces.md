# Spaces on Kemlock Server

Kemlock Server makes a shared space a set of space-owned `kem1` items. Their keys are sealed to each
member's post-quantum exchange key, and every change to who is in the space is recorded in a chain the
members' apps sign and check. This plan covers the app side: making, joining, confirming and leaving
spaces, replacing keys when someone leaves, the policies the app respects, and moving today's WebDAV
spaces over without stranding anyone.

## Why

A shared space today is a WebDAV file under one random key that every member holds
(`backmycodes-space-<id>.json`, opened by a `bmc-space:` invite). Nobody can be removed: a former member
keeps the key. The file has no roles, no list of who is in, and no way to share only part of a space.

Kemlock Server can do all of that, but only with a client that seals and checks the keys, and a way for
today's WebDAV spaces to move over. The owner settled the design's choices on 2026-11-21. They are in the
Decisions table of the design doc "Kemlock Server: design and architecture"
(https://claude.ai/artifact/2NWbdYSZaFK84mnLMWvx1Y), under "Key exchange" and "Collections". The screens
follow the mockup "Space · Example Co" on https://claude.ai/artifact/4wvdwScsMsGu6NMSj6ptPo.

## What changes

- **Spaces on Kemlock Server**, beside WebDAV spaces, for a vault that syncs with Kemlock Server. A
  space holds space-owned `kem1` items, and each item belongs to one collection.
- **A key per collection.** A space key protects the space's names: the space, its collections and its
  groups. Each collection key protects the item keys of that collection's items. Each key is sealed
  with ML-KEM-1024 + X25519 only to the members granted it. A new space starts with one collection,
  "Everyone", so a space nobody configures works like a WebDAV space.
- **Invite, accept, confirm.** An admin invites by email and the person accepts in their app. An admin
  then confirms them by comparing their fingerprint, the 12 groups of 5 digits that every Kemlock
  fingerprint uses, read out or scanned as a QR code. Only then are keys sealed to them. Each member's
  fingerprint is under Settings › Account security.
- **A signed space chain.** Every change to members, roles, grants, policies or keys is an entry
  signed by the admin who made it and linked to the entry before. Apps seal keys only to members the
  chain shows confirmed. They refuse a chain that forks, goes back, or carries an unauthorised
  signature, so the server can't add a key or quietly undo a removal.
- **Roles and grants**: Owner, Admin and Member, and five permissions per collection grant: view, view
  with hidden passwords, edit, edit with hidden passwords, and manage. This replaces the mockup's
  Manager and Custom roles, as the design does.
- **Removing a member replaces keys.** Removing or revoking someone makes a new space key, and a new key
  for each collection they had. The new keys are sealed to the members who stay, and those collections'
  items are re-encrypted under new item keys in checked batches. The space's manifest is signed after
  the last batch.
- **A signed manifest per space.** It lists every item of the space, every collection's, so a member
  sees a withheld or rolled-back item even in a collection they can't open.
- **Home-only changes.** Members, roles, grants, policies and keys change only on the space's home
  server. While the home is unreachable those actions wait, with a message saying so, and items keep
  syncing through the replicas.
- **Policies the app respects:**
  - Require SSO, which the app passes to sign-in.
  - The account recovery notice, and enrolment once the member agrees.
  - The duplicate-matching notice. The matching itself is in the duplicate cleaner plan.
  - No export of space items, one space per member, and a minimum master password length.
- **Moving a WebDAV space.** A member on Kemlock Server can move a WebDAV space to the server. On the
  phone the space keeps its id and every entry keeps its id. On the server the space and its items
  take the UUIDs `crypto.md`'s "Legacy ids" gives for ids that aren't UUIDs. Until the space's Owner
  closes the WebDAV copy, moved members' apps bridge the WebDAV file and the server space, so members
  who haven't moved keep working. The WebDAV file, the `bmc-space:` invites and their fixtures stay
  byte for byte.
- **Nothing existing changes shape.** An item's collection is metadata of the server item, beside its
  owner, kept in the server space's scope state on the phone. It never enters the entry's JSON, so
  `_withoutPlace` in `sync_merge.dart`, the scope guard and the WebDAV space files are unchanged.

Out of scope:

- The primitives (exchange and signing keys, item keys and their AAD, the manifest): the account crypto
  plan.
- The server client, sign-in, tokens and the sync cursor: the Kemlock Server sync plan.
- Moving the personal vault: the Vaultwarden move plan.
- Duplicate matching.
- An admin opening a member's vault through account recovery. This plan only enrols the member; the
  reset itself is the web vault's.
- Organization items on the Bitwarden API, which stay under Bitwarden's RSA key.
- Groups from an identity provider, and SCIM, which are server-side work in `kemlock-server`.
- Sends.
- The fingerprint's derivation and display. They are `crypto.md`'s and the account crypto plan's
  (its design 5): SHA-512 over the account's bundle, shown as 12 groups of 5 digits and a QR code of
  the 64 bytes. This plan only shows and compares it.
- Gating: none. Server spaces are free, as WebDAV spaces are.

## Decisions for the owner

Decided by the owner on 2026-11-21: every recommendation below, as the tasks assume.

1. **How does a WebDAV space move?**
   - Bridge the WebDAV file both ways until the space's Owner closes it, and close it on its own after
     any removal or key replacement.
   - Move once and stop writing the file, as the personal vault's move does.

   Recommended: the bridge, which the tasks assume. The one-time move strands members who haven't
   moved. A personal vault doesn't have that problem, because all its phones belong to one person.
2. **How many collections can a `kem1` item be in?**
   - Exactly one.
   - Several, as in Bitwarden.

   Several means wrapping the item key once per collection, and more work on every key replacement.
   Recommended: one, which the tasks assume; an item shared by two teams goes in a collection both are
   granted.
3. **When admins turn account recovery on in a space people already belong to, what happens?**
   - Ask each member to agree or leave, and seal nothing until they agree.
   - Enrol everyone automatically after a notice.

   Recommended: ask, which the tasks assume.

## Design

### Context

- **WebDAV spaces today.** `SyncSettings.spaces` (`mobile/lib/features/sync/sync.dart`) lists `Space`s.
  Each is a `SyncTarget`: a WebDAV folder, a file name and a 32-byte key. An invite (`sealInvite` and
  `openInvite` in `sync_crypto.dart`) is the space's id, name, file and key. It is sealed under scrypt of
  a 12-letter one-time code, behind the `bmc-space:` prefix. Anyone holding the key reads and writes the
  whole file; there is no member list, role or removal. Since 3f8017e7, `isSpaceId` refuses the ids
  `personal` and `vaultwarden`.
- **Scopes in the merge.** Entries carry `spaceId`, and `sync_merge.dart` syncs one scope at a time
  (`scopeLists`, `mergeScope`, `applyScope`, `heldElsewhere`). Passkeys, on-key accounts and contacts
  never leave the vault's own scope, and logins follow their accounts. `_placeScope` lets an entry change
  scope only when the incoming copy equals it but for `spaceId` and `updatedAt`; that is the fix for
  audit finding 6. Server spaces reuse all of this: a server space is one more scope.
- **What other plans provide.**
  - The account crypto plan, following `crypto.md` in `../kemlock-server`:
    - each account's `kx1` exchange key and `sig1` signing key, published in a self-signed bundle;
    - the bundle's fingerprint and `FingerprintView`;
    - item keys under AES-256-GCM, with an AAD binding id, revision, kind and owner;
    - the sealed box with the `"space-key"` and `"collection-key"` contexts;
    - legacy ids;
    - the signed manifest and its rule (its design 6).
  - The Kemlock Server sync plan: the signed-in client, DPoP tokens, the sync cursor, `items:batch` with
    `If-Match`, the field merge per item, and the vault's server list with the home first.
  - The duplicate cleaner plan: dedup tags and server matching.
- **Server side.** `kemlock-server` stores `spaces`, `members`, `groups` and `collections` (design,
  "Main tables"). That covers roles, member states (invited, accepted, confirmed), sealed space keys,
  and collections with encrypted names and keys sealed to each member granted them. It serves
  `GET, POST /kem/v1/spaces/…/members`. Once its OpenAPI spec and shared vectors are published, they are
  the contract. This design names what they must carry on the client side.
- **Mockup.** "Space · Example Co" draws:
  - the member table, with Owner, Admin, Manager, Custom and Member;
  - "Confirm Theo Grant", with a phrase read out;
  - the space key card, with "Replace space key";
  - policies and collections.

  It is a web vault screen. The app follows it in sheets, as the Spaces sheet does today.

Goals: no server action alone can put a key it controls among a space's members, widen a collection,
roll back a removal or swap a recovery key. A space nobody configures behaves like a WebDAV space. WebDAV
spaces keep working, unchanged, for members who never move.

Not goals:

- Hiding membership from the server: it sees who is in which space and collection, as the design's
  "What the server can see" table says.
- Key transparency across spaces, which is the design's later phase. The chain is per space, and only
  its members check it.

### 1. The fingerprint: one format for every client

A member's fingerprint is the account crypto plan's (design 5, from `crypto.md` "Public-key bundle
and fingerprint"):
- `SHA-512("kemlock/v1/fingerprint" ‖ bundle)`, where the bundle holds the account id, the key
  version, the `kx1` public key and the `sig1` public key;
- shown as 12 groups of 5 digits through `FingerprintView`;
- also shown as a QR code of the 64 bytes, scanned with the existing scanner and compared in constant
  time.

The web vault, the server's own pages and Amethystora Vault show the same digits.

- **It covers both keys.** Replacing either the exchange key or the signing key changes the
  fingerprint, so a member who replaces their key pair is confirmed again before keys are sealed to
  the new one. The design's "Replace the post-quantum key pair" row says other members must then
  check again.
- **Digits, not words.** The server's contract fixed digits, and one format everywhere is easier to
  explain. They need no word list in every language. Reading 60 digits takes longer than six words,
  so the confirm sheet groups them in three rows of four groups, and the QR code serves people in the
  same room.
- **Alternatives weighed:**
  - Bitwarden's five-word phrase over the RSA key and user id. It would be compatible in name only,
    since Kemlock's keys differ.
  - A pairwise safety number for two accounts. One comparison would check both sides, but a person
    joining can't know which admin will confirm them.

The person joining sees the inviting admin's fingerprint on the accept screen and may compare it. The
admin's check of the new member is the one that's required.

### 2. A signed, hash-linked space chain

The contract is the "Space chain" section of `docs/crypto.md` in the server repository, version 2
(draft `space-chain-spec-v2.md`). It wins over this plan and over the code, and this design is its
summary for the app. Nothing of version 1 was released, so the format keeps `"v": 1`.

Every change to who is in a space, their roles, the collections, groups and grants, the key versions
and the seals, the policies, the recovery key and the space's home epoch is a **record**. The member
who makes it signs it with their own `sig1` key, and each record holds the labelled hash of the record
before it. The server stores and serves the chain but holds no member's signing key, so it can't make
a record. Every member's client verifies the whole chain from the creator's self-signed first record
and takes members, bundles, roles, grants, key versions, seals and policies only from the state the
chain gives, never from the server's lists.

- **Record.** Nine members, `{"at","body","by","epoch","kind","prev","seq","space","v":1}`, in a strict
  subset of JSON that has exactly one spelling: no `null`, integers `0` to 2^53 - 1, strings of
  `A-Z a-z 0-9 - _ :` only (so no escape, no surrogate, no non-ASCII), member names once and in byte
  order, arrays that are strictly ascending sets, no whitespace, objects at most 6 deep. Its bytes are
  its RFC 8785 serialisation. Ids are hyphenated lower-case UUIDs and binary values base64url without
  padding; `space` is the legacy-id UUID for a moved WebDAV space (`chain_json.dart`, `chain_body.dart`).
- **Link.** `link(record) = SHA-256("kemlock/v1/space-chain/link" ‖ record bytes)`, 32 zero bytes
  before `seq` 0. The link covers the bytes only, never a signature.
- **Signature.** `sig1` under the context `"space-chain"`, so the message is
  `"kemlock/v1/sig1" ‖ lp("space-chain") ‖ lp(record bytes)`. The key that verifies a record is the
  bundle the chain records for `by` in the state before it (the creator's own for `create`). A `rekey`
  is also cosigned by the bundle it installs. On the wire a record is `{"entry", "signature"}`, with a
  `"cosignature"` for `rekey` only.
- **Kinds (21).** `create`, `invite`, `confirm`, `rekey`, `role` (an Owner included), `remove`, `grant`,
  `ungrant`, `collection`, `move`, `collection-delete`, `group`, `group-members`, `group-delete`,
  `rename`, `seal`, `keys`, `policies`, `recovery-key`, `recovery-key-clear` and `fence`.
- **What the chain commits to.** It never holds a sealed key or a sealed name, only their hashes: a
  commitment per key (`count`, a digest of the recipients' seal hashes, and for a new key version its
  check) and a `nameHash` with the space key version it is sealed under. A client uses a seal or a
  name only when its hash is the chain's.
- **Removal and replacement.** A `remove`, `ungrant`, `group-members` or `group-delete` names in
  `replace` every key a member held and is no longer entitled to; the verifier works the set out from
  the seals held and refuses another. Those keys are **marked**, and while the space key is marked no
  record may confirm, make a collection or group, rename, seal, or give access; a marked collection
  key blocks its own seal and new access. A `keys` record replaces them (design 4).
- **Authority.** Manage, Assign, MayGrant and GroupAdmin, and four rules for every kind but `create`:
  Owners change Owners (by diff, groups included), nobody widens themselves, access changes need
  MayGrant, and a confirmed Owner remains. A Custom member with `manage-users` acts only on members
  whose permissions are all its own. `keys` for a collection is signed by an entitled Owner, Admin or
  manager, or by any entitled member while it is marked; account recovery is an Owner's; `fence` and
  the recovery key are an Owner's.
- **Epochs.** A record's epoch is the state's, or one more exactly on an Owner's `fence`. The chain
  doesn't trust a server to move its epoch: after a promotion, the new home takes no record until an
  Owner's client has checked the promotion and signed the `fence` that names it. Records the old home
  took after it never become part of the chain.
- **Order of checks**, which fixes the reason a record that breaks several rules gets: anchor,
  position, signer, signatures, kind rules, authority. Reasons: malformed, too large, wrong space, bad
  sequence, bad link, bad epoch, unknown signer, bad signature, bad bundle, bad confirmation, invalid,
  not allowed, forked, rolled back.
- **The anchor.** For each space the device keeps, in the vault's encrypted store, the epoch and the
  link of every record it accepted (`space_head_store.dart`, format 2). A chain that ends before it is
  rolled back; another record at an accepted `seq` is forked, unless it is a verifying `fence` of a
  higher epoch, which drops the device's records from there for the Admins to redo or drop.
- **First contact.** A consistent chain proves nothing about people: a server could make a whole space
  of its own. Before the Accept button, an anchor, any key, account recovery enrolment or anything shown
  as checked, the device compares the fingerprint of an **anchor person** (the inviter for an invitee,
  the confirmer for a new device, none for the creator) as the verified chain records it at its head,
  and checks that bundle signed a record at or after the invite that admitted the account. A mismatch
  stores nothing. That the device compared is its own record, `"compared": true` beside the space's anchor
  (`SpaceAnchors.hasCompared`), set only by the first-contact screen once the digits matched and by the maker of a
  space, whose chain must begin with the `create` it signed; **an anchor alone is not first contact**. Reading a
  chain moves an anchor that is stored and never makes one, so the Spaces list can't anchor a space a server made
  up. A space with no such record holds nothing: a run opens no key and merges no item, the list says "Compare
  fingerprint", its name stays unopened, and its policies, recovery notice and matching notice are not applied or
  shown. The creator's other device and an account vouched for by its own key still need the chain to record the key
  this phone holds.
- **Using the state.** Keys open at the chain's current version only, through the commitment (design 3).
  Names show only when their hash and version are the chain's. Item revisions under another key version
  than the collection's current one, or newer than those accepted once the key is marked, are held. The
  manifest is accepted only from a signer the chain shows confirmed with edit on a collection.
- **Limits.** A record 192 KiB; a chain 65,536 records and 64 MiB; 1,000 grants, collections and groups;
  10,000 members; collections nested 16 deep; 1,001 seals and 257 rotated keys in a record.
- **Why a chain, not signed member records alone.** Signed records stop forged additions, but not
  withheld removals: a server could keep serving a removed member's `confirm` record. With a linked chain
  and the anchor, a device that saw "Lee was removed" can't be made to forget it. The space's manifest
  (design decision 4a) does the same for items.
- **Alternatives weighed:**
  - MLS (RFC 9420). It gives forward secrecy per message, but the RFC has no post-quantum ciphersuite.
    It also needs a delivery service, which the server isn't built as, and a large Dart implementation.
  - Trusting the server's member list. The design rules that out: "the server can't slip in a key of
    its own".

Decided by the owner on 2026-11-22: anchors across devices, and changes from outside Kemlock clients. Left for
the owner, each with a seam in the code marked `// owner: to decide`:

1. **Anchors across one account's devices** (decided). They sync through the personal vault: besides the
   device's own value, `SyncedSpaceAnchorStore` keeps them as one more sealed value, `backmycodes_space_anchors`,
   which the vault's own sync carries (Kemlock Server or WebDAV) and merges by `SpaceAnchors.mergedWith` (the
   longer chain when one is a prefix of the other, the higher epoch when a fence moved it, and a fork between
   two devices of one account named for the sheet). A new phone of the account then finds its spaces anchored
   and, where another phone compared them, compares no fingerprint. The anchor's `compared` record travels with it:
   merging keeps a comparison made on either device for one chain, and the taken anchor's own when two chains differ;
   an anchor with no record, as an earlier build of this branch wrote by anchoring what it read, goes through first
   contact again. A phone with no vault sync keeps them on the device only. On Kemlock Server the value is one item of the kind `space-anchors`, owned by the user, written only when it differs from the server's; on WebDAV it is the personal file's `extra` key `spaceAnchors`, never a space's file, so the space files stay as released (`KmScopeSync`, `mergeScope`).
2. **Chains past the limit.** The spec's limits stand, and a chain beyond them is refused as too large.
   The options are a `checkpoint` kind, a new space and a move, or a higher limit with incremental
   verification.
3. **Changes from outside Kemlock clients** (decided: queued for an Admin to sign). The server's
   Bitwarden-compatible routes and SSO group sync change members and groups with no signing key, so the
   server queues each as a pending change. An Owner's or Admin's app lists a space's pending changes on the
   space's sheet, shows what each would do, and approves one by appending the matching record, made through
   the record builders and signed with its own key, or drops it. Only a role the chain allows may approve:
   the record is run against the state and the authority rules first. The client verifies the chain and
   accepts nothing unsigned, as before (`space_pending.dart`). The server's routes are `GET /pending`, `POST /pending/{n}` (the body of an append) and `DELETE /pending/{n}`.

### 3. Keys: a space key for names, collection keys for items

A new space has a space key, and one collection, "Everyone", granted to every member with edit. An item
belongs to exactly one collection (owner decision 2). Its item key is wrapped under that collection's
`item-wrap` child: the collection key takes the space key's place as the parent in `crypto.md`'s
"Child keys", with the item-key wrap's additional data as `crypto.md` defines it. That use of a
collection key isn't in `crypto.md` yet, so it is listed under "Agreed with the server".

A space or collection key reaches a member only in `crypto.md`'s sealed box, sealed to the member's
`kx1` key from their confirmed bundle:

```text
space key:      seal(pk, key, context = "space-key",
                     aad = space uuid (16) ‖ u32be(space key version) ‖ member account id (16))
collection key: seal(pk, key, context = "collection-key",
                     aad = space uuid (16) ‖ collection uuid (16) ‖ u32be(collection key version)
                           ‖ member account id (16))
```

Every field of the `aad` has a fixed length, so no field can run into another, and the sealed box
adds `lp(context) ‖ lp(aad)` itself. There is no empty sentinel: the space key and collection keys use
different contexts. The server confirmed these `aad` layouts.

**Keys come from the chain.** The chain commits to the hash of every box, the digest of the recipients'
seal hashes and the check of each key version (design 2). A client opens the space key and each
collection key at the chain's current version only, never the version the server names, and accepts a
box only when the commitment at its `seq` covers just this member and the digest of its own box is the
committed one (or the server's hash list for that `seq` names exactly the recipients the chain gives and
its digest matches), when it opens under the bundle version committed, and when the key has the chain's
check (`space_seals.dart`). Otherwise it uses no key of that version and shows "Can't be checked". A
holder seals only to the members the chain says await a key, and publishes the boxes with a `seal`,
`keys` or `collection` record.

**Names.** A name is a `kem1` envelope under the space key's `"kemlock/v1/space-name"` child, of kind
`space-name`, `collection-name` or `group-name`, with the object's own id as the item id (the space's for
its own name), owner `space:<id>`, the space key version as the revision and the name's UTF-8 as the
plaintext. The chain holds `SHA-256` of the sealed name and the name version; a client shows a name only
when both are the chain's.

**Where the collection lives.** An item's collection id is metadata of the server item, sent beside
`owner` on the wire, never a key of the entry's JSON. The phone keeps it in the server space's scope
state, per item id. So `_withoutPlace` (`sync_merge.dart`), which strips only `updatedAt` and
`spaceId`, keeps working: a move into a server space is never refused as "held elsewhere" because of
it, and a bridged WebDAV file never gains a `collectionId`.

- **Why one collection per item.** With several, an item key is wrapped once per collection and every
  key replacement multiplies. With one, it stays linear. Bitwarden items are untouched either way.
- **Roles.** Owner, Admin and Member, with permissions per grant. This follows the design's "Feasible
  with a change" row: Manager becomes the per-collection manage permission. "Hidden passwords" is a
  display rule only: the member holds the key, so it guards against shoulder-surfing and careless
  copying, not against the member. The sheet's help text says so.

### 4. Replacing keys after someone leaves

When a member is removed or leaves, the derived state marks the space "keys need replacing". The
remover's app runs the replacement at once; otherwise the next Owner or Admin app to open the space
does. A replacement:

1. Makes a new space key, and a new key for each collection the leaver held.
2. Seals each new key to the members still granted it, and writes a `keys` entry.
3. Re-encrypts every item of those collections under a fresh item key, in `items:batch` writes of up to
   500 with `If-Match`.
4. On a 409, merges with the sync plan's field merge and retries that item.
5. Signs the space's manifest once, after the last batch, as the account crypto plan's design 6
   requires after a key replacement.
6. Ends with a read-back that compares every item's revision and key version, and the manifest.

Progress is the set of items still under an old key version, so a run that stops resumes by reading the
space again.

- **Why re-encrypt, not only re-wrap.** The leaver may have kept item keys. Re-wrapping the old item
  keys under a new collection key would let the leaver open later revisions, whenever a revision reuses
  its item key. A fresh item key for each item at replacement gives the guarantee whatever the leaver
  kept, and whether or not the account crypto plan gives each revision a new item key. A space of a few
  thousand items is a few batches.
- **Writes under an old version.** The server refuses an item write under a collection key version
  older than the chain's. The app never writes one either, so a phone that was offline merges and
  re-encrypts under the new key.
- **Dedup tags.** A new space key gives a new dedup key version, and the duplicate cleaner re-tags in
  the same batches.

### 4a. The space's manifest

The account crypto plan owns the manifest rule (its design 6). For a space it means:

- **Who signs.** A member whose role the verified chain allows to write items: an Owner, an Admin, or
  a member with an edit or manage grant. A manifest signed by anyone else, or by a key the chain
  doesn't confirm, is refused.
- **What it lists.** Every item of the space, in every collection, with its revision and
  `SHA-256(ciphertext)`, or 32 zero bytes for a tombstone. It doesn't cover only what the signer can
  open.
- **What the server sends.** Every space item's envelope to every confirmed member, whether or not
  they hold its collection's key. A member never sees the contents of a collection they aren't
  granted: they can't unwrap its item keys.
- **What a member checks.** Presence and revision for every entry, and the ciphertext hash, against
  the envelopes received. Contents only for the collections they hold. So a member granted only
  Engineering still notices a Finance item withheld or rolled back. Without this, a partial member's
  manifest check would report every unreadable item missing and stop every run.
- **When it is signed.** At the end of each sync run that wrote to the space, by the writing
  device, and after a key replacement's last batch.
- **Unlisted items** are held and flagged. That covers a removed member writing with a key they kept
  before the replacement: their writes arrive unlisted, and no permitted signer lists them.

Sending every envelope to every member, and the server's routes for a space manifest, are listed
under "Agreed with the server".

### 5. Home-only writes

Every chain entry and sealed key goes to the home on the server list, with the epoch the app last saw.
The home can fail by the failover rule: two failed requests, or 10 seconds without an answer. While it
is down, the actions that write chain entries are disabled with "Waits for <home> to be back". Nothing
is queued. A removal sent later under a stale epoch would be refused anyway, and a person should redo
it knowingly.

### 6. Policies from the chain

Policies are `policy` entries, and the recovery public key is a `recovery-key` entry signed by an Owner.
The app:

- passes Require SSO to sign-in, which the sync plan checks before showing sign-in methods;
- enforces the export, one-space and password-length rules on the device;
- shows the account recovery and duplicate-matching notices.

Account recovery enrolment seals the root to the recovery key in a sealed box under `crypto.md`'s
`"account-recovery"` context, only after the member taps Agree. A member who declines is offered to
leave (owner decision 3).

### 7. Moving a WebDAV space: same ids on the phone, legacy UUIDs on the server, bridged until closed

The mover's app:

1. Creates the server space under the UUID that `crypto.md` "Legacy ids" gives for the WebDAV space's
   id: `uuidv8(SHA-256("kemlock/v1/legacy-id" ‖ lp("space") ‖ lp(old space id)))`. Every member's app
   computes the same UUID, so a joining member finds the server space from the WebDAV id it holds. The
   local scope id stays the WebDAV id.
2. Uploads every entry as a `kem1` item in "Everyone". An entry whose id is a UUID keeps it. Any other
   id is mapped under the space's owner (`0x02 ‖ space uuid`). The entry's JSON keeps its own id, and
   the merge pairs copies by it.
3. Signs the space's manifest after the last batch.
4. Reads the space back to check it.

Because the owner is part of an item's legacy UUID, an entry with an older id that later moves between
this space and a vault gets a new UUID. The server sees a delete and a create, and the phone pairs the
two by the original id.

Members are then invited by email and confirmed as for any space. When a member's app finds a server
space whose id equals a WebDAV space it holds, it offers to merge the file into the server space once.
That UUID is computable by anyone who can list the folder, so the offer needs more than the server's
word: an anchor for the space that a real fingerprint comparison stored (the accept screen, or the
account's synced anchors; the join path never makes one), the space's move marker, and the person's
agreement, which names the space's Owner.

Until the WebDAV copy is closed, every moved member's app also syncs the WebDAV file, as a second target
of the same scope. It merges the file, the server space and the device, writes the server items, and
writes the file back when it differs, exactly as today's WebDAV sync writes it. The file holds the space's
entries as one set for everyone who has its key, so the bridge carries a space with one collection and
no grant that hides passwords. Removing or losing any member, replacing keys, a second collection, or
a grant that hides passwords closes the bridge, since the WebDAV key can't be taken back and the file
can't keep a restriction. The alternative, a
one-time move, is owner decision 1.

### 8. Code layout

`mobile/lib/features/spaces/` holds:

- `chain_json.dart`: the strict JSON of a record; `chain_kind.dart` and `chain_body.dart`: the 21 kinds, their reasons and exact shapes; `space_chain.dart`: records, their links and signatures; `space_types.dart`: roles, permissions, key refs; `space_state.dart`: the derived state; `space_verify.dart`: the order of the checks, who may sign, the anchor and the fence;
- `space_keys.dart`: sealing, names and the keyring; `space_seals.dart`: seal commitments, key checks and opening a key through the chain; `space_head_store.dart`: the anchors; `space_manifest.dart`: the space's manifest; `space_scope.dart`: ids and the collection of each entry in the scope state;
- `fingerprint.dart`;
- `server_spaces.dart`: the scope adapter for the Kemlock Server sync engine;
- `space_move.dart`;
- the sheets.

Everything but the sheets is pure Dart with no Flutter import. That way, the move into
`packages/kemlock_core` that the `add-browser-extension` change plans can take these files as they are.
That change is in the git history before 5ba88b42, and the move is its tasks 2.3 to 2.5.

### Risks and trade-offs

- **The server withholds new chain entries from one member.** That member keeps an older state and
  sees no removal until it syncs again, but it can't seal a key to anyone new, and it can't be made to
  seal to an unconfirmed key. Each member's anchor and the manifest show a withheld removal as soon
  as any later entry arrives.
- **A removed member still holds what they saw.** That can't be avoided. The app lists what they could
  open, so admins can change those passwords.
- **A bridged WebDAV copy is as weak as today's spaces.** The bridge closes on any removal or key
  replacement, and the move screen says so.
- **A key replacement in a large space, on a phone.** It runs in batches of 500 and resumes if stopped.
  The app keeps the screen on and shows progress while it runs.
- **Freshness of the chain.** The anchor catches a chain that ends before what this device accepted, but a server can still
  serve an old chain to a phone that has seen nothing newer, for as long as it likes: there is no freshness limit. A
  phone that syncs often sees a removal as soon as any later entry arrives; a limit (a signed head with a time) is left
  for later.
- **The server's contract isn't complete yet.** `crypto.md` fixes the sealed box, `sig1`, the
  fingerprint and legacy ids. The chain's context, the seal `aad` layouts, collection keys as wrap
  parents and the space manifest are proposed here and listed under "Agreed with the server". Their
  fixtures come only from the server's vectors once published, copied by the account crypto plan's
  script; until then the tests build their cases in code. The routes wait for its OpenAPI spec.

### Migration and rollback

Nothing on a phone changes until someone makes or joins a server space. WebDAV spaces, files and invites
are read and written as today. A moved space keeps its scope id, so `ScopeState.known` and every entry's
`spaceId` stay valid. An older build doesn't know server spaces. Their entries stay in its vault under
their `spaceId`, and a WebDAV copy that is still bridged keeps syncing. No entry gains a new key.

Still to settle, without changing this plan: the route shapes for chain entries, sealed keys and the
space manifest, once `kemlock-server` publishes its OpenAPI spec.

## Behaviour

### Members

- **Fingerprint.** Every account has a fingerprint: SHA-512 over its public-key bundle, shown as 12
  groups of 5 digits. Settings › Account security shows it, and a QR code holding the 64 bytes.
  - One account shows the same digits and QR code on every device, and in the web vault.
  - When the account replaces its key pair, its fingerprint changes, and every space it belongs to
    shows it as needing confirmation again.
  - Every case of the server's fingerprint vectors, copied into `mobile/test/fixtures/server/`, gives
    its recorded digits.
- **Inviting.** An Owner or Admin can invite someone by email. An invitation grants nothing: no key is
  sealed to anyone until they are confirmed.
  - Ana, invited and not yet confirmed, shows as "Invited", and no space or collection key is sealed to
    her.
  - A Member is offered no "Invite people" action.
- **Accepting.** A person accepts or declines in their app. Before they accept, the app shows the
  space's name, who invited them with that admin's fingerprint, the policies for members, and every
  notice those policies require.
  - For a space with account recovery on, the accept screen says, before the Accept button, that the
    space's admins could reset the person's master password and open their vault.
  - After Theo accepts, his app shows "Waiting for an admin to confirm you" and his own fingerprint to
    read out, and lists no space items.
- **Confirming.** An Owner or Admin confirms an accepted member only after comparing their fingerprint,
  read out, or their QR code, scanned. Confirming records the member's bundle in the chain, and seals
  to them the space key and the keys of the collections they are granted.
  - The admin's app shows Theo's 12 groups of digits, Theo's app shows the same, and the admin taps "It
    matches". Theo is confirmed, and at his next sync his app lists his collections' items.
  - The digits differ and the admin taps "Not now". Nothing is sealed, and the app says that a
    different fingerprint means someone else's key is in the way.
  - The scanned QR fingerprint equals the one computed from the bundle the server gave for Theo: the
    app confirms him without asking for the digits.
  - The scanned fingerprint differs: the app refuses, with the same warning as differing digits.
- **Roles and grants.** A space has the roles Owner, Admin and Member. Each grant of a collection to a
  member or group carries one of view, view with hidden passwords, edit, edit with hidden passwords, or
  manage. The app offers actions by role and permission.
  - With "view" on Finance, a member sees Finance's items without Edit or Delete.
  - With "view with hidden passwords", the login sheet has no Show or Copy for the password, and
    AutoFill still fills it.
  - When an admin grants Engineering to a confirmed member, the admin's app seals Engineering's key to
    them and records the grant.
- **Leaving.** A member can leave from the app, and the space's items leave all their devices. The only
  Owner can't leave until another confirmed member is made Owner.
  - After a Member leaves, the space's items disappear from their devices at the next sync, and the
    space's admins see that the keys should be replaced.
  - The only Owner trying to leave is asked to make another confirmed member Owner first.
- **Removing.** An Owner or Admin can revoke or remove a member. Removing records it in the chain,
  lists what the member could open, then replaces the keys they held.
  - Removing Lee, who had Finance, shows that Lee could open Finance's 12 items, records the removal,
    and starts replacing the space key and Finance's key.
- **Changes only on the home.** Chain entries go only to the space's home, with the epoch the app last
  saw. While the home is unreachable, none of those actions are offered, the app says why, and items
  keep syncing through replicas.
  - With the home down, items sync, and Invite, Confirm, Remove and Replace keys say they wait for the
    home server to be back.
  - An entry made under an epoch older than the one a promotion record moved the space to isn't
    applied. It is shown to the space's admins to redo or drop.
- **Space ids stay apart from the vault's own.** The app refuses a server space whose id isn't a valid
  space id, or is `personal` or `vaultwarden`, as it refuses such an invite today.
  - A server space listed with the id `personal` is ignored, and nothing syncs into or out of it.
- **Entries held in another scope stay there.** A space item whose id this device holds in another
  scope replaces that entry only when it equals it but for its space and its change time.
  - A member writes a space item under the id of this device's own login, with other contents and a
    later time. The login stays in its own vault unchanged, and the space item isn't shown under that
    id.

### The space chain

- **Every change is a signed entry.** Members, roles, grants, policies, the recovery key, and space and
  collection keys change only through chain entries. Each names its space, sequence number, the hash of
  the entry before, its home epoch, its time and its signer. It is signed with the signer's `sig1` key
  under the context `"space-chain"`.
  - At each sync, the app verifies each new entry's signature, sequence number and link before using
    what it sets.
  - A chain entry signature checked under the context `"manifest"` or `"bundle"` doesn't verify.
  - Every valid chain among the test cases is accepted, and each invalid one is refused for the reason
    the case names. The cases are built in test code until the server's chain vectors exist, then come
    from them.
- **Only authorised signers.** An entry counts only if its signer was, at the entry before, a confirmed
  Owner, or a confirmed Admin acting within an Admin's rights. The first entry is signed by the account
  that made the space, which becomes its Owner.
  - An entry adding a member, signed by a Member, is refused from that entry on. The app keeps the last
    valid state and shows the space as "Can't be checked".
  - An entry whose signature doesn't verify under the signer's recorded key is refused the same way.
  - An Admin's entry removing or demoting the Owner is refused.
- **The chain can't go back or fork.** The app remembers, per space and in the vault's encrypted store,
  the last entry it accepted. It refuses a chain that ends before that entry, or holds a different
  entry at a sequence number it already accepted.
  - The app accepted entry 12 and the server's chain ends at 9. The app keeps entry 12's state, seals
    nothing new, and says the server sent an older list of members.
  - The server's entry 12 differs from the one the app accepted. The app refuses the chain and shows the
    space as "Can't be checked".
- **Keys only to confirmed members.** The app seals a key only to a member the verified chain confirms,
  using the `kx1` key in their confirmed bundle. It never seals to a key the server lists but the chain
  doesn't confirm.
  - When an admin replaces a collection key and the server's list holds an unconfirmed key, the new
    key goes only to chain-confirmed members, and the extra key is logged in the space's activity.

### Keys

- **Space key and collection keys.** Each server space has a 32-byte space key for its own names, and
  each collection a 32-byte key that wraps its items' item keys. Every key has a version number and is
  made on a member's device from the secure random source.
  - Making a space makes its space key and the "Everyone" collection with its own key, both sealed to
    the maker.
- **Sealed to each member's exchange key.** A key reaches a member only in a sealed box to their `kx1`
  key, under the `"space-key"` or `"collection-key"` context. The space, the collection for a
  collection key, the key version and the member's account id are bound into the seal's `aad`.
  - A seal made for Mina, handed to Theo, doesn't open, and Theo's app reports a key problem for that
    collection.
  - A space key's seal opened as a collection key fails.
  - Each sealed-key case opens to its key, or is refused when it is marked as bound to another space,
    collection, version or member. The cases come from the server's vectors once published.
- **Space items are keyed by their collection.** Every space item belongs to one collection. Its item
  key is wrapped under that collection's `item-wrap` key, and its owner in the item's binding is the
  space. A member receives every item's envelope, but opens and lists only the items of the
  collections they are granted.
  - Theo, granted Engineering only, receives Finance's envelopes for the manifest check, but can't open
    them and lists none of them.
  - The server withholds a Finance item from Theo: the space's manifest still lists it, and Theo's app
    reports it missing.
  - When an item moves from Engineering to Finance, it gets a new item key under Finance's key, and
    members with Engineering alone no longer see it.
- **Keys are replaced after someone leaves.** An Owner or Admin's app makes a new space key, and new
  keys for the collections the member held. It seals them only to those who stay, re-encrypts every
  item of those collections under new item and collection keys, and records the new versions.
  - When Jordan edits a Finance login after Lee's removal and the replacement, the new revision opens
    only with Finance's new key, which was never sealed to Lee.
  - When a Member leaves and no admin's app is open, the space shows "Keys need replacing" to its
    admins, and the next admin's app to open it asks to replace them.
- **Replacing is resumable and checked.** Items go up in batches of at most 500, each write conditional
  on the item's revision. A failed batch is resent unchanged, and an item changed meanwhile is merged
  and re-encrypted. Every item's revision and key version is compared with the server before the app
  reports the replacement done.
  - Mina edits a Finance item during Jordan's replacement. Jordan's write fails on its revision, his app
    merges Mina's edit and re-encrypts it, and the space ends with her edit under the new key.
  - Jordan's app, closed after two of five batches, carries on from the first item not yet under the new
    key.
- **No writes under a replaced key.** After a collection key is replaced, an app never writes under the
  old version: it fetches the new key, merges, and writes under that.
  - A phone offline since before the replacement syncs an edit, and it lands under Finance's new key,
    merged with what changed meanwhile.
- **Keys follow a member's new key pair.** When a member replaces their key pair, their keys are sealed
  again only after an admin confirms them again.
  - Mina sees the space's items again only after an admin confirms her new fingerprint.
- **The space's manifest is checked by everyone.** It lists every item of the space, is signed by a
  member allowed to write, and is signed after each run that wrote and after a key replacement.
  - A manifest signed by a Member with view-only grants is refused.
  - A removed member's write with a key kept from before the replacement arrives unlisted, and is held
    and flagged on every member's app.

### Policies

- **Policies come from the chain.** The app reads a space's policies only from its verified chain,
  where an Owner or Admin signed them, and shows them in the space's details. Only a space whose fingerprint
  this device compared counts (`onComparedChain`); a chain a server made up, listed but never compared, forces
  nothing. A policy is also tied to the account it was read for: Require SSO holds in the sign-in sheet for the
  email that account signed in with, not for whoever signs in next.
  - The server reports account recovery on, but the verified chain says off: the app treats it as off
    and enrols nothing.
- **Require SSO.** When any space the account is a Member of requires SSO, the app tells sign-in to
  offer only SSO for that account, unless it is that space's Owner or Admin.
  - Theo, a Member, signing in on a new phone, is offered SSO and no password, passkey or phone
    approval.
  - Sam, the Owner, keeps every sign-in method.
- **Account recovery.** Where a space's recovery policy is on, the app tells the member before they
  join, and again when an admin turns it on. Only after the member agrees does it seal their user key
  to the recovery public key an Owner recorded in the chain.
  - Turned on later, Theo's app explains what it means and asks him to agree or leave, and seals nothing
    until he agrees.
  - A recovery key that no Owner's chain entry records is refused, and the space shows "Can't be
    checked".
- **Duplicate matching notice.** Where a space's admins turned on server matching of duplicates, each
  member is shown, once and in the space's details, what the server can learn: which of the space's
  items share a sign-in, how many, and when a new one appears.
  - After matching is turned on, each member sees the notice at their next open of the app, and it
    stays under the space's details.
- **Rules enforced on the device.** A space's items are left out of every export when the space forbids
  exporting them. Joining a second space is refused when a space allows one per member. A new master
  password must meet the space's minimum length.
  - An encrypted export holds the member's own items only, and the export sheet names the space left
    out.
  - An invitation to a second space says the member must leave their current one first. An invitation the member
    accepted and waits to be confirmed in counts as being in the space for this rule.
  - A member of a space that allows one makes no other: Make a space is held back, naming the space to leave. A member
    already in two spaces, one of which turned the policy on later, is told to leave one of them. **The server must
    enforce one space per member as well**: the app's rule is a courtesy a modified client skips.
  - A private key of a space that forbids export is not saved to a file from the key's sheet (the same rule as the file
    exports, unknown spaces failing closed). Show and Copy stay as they are: a key on screen or on the secret clipboard is
    no file.
  - Changing to a 12-character password in a space requiring 14 is refused, naming the space.

### Moving a WebDAV space

- **Moving.** A member whose vault syncs with Kemlock Server can move a WebDAV space they belong to. The
  space keeps its id and name on the phone, every entry keeps its id, and the mover becomes Owner. On
  the server, ids that aren't UUIDs take their legacy-id UUIDs.
  - Sam moves "Family" with 40 entries. The server space "Family" holds 40 items in "Everyone", each
    entry with its own id inside, Sam is Owner, and his other devices list the space once.
  - Ana's phone, holding the WebDAV space `fam-01`, computes the same server UUID and finds the moved
    space.
  - When the upload ends, the app reads the space back and compares every id and hash before reporting
    it moved. On a difference, the space keeps syncing the WebDAV file alone.
- **The WebDAV file and invites are unchanged.** They stay byte for byte as released, and the app writes
  nothing new into them, `collectionId` included.
  - The space files and invites in `mobile/test/fixtures/sync` still open to what each fixture records.
  - A bridged write of an entry in a non-default collection writes exactly the JSON today's sync
    writes.
- **The bridge.** Until the Owner closes the WebDAV copy, each moved member's app also syncs the WebDAV
  file, carrying changes both ways with the field merge.
  - Ana's older phone edits an entry in the file, and the next moved app to sync merges her edit into
    the server space.
  - When Ana's app finds the server space by the WebDAV id, it names its Owner and asks. Only if she
    agrees, and the account already compared that chain's fingerprint, it merges its WebDAV copy in once,
    by id, and stops writing the file. Its invites are by email from then on, never a `bmc-space:` one.
- **Closing the WebDAV copy.** The Owner can close it, which stops every moved app from reading or
  writing the file. The app closes it on its own when a member is removed or leaves (whether or not
  keys were marked), keys are replaced, the space gets a second collection, or a grant hides passwords,
  and says so; the space sheet warns before a grant that hides passwords on a space whose copy is open.
  - Removing a member from a moved space with an open bridge closes it. The app warns that anyone
    holding the old invite can still read the file as it was, but will see nothing new.
  - The closed file stays in the folder unchanged, and the app offers to delete it.

## Tasks

The tasks assume the recommendations under Decisions for the owner. Coding agents don't run builds,
tests, CI or `pub get`: each "Verify" names the test that the single build-and-test pass after merging
runs. Tests go in their own `test(sync)` commits, after the code they check. The `sync` scope is added
to `CLAUDE.md` by the main session before building starts. No fixture shared with the server is written
by the app: those come from the server's vectors, and an old fixture is never regenerated.

### 1. Fingerprints

- [x] 1.1 Show the account's fingerprint and QR code under Settings › Account security, through the account crypto plan's `FingerprintView` (its task 4.2), worded for reading it out in three rows of four groups. Verify a widget test finds the 12 groups and the QR code, in English and French. (Code done; verify after merge. The widget is `lib/features/spaces/fingerprint_view.dart`, written here because the account crypto plan left it unwritten; the row shows only for a vault signed in to Kemlock Server.)
- [x] 1.2 Hold the display to the server's fingerprint vectors once the account crypto plan's script has copied them. Verify the Dart test reproduces every case's digits. (The vectors are copied: `test/crypto/server/bundle_vectors_test.dart` reproduces every case's digits, and the widget test of 1.1 shows the same groups.)

### 2. The space chain

- [x] 2.1 Add `space_chain.dart`, `chain_json.dart`, `chain_body.dart` and `space_state.dart`: the record model in its strict JSON subset, the link under its label, signing and verifying with `sig1` under the context `"space-chain"` (and a `rekey`'s cosignature), the 21 kinds with their exact shapes and limits, and the derived state (members with their bundles, roles, grants, name hashes, seal commitments, key checks, marks, policies, recovery key and home). Verify unit tests that a valid chain of each kind derives the expected state, that each shape the spec refuses is malformed or too large, and that a `"manifest"`-context signature is refused as a record. (Code done; verify after merge. The spec's two link examples, computed by hand, are known-answer tests marked provisional until the server's vectors arrive.)
- [x] 2.2 Verify in the spec's order (anchor, position, signer, signatures, kind rules, authority), check who may sign by its four rules and each kind's row, and hold the chain to the anchor: rollback, fork, and the fence that drops a device's records. Verify that each gives its expected reason: a Member's `invite`, an Admin changing an Owner through a group, a Custom member widening themselves through a group, a bad signature before a bad authority, a bad link before a bad signature, a shorter chain, a different record 12, a fence at 10 above an anchor at 12, and an epoch that jumps. (Code done; verify after merge, in `space_verify.dart`. A fence is held to its promotion record through `fenceCheck`, which the sync plan supplies.)
- [x] 2.3 Store each space's anchor (the epoch and the link of every record accepted) in the vault's encrypted store, under the sealed key older builds pass through, and add it to `sealedValueKeys`. Verify that `test/vault/unknown_sealed_value_test.dart` still passes, that deleting a vault removes the key, and that a version-1 value (a head) reads as no anchors. (Code done; verify after merge. `backmycodes_space_heads` is a sealed value written through `saveEncryptedValue`, format 2. The owner chose to sync them through the personal vault: `SyncedSpaceAnchorStore`, over the sealed value `backmycodes_space_anchors`, which the vault's sync carries.)
- [x] 2.4 Once the server publishes `test-vectors/space-chain.json` for the agreed format, hold the chain code to it, in place of the provisional link examples (copied into `mobile/test/fixtures/server/` by the account crypto plan's script). Until then, the valid and invalid chains are built in test code, not written as fixtures. Verify the Dart test passes every server case. (Done; verify after merge. The server publishes it: `space-chain.json` is in `mobile/test/fixtures/server/` and in `SHA256SUMS`, byte for byte what `kemlock-server` holds on `build/vertical-slice` (sha256 `0e444b45...`). `test/crypto/server/space_chain_vectors_test.dart` runs every case: the 2 `link`, 18 `encoding`, 1 `signing`, 2 `seals` and 53 `chain` cases, so the provisional link examples are gone. Nothing was added in this merge.)

### 3. Space and collection keys

- [x] 3.1 Add `space_keys.dart` and `space_seals.dart`: making space and collection keys, sealing them in `crypto.md`'s sealed box under `"space-key"` and `"collection-key"` with design decision 3's fixed-length `aad`, opening them only through the chain's commitments at its current version (the seal hash, the digest over the recipients and the key check), and names as `kem1` envelopes under the space key's `"kemlock/v1/space-name"` child. Verify a unit test for each binding mismatch, for a box the chain didn't commit to, an old version, an extra recipient in the hash list and a wrong check, and that a name shows only for the chain's hash and version. (Code done; verify after merge. The aads and the names are the server's; the digest and the check are written out by hand in the tests.)
- [x] 3.2 Hold the seals to the server's sealed-box vectors for both contexts once copied. Verify the Dart test opens or refuses each case as recorded. (Verify after merge, in `test/crypto/server/space_key_vectors_test.dart`. The server's vectors hold one `space-key` case and no `collection-key` case yet; the test covers both as they come.)
- [x] 3.3 Wrap space items' item keys under their collection key's `item-wrap` child, with the space as owner in the AAD. Keep each item's collection id in the server space's scope state, never in the entry's JSON. Verify that every existing fixture under `mobile/test/fixtures/sync` and `mobile/test/fixtures/vault` opens byte for byte, that `_withoutPlace` is unchanged, and that a move into a server space isn't refused as held elsewhere. (Code done; verify after merge. Items are wrapped by `SpaceItemCrypto` in `space_keys.dart`, and the collection of each entry is kept in the scope state by `space_scope.dart`. No existing file of the merge or of the fixtures was changed.)
- [x] 3.4 Map the space id and entry ids with the account crypto plan's legacy ids (space owner `0x02 ‖ space uuid`). Verify against the server's legacy-id vectors that a space id gives the recorded UUID, and that two members compute the same one. (Code done; verify after merge, in `space_scope.dart`, over `legacy_ids.dart`)

### 3a. The space's manifest

- [x] 3a.1 Sign the space's manifest per design decision 4a: only a member the chain allows to write, every item of the space listed, signed at the end of each run that wrote and after a key replacement. Verify fake-server tests that a run that wrote sends one manifest, and that a view-only member's manifest is refused. (Code done; verify after merge. `KmSpaceSync` in `server_spaces.dart` signs one manifest after a run that wrote, if the account may write the space's items; `space_manifest.dart` has the rule. The server's rule is edit on one collection through a grant, which is narrower than the design's Owner or Admin)
- [x] 3a.2 Check it as a member: presence, revision and hash for every entry, and contents only for held collections, with unlisted items held. Verify fake-server tests: a member with Engineering only reports a withheld Finance item missing; a removed member's later write is held and flagged; a full sync of a partly granted member doesn't stop on unreadable items. (Code done; verify after merge. Every envelope of the space is checked against the manifest, readable or not; a run stops on a missing, rolled-back or resurrected one and holds an unlisted one)

### 4. Server spaces as a sync scope

- [x] 4.1 Add `server_spaces.dart`. It lists the account's spaces, verifies each chain, opens each space's keys, and syncs each space as a scope through the Kemlock Server sync engine, with `mergeScope` and `applyScope`. It refuses ids that `isSpaceId` refuses. Verify against the fake server that two members see each other's edits, and that a space named `personal` is ignored. (Code done; verify after merge, in `server_spaces.dart`. The scheduler runs each space the account is a confirmed member of as a scope under its UUID (`KemlockSpacesBackend` in `km_backend.dart`, run by `SyncScheduler`, with `KmSpacesBackend` for the app): on open, on settle, in front, on the period and on Sync now, paused while a move runs, each space's problem in the sync problems, and a space that stops (its chain fails, its keys are being replaced) stops alone; listing is the Spaces sheet's work in task group 5; the run takes the space's UUID and refuses ids `isSpaceId` refuses. The chain routes are the server's, pinned and used through `space_chain_client.dart`; the manifest route is marked "server: to confirm")
- [x] 4.2 Keep audit finding 6's guard for server scopes. Verify a test that a changed space item under the id of this device's own login leaves the login in place, and that `heldElsewhere` reports it. (Code done; verify after merge. `applyScope`, `heldElsewhere` and `_withoutPlace` are unchanged and serve a server space as any other scope)
- [x] 4.3 Seal only to chain-confirmed members. Verify a fake-server test that an extra key in the server's member list gets no seal and is logged. (Code done; verify after merge. `planSeals` takes the recipients and their `kx1` keys from the chain's state and returns the server-listed members it ignored, for the caller to log)
- [x] 4.4 Send chain entries and seals only to the home, with the last epoch seen. While the home is unreachable, disable those actions with their message (design decision 5). Verify a fake-server test with the home down: items sync through the replica, and Invite, Confirm, Remove and Replace keys show the message. (Code and tests done; verify after merge. `KmSpaceSync.homeDown` names the home while the phone is on a replica and the home is not known to be back (`KmServerSpaces.homeDown`, from `KmHost.requireHome`). Until then `requireHome` refuses every chain append, `create`, pending-change answer and key replacement with a `SpaceActionError` of `SpaceActionProblem.homeAway`, before anything is built or sent and with nothing queued; the sheet words it in `space.error` and `space.confirm.failed`, and its buttons were already off with `space.homeDown`. A record carries the epoch of the chain the phone last verified (`state.epoch`, `space_actions.dart`). Items keep syncing through the replica. `space_home_only_test.dart` holds all of it against the fake server.)

### 5. Members in the app

- [x] 5.1 Make the Spaces sheet list WebDAV and server spaces apart. A server space's sheet shows its members with role and status, its collections, its policies, and its space key's version and date, per "Space · Example Co". Verify widget tests for each member status.  (Code done; verify after merge. `server_space_sheet.dart` shows the members with role and state (`space_overview.dart`), the collections with their grants, the policies, the space key's version and date, the keys that need replacing, Leave, the pending changes and the held items; `server_spaces_list.dart` lists a person's server spaces apart from their WebDAV ones on the Spaces sheet, through a `ServerSpacesSource`. Not wired in the app yet: no production `serverSpacesSourceProvider` or `ServerSpaceSheet` host builds the sheet's closures from `KmSpaceSync.actions()` and the vault's connection, so the section stays hidden until one does.)
- [x] 5.2 Make a space (with "Everyone"), invite by email, and resend or revoke an invitation. Verify fake-server tests that an invitation seals nothing. (Code and tests done; verify after merge. A space is its `create`, with its seals and names, as `records[0]` of `POST /kem/v1/spaces/{newId}/chain`, which is how the server makes it; the list reads `GET /kem/v1/spaces` as `[{space, member}]` and opens the space's `kem1` name through the chain's commitment (`km_server_spaces_test.dart`). Invite by email looks the address up with `GET .../lookup?email=`, shows who would be invited and in which role, then builds the `invite`, which seals nothing; resend is `POST .../members/{user}/resend`. The lookup, the resend and the invitee's accept and decline (5.3) are built to the shape the server's session gave and marked `server: to confirm` in `space_invites.dart`, with the fake server's side in `fake_space_server.dart`. The fake-server tests are in `server_spaces_test.dart` ("inviting by email") and `space_invites_test.dart`.)
- [x] 5.3 Accept and decline: show the inviter's fingerprint, the policies and their notices before Accept, then the "waiting to be confirmed" state. Verify widget tests that the recovery notice comes before Accept. (Code and tests done; verify after merge. The first-contact comparison in `accept_space_sheet.dart` holds the Accept button, the anchor and the notices back until the inviter's or confirmer's fingerprint, as the verified chain records it, matches by digits or by the app's scanner (`fingerprint_scan.dart`); it then shows the space's name when it opened, the policies from the verified chain, the recovery notice and the notices of the policies that affect a member, all before Accept. Opening an invitation in the Spaces list reads the chain without storing its anchor, stores it once the digits matched, and Accept leads to the "waiting to be confirmed" sheet with the person's own fingerprint; Decline answers for good and "Not now" leaves it unanswered. Left for the server: the accept and decline routes are marked `server: to confirm`; an invitee holds no space key, so the name shows only if the server gives one that opens; and no route gives the bundle of a member who accepted, so the sheet's Confirm button isn't offered in the app until one does.)
- [x] 5.4 Confirm by the 12 groups of digits ("It matches", "Not now") or by scanning the QR code with the existing scanner; refuse a differing fingerprint with the warning. Verify widget and fake-server tests of both outcomes. (Code done; verify after merge. The sheet's confirm view shows the digits of the bundle the server gave, and "It matches" or a matching scan makes the `confirm` (`buildConfirmAction`) and seals the member's keys; a differing scan is refused with the warning and offers no way on. The tests run the actions against a chain kept in memory, not the fake server.)
- [x] 5.5 Add roles and grants with the five permissions, granting a collection (which seals its key), and hidden passwords in the login sheet with AutoFill still filling. Verify a widget test per permission. (Code and tests done; verify after merge. `role`, `grant` and `ungrant` are in the sheet's menus, a grant to a confirmed member seals the collection's key, and the help text on hidden passwords is shown. The login sheet hides the password, Show, Copy and the strength line of a login whose collection the account holds only with a "passwords hidden" grant, and the previous passwords too (`hidden_passwords.dart`); `test/features/logins/hidden_passwords_test.dart` has one widget test per permission, and checks the login still holds its password, which AutoFill reads. The edit sheet of such a login shows no password field, Show, Generate or strength bar and saves the password as it was; password health leaves a hidden password out of "reused" and "weak"; the duplicate merge makes no password choice for a group holding one and never moves it into another login's previous passwords; the encrypted, plain and Credential Exchange exports leave the login out; there is no Send from an item on this branch. Choice made: the task's wording is "AutoFill still filling", so AutoFill keeps filling a hidden password into a site, from the copy the app writes (encrypted on the phone's side), and never displays it. `KmSpaceSync.onChain` reports each verified chain, and a sync run the collection of each entry, to `hiddenPasswordsProvider`, through the source the Spaces sheet uses; the scheduler's run of each space maps its entries to their collections and reports each verified chain; a chain read by the sheet alone hides an entry of unknown collection when every collection of the account hides passwords. It fails closed: the reports live in memory, and the list of server spaces is only known after a network call, so a login with a `spaceId` that is not a WebDAV space of the vault's settings stays hidden until its space reports a chain whose grant for this account shows passwords; the breach check never sends a hidden password's hash prefix.)
- [x] 5.6 Leave (blocked for the only Owner), revoke, and remove, with the list of what the member could open. Verify fake-server tests that the leaver's devices drop the space's entries and that admins see "Keys need replacing". (Code and test done; verify after merge. Leave, blocked for the only Owner, revoke, and remove with the list of what the member could open are each a `remove` naming the keys the member held, which admins then see as "Keys need replacing" and replace through the sheet. The fake-server test in `server_spaces_test.dart` has a member leave from one of two phones: both phones then drop the space's entries at their next run, the Owner's row reads "Keys need replacing", and the Owner's phone replaces the keys, sealing them to nobody who left.)

### 6. Replacing keys

- [x] 6.1 Build the key replacement run of design decision 4: new keys, seals to the remaining members, the `keys` entry, re-encryption in batches of 500 with `If-Match`, merging on 409, resuming from the items still under an old version, the space's manifest signed after the last batch, and the read-back check. Verify three fake-server tests: a concurrent edit ends merged under the new key; a run stopped after two batches resumes; the removed member's key opens nothing written afterwards. (Code done; verify after merge. `buildKeysRecord` in `space_replace.dart` makes the `keys` record, its boxes and, for a new space key, the names sealed again; `KmSpaceSync.replaceKeys` in `server_spaces.dart` publishes it, re-wraps the accepted, listed items of the replaced collections from the cache's plaintext under fresh item keys, saves after each batch, merges on a 409 by reading the space again, signs the manifest and reads back. Items it didn't accept are named held, as the spec's "Using the state" says. `buildRekey` is a member's own key-pair replacement, not this record. The append route is the server's: a 409 makes the run read the chain again and rebuild the record.)
- [x] 6.2 Never write under a replaced key version: an offline phone fetches the new key, merges and re-encrypts. Verify a fake-server test with a phone offline across a replacement. (Code and test done; verify after merge, in `server_spaces_test.dart`. The fake server refuses a write under an old key version with a 409, as the server does, and the phone that was offline reads the chain to its head, opens the new keys through it, merges its edit with the rest and writes once, under the new version.)
- [x] 6.3 After a member's new key pair, seal their keys again only once they are confirmed again. Verify a fake-server test. (Code done; verify after merge. The spec decides it: a `rekey` is vouched for by the old key, so the chain entitles the new bundle and `SpaceActions.shareKeys` seals the keys to it as soon as the record is on the chain, never to a key the chain doesn't record; it can't be confirmed again as the task said, since a `confirm` of a member who is confirmed needs a newer bundle than the recorded one. The test is in `test/features/spaces/space_actions_test.dart`, against a chain in memory.)

### 7. Policies

- [x] 7.1 Read policies from the chain only, and hand Require SSO to sign-in for Members (not Owners or Admins). Verify tests that a policy the server flipped is ignored, and that sign-in offers a Member SSO alone. (Code and tests done; verify after merge. `SpacePolicies` (`space_policies.dart`, held by `spacePoliciesProvider`) keeps the policy set of each verified chain of a compared space that a run or a read of the Spaces sheet reports through `onComparedChain`, only while the chain shows the account a confirmed member (an accepted invitation is kept for one space per member alone), and is emptied when the vault locks, unlocks or another vault opens, not when a password change or a key replacement installs a new session. Nothing the server says beside the chain is read: the list of spaces carries no policy here, and the setup sheet no longer reads the `ssoRequired` flag among the ways in. `requiresSso` holds for a Member (a Custom member too) of a space with Require SSO on, never for its Owner or an Admin; the sheet then offers SSO alone, as it does after the server's 403 `sso-required` once the person has proved who they are. A new phone holds no chain before it signs in, so there only the 403 sends the person to SSO. Tests: `space_policies_test.dart`, `space_policies_server_test.dart` (a server that flips a policy in its list), `kemlock_setup_test.dart`.)
- [x] 7.2 Account recovery: the notice on joining and when it is turned on, Agree or leave, and sealing the root only to the chain's recovery key, under the `"account-recovery"` context. Verify tests that nothing is sealed before Agree, and that a recovery key outside the chain is refused. (Code and tests done; verify after merge. The notice before Accept on an invitation was 5.3's. The space's details now show a recovery notice, with Agree and Leave the space, to a confirmed member of a space whose verified chain has account recovery on (`space_notices.dart`). `sealRecoveryEnrolment` (`space_recovery.dart`) seals the 64-byte root key in the sealed box under `"account-recovery"`, only to the chain's own recovery key, and refuses before sealing anything when the member hasn't agreed, the device has done no first contact, the chain doesn't show the account confirmed, recovery is off or no key is recorded, or the key offered differs from the chain's. The box is bound by the `aad` Kemlock Server pinned (2026-11-22): `space id (16) || account id (16) || u64be(seq of the chain record that set the recovery key)` (`recoveryAad`), and the enrolment gives that `keySeq` with the box. Every confirmed member may enrol, Owners included (the server's rule; an Admin can't recover an Owner). Left open until the server merges it: `PUT /kem/v1/spaces/{id}/members/me/recovery` `{box, keySeq}` (409 `stale-recovery-key`; `DELETE` withdraws) and the vector of the box in docs/crypto.md; until then the sheet's Agree is not wired (`ServerSpaceSheet.agreeRecovery`); Leave is. Tests: `space_recovery_test.dart` (real keys), `space_notices_test.dart`.)
- [x] 7.3 Show the duplicate-matching notice once, and keep it in the space's details. Verify a widget test. (Code and tests done; verify after merge. `MatchingNoticeSection` (`space_notices.dart`) in the space's details, for a confirmed member of a space whose verified chain has `duplicateMatching` on: what the server can learn, shown as a notice with "Got it" the first time and as plain text after. Once is remembered in the vault's Kemlock settings (`matchingSeen`, under `chain:<space>:duplicateMatching`) by the `seq` of the `policies` record that turned the flag on (`SpaceState.flagSince`), so off and on again is a new notice. Left open: it shows when the member opens the space's details, not when the app opens, and the duplicate cleaner's own notices (`kemlockMatchingNoticesProvider`) still follow the server's settings. Tests: `space_notices_test.dart`, `space_policies_test.dart`.)
- [x] 7.4 Enforce no export of space items, one space per member, and the minimum master password length. Verify tests on the export sheet, the invitation screen and the change-password sheet. (Code and tests done; verify after merge. Export: `blockedExportSpacesProvider` names the spaces whose verified chain has `disableExport`, and the Credential Exchange plan checks it before the blanket server-space rule so the sheet names the space; the rest of a server space's items still stay out of Credential Exchange (the owner's earlier decision). The encrypted and plain file exports and the QR sheet had no space rule and put every item in the file; they now go through `space_export.dart`, which leaves out a forbidding space's items (named on the sheet) and, failing closed, a server space's items while its policy is not known (with a line saying to sync and export again). A policy is known from the chain read since the vault opened or, when none was (offline, the server down, just after unlock), from the last compared chain's, which the vault remembers: `disableExport`, the chain's epoch and head seq and when, in the `exportPolicies` member of the sealed anchors value (`RememberedExportPolicy`, a top-level member beside `anchors`, optional, so it is carried to the account's other phones by the anchors item; each space's entry is unchanged because a build from before reads an entry strictly, and no released format changes). A chain read since the vault opened always wins over it, in either direction; a space with no remembered policy stays unknown and left out, and an encrypted backup or QR that left such items out says it is partial and is not recorded as a backup in Vault health. A chain that does not show the account confirmed is remembered as forbidding export. One space per member: the accept sheet offers no Accept and names the space to leave first when the account is a confirmed member of another space that allows one, or the space to join allows one while it is in another; only spaces whose chain was read are known, and the Spaces list reads them all before an invitation opens. Minimum length: the change-password sheet and the unlock method's new-password sheet refuse a password under a space's `masterPassword.minLength`, naming it; the other master password requirements the policy carries are not applied, and the recovery kit unlock and new-vault forms are not either. Tests: `space_export_test.dart`, `space_head_store_test.dart`, `remembered_export_policies_test.dart`, `credential_export_test.dart`, `hidden_passwords_export_test.dart`, `accept_space_test.dart`, `space_policies_test.dart`, `change_password_sheet_test.dart`.)

### 8. Moving a WebDAV space

- [x] 8.1 Add "Move to Kemlock Server" to a WebDAV space: create the server space under its legacy-id UUID, upload every entry to "Everyone" under its own or legacy-id UUID, sign the manifest, then read back and compare (design decision 7). Verify a test against the fake server and fake WebDAV that 40 entries arrive with their own ids inside, and that a mismatch keeps the space on WebDAV. (Code and tests done; verify after merge. `KmServerSpaces.moveSpace` makes the space under `serverSpaceUuid` of the WebDAV id (`create` as `records[0]`), runs the space's own sync over the entries rescoped to the server's id (each keeps its own id inside; an older id takes its legacy-id UUID under the space), then `KmSpaceSync.compareMoved` reads the space back and compares, under the ids that were sent, the hash of each entry of the document the run merged (the server may already hold other copies; the sheet applies that document to the vault),  and its listing in the signed manifest, and `markBridge` writes the marker that the move is whole. `moveWebDavSpace` marks the space `moving` before anything goes up and `bridged` only after the read-back, so a mismatch or a stop leaves it a WebDAV space that syncs the file alone and the move runs again; the server space it made is filled again, not made twice. The state is a note under the space's settings entry (`space_bridge.dart`), never in the file or an invite. The tests are `space_move_test.dart`, and `hidden_passwords_moved_test.dart` for the logins: a moved space's logins are a server space's (hidden until its chain is read, then by its grants, and out of exports) and a half-done move's are still a WebDAV space's.)
- [x] 8.2 Build the bridge: moved members' apps sync the WebDAV file as a second target of the scope, both ways, writing it as today's sync does. Verify a test that an edit made by the frozen merge in `test/compat/before_vault_items` (an older phone) reaches the server space, and the reverse. (Code and tests done; verify after merge. `runBridged` (`space_bridge_run.dart`) runs the server space, then the file through `runWebDavScope`, the code of today's WebDAV run, then the server space again only if the file brought something new. The later change wins on both sides, a login's passwords are kept and a deletion beats an older copy, as `mergeScope` decides everywhere; a failure of one side leaves the other syncing and is shown as the scope's problem. The tests are `space_bridge_test.dart`, with the frozen merge as the older phone.)
- [x] 8.3 A joining member finds its WebDAV copy by id, is asked, merges it once, and stops writing the file. Verify a fake-server test. (Code and tests done; verify after merge. Joining on the server's word alone was a hole: the UUID is computable by anyone who can list the folder. The scheduler lists the server spaces once per run and, for a WebDAV space with no note whose UUID is listed with the account confirmed, only asks `joinOffer`: it answers an offer, naming the Owner, when an anchor for that chain is already stored with the record that a fingerprint was compared (`KmSpaceSync.joining` reads the chain against it and never makes one; an anchor without the record is refused, `loadCompared`), the account is confirmed and the move marker is there. The space is then `offered`, and still syncs the file alone. Only the person's agreement in the Spaces sheet makes it `joining`, which counts as a server space for hidden passwords and exports from that moment; the next run merges the file in through `runBridged` with `writeFile: false` and marks it `joined` only on `BridgeSignal.open` or `closed` (`pending` when the marker is missing: nothing is merged or uploaded). A "not a member" answer deletes nothing and leaves a joining space joining. A noted change is applied only to the note the run started from, and a space whose move runs on this phone is skipped (`SyncNotifier.isMoving`). The server space list hides only spaces whose note says they are on the server, so an invitee can accept on the phone that holds the file. The tests are `space_join_test.dart`, `space_move_sheet_test.dart` and `hidden_passwords_moved_test.dart`; `km_space_scheduler_test.dart` is back to leaving a UUID-shaped WebDAV id to its WebDAV scope.)
- [x] 8.4 Close the WebDAV copy, by the Owner or on its own after a removal, key replacement or restriction, with the warning and the offer to delete the file. Verify tests that no moved app reads or writes the file afterwards. (Code and tests done; verify after merge. The chain closes the copy on every phone at once (`chainClosure`, no marker): when any member was removed or left, marked keys or not; when keys were replaced; when the space has more than one collection; or when a grant hides passwords. The Owner's close writes one item of kind `space-bridge-closed` into the space, whose kind and existence every phone reads on its next run, and an item ever seen at its id closes the copy, deleted or not; the chain has no kind or policy for it and no route is invented, so the kind is marked `server: to confirm` like `space-anchors`, and any member who may edit "Everyone" can write one, which can stop the bridge and never carry anything. A closed run reads and writes no file; a run that fails after its chain showed a closure carries it in a `ClosedRunError` and closes the copy all the same; a server failure with no closure reads the file and never writes it. The Spaces sheet gives the warning and offers to delete the file, and the app never deletes it; the server space sheet warns before a grant that hides passwords on a space whose copy is open (the app has no screen that makes a second collection yet). The tests are `space_close_test.dart`, `space_closure_test.dart`, `space_bridge_test.dart`, `space_sheet_test.dart` and `space_move_sheet_test.dart`.)
- [x] 8.5 Check that the WebDAV space files and `bmc-space:` invites are unchanged. Verify two things: every case in `mobile/test/fixtures/sync/sync.json` still opens; and a file written by a bridged sync, with a single-collection space's entries, equals the file today's sync writes for the same entries; a space with a second collection closes the bridge instead. (Tests done; verify after merge, in `space_files_unchanged_test.dart`. No file or fixture was changed. The bridged file holds only a single-collection space's entries: a restricted collection's items and hidden passwords never reach it. A bridged, joining or joined space offers no `bmc-space:` invite.)

### 9. Strings and checks

- [x] 9.1 Add every new string to the app's message files, `mobile/assets/i18n/en.json` and `fr.json` (`mobile/lib/i18n/messages.dart` only loads them), in each shipped language. Verify the i18n completeness test passes. (Checked after the merge; verify the run in 9.2. Both files have the same 3315 ids, every id the code names through `t(...)`, `id:` or `...Id:` is in both, and the space screens' helper-named ids (`_title(context, 'space.keys.title')`), which the scanner missed, are now held to both by `messages_test.dart`. The new messages use `select`, never `plural`, so `plurals.json` is unchanged.)
- [ ] 9.2 After merging, the main session runs `flutter analyze` and the whole Flutter suite once, on the owner's machine. Verify both pass, and record the result in this plan.
- [ ] 9.3 With `kemlock-server` running, the owner uses two phones in one space: make, join, confirm, edit, remove and replace keys. Then one phone moves a WebDAV space while the other stays on WebDAV. Record what passed in this plan.

## Agreed with the server

`crypto.md` settles the sealed box and its `"space-key"`, `"collection-key"` and `"account-recovery"`
contexts, `sig1`, the bundle and fingerprint, and legacy ids. The kemlock-server session must settle:

- the chain of design decision 2 is settled by the server's "Space chain" section (version 2), which this plan follows; what is left is its vectors, `test-vectors/space-chain.json`, and the routes it lists (the chain, `?from=`, the seal hashes of a record, and the append route);
- the `aad` layouts of the space-key and collection-key seals and the `kem1` names are confirmed (design decision 3);
- a collection key as the parent of `item-wrap` for its items, and the collection id as item metadata
  on the wire (design decision 3);
- the space manifest: who may sign, that it lists every item, and that the server sends every space
  item's envelope to every confirmed member (design decision 4a);
- whether an item whose id is a UUID may change owner in one write (vault to space), or must be
  deleted and created as a legacy-id item is;
- the routes for spaces, members, chain entries, sealed keys and the space manifest, in its OpenAPI
  spec;
- the anchors of the account's server spaces as one more item kind, `space-anchors`: an item owned by the user, its id the legacy-id UUID of `space-anchors` under that owner, holding the anchors JSON (`{"v": 2, "anchors": {<space uuid>: {"epoch", "links"}}}`), which the account's devices merge with `SpaceAnchors.mergedWith` (marked `// server: to confirm` in `km_kinds.dart`; the server only needs the kind in its list, and sees an item it can't read). A vault that syncs with WebDAV carries the same value in the personal sync file's `extra`, under `spaceAnchors`, which older builds pass through, and the merge keeps the union of both sides' anchors for that key alone;
- the markers of a moved space's WebDAV copy, two items owned by the space and read by their existence alone: `space-bridge`, written once by the mover's app when its read-back matched, and `space-bridge-closed`, written once by the Owner's app to close the copy, each with the legacy-id UUID of its name (`space-bridge`, `space-bridge-closed`) under the space as its item id and a small JSON of its own inside (marked `// server: to confirm` in `km_kinds.dart`; the server only needs the kinds in its list). A removal and a key replacement close the copy from the chain itself, with no marker;
- vectors for each of the above, which this plan's tests then read.

### What the server's code settled

The server's code (`kemlock-server`, `build/vertical-slice`, 2026-11-22) differs from this design in these places, and where it pins a format the app follows it:

- **Roles.** Owner, Admin, **Custom** and Member, with the Custom permissions `manage-users`, `manage-groups` and `create-collections`. The design named three roles; the chain's rules are the server's (`kemlock-domain`'s `spaces.rs`). Owners and admins read and write a collection's items only through a grant, as anyone does.
- **Member confirmation.** crypto.md "Member confirmation" pins a 134-byte statement, signed by the confirmer under the sig1 context `"confirm"`, kept by the server beside the member and checked again by every client (`confirm.dart`). The chain's `confirm` entry carries that statement and signature, and the member's own bundle and its self-signature.
- **Collections and groups.** The server has both, so the chain has `collection` and `group` entries beyond the design's list, and grants name a member or a group.
- **The collection id** is a field of the wire item beside `owner` (`collectionId`), as the design said; it is no part of the `kem1` envelope.
- **The space manifest** is signed by a member with edit on at least one collection, through a grant, not by any Owner or Admin. The route is the server's pending one: PUT and GET `/kem/v1/manifests/space:<id>`, 423 while the space waits for new keys, GET for any confirmed member and 404 for a stranger, counters per owner.
- **The sync cursor** is one vector per owner and grows with the spaces, so a long one goes in a `POST /kem/v1/sync` body `{since, limit}`. The server names no feature for the route yet, so the client chooses by the cursor's length and falls back to the GET.

What the server lacks and the app builds behind fakes, each marked `// server: to confirm`: the chain's vectors, the name of the sync field that marks a held item (`held`), a collection key as the parent of `item-wrap`, the text of a fingerprint's QR code, and the space manifest route. The context `"space-chain"`, the seal `aad` layouts and the names are settled.

One point is still the owner's, with a seam marked `// owner: to decide`: what happens past the chain's size limit (refused beyond the spec's limits). Where trust anchors live is decided: they sync through the personal vault (design 2, point 1). Member changes made outside Kemlock clients are decided too: they are queued for an Admin's app to sign (design 2, point 3), and the server has named its routes (`GET /pending`, `POST` and `DELETE /pending/{n}`), which the client and the fake server follow.

Left open by moving a WebDAV space (tasks 8.1 to 8.5), none of which needed a server route the server lacks:

- **Who bridges.** Only the phone that moved the space syncs the file with it (`bridged`). Another phone of the account, or a member who finds the space by its WebDAV id, merges the file in once and writes it no more (`joined`), as task 8.3 says. If the phone that moved stops syncing, the file stops being carried until the Owner closes it or moves again.
- **A collection other than "Everyone" in the bridged file.** The bridge writes the server space's entries to the file as today's sync writes them, which is what task 8.5 checks, and everyone holding the file's key can read it. Once the Owner restricts a collection, its items go into the file too; the Owner should close the copy first. The move screen's body says the copy is as weak as today's spaces.
- **Attached files.** A note's attached files stay in the WebDAV folder through the file sync, as they do today; the server space carries none of them yet, so a moved note's files reach only the phones that read the folder.
- **Who may close.** The chain closes the copy after a removal or a key replacement for everyone and cannot be forged. The Owner's own close is one marker item that any member with edit on "Everyone" could also write; it can stop a bridge, never carry anything into one.

## Dependencies

- `docs/plans/add-account-crypto.md`: the `kx1` and `sig1` keys and bundle, the fingerprint and
  `FingerprintView`, item keys and their AAD, the sealed box, legacy ids, and the manifest rule.
  Required first.
- `docs/plans/add-kemlock-server-sync.md`: the client, DPoP tokens, the sync cursor, `items:batch` with
  `If-Match`, the per-item field merge, the server list, failover, and promotion records. Required
  first.
- `docs/plans/add-duplicate-cleaner.md`: server matching (this plan only shows its notice), and
  re-tagging after a key replacement.
- `docs/plans/move-off-vaultwarden-sync.md`: the personal vault's move, which this plan's WebDAV space
  move sits beside; it uses the same rule of keeping ids and checking a read-back.
- `docs/plans/add-cards-identities-and-websites.md`: card and identity items, which space items can be
  once that plan lands; nothing here waits on it.
- `docs/plans/add-credential-exchange.md`: imports into a space go through this plan's keys; no task
  here waits on it.
- `kemlock-server` (`../kemlock-server`): `crypto.md`, its OpenAPI spec for the `/kem/v1/spaces/…`
  routes, and the shared vectors this plan's tests read.
