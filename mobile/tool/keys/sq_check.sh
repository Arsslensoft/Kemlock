#!/bin/sh
# Runs the keys tool/keys/write_edited_keys.dart changed through Sequoia
# `sq` (openspec: add-pgp-key-editing, task 3.6): each changed public key
# imported alone and inspected and linted, and each revocation certificate
# Kemlock made imported over the key's original public key, which must
# then show as revoked. test/fixtures/keys/other/editing/sq-check.txt is
# one run's output.
#
# No sq is at hand on the machines Kemlock is built on, so it runs in
# Alpine Linux, which packages it. From mobile/, in Git Bash:
#
#   dart run tool/keys/write_edited_keys.dart <dir>/edited
#   MSYS_NO_PATHCONV=1 docker run --rm -v "<dir>:/in:ro" -v "$PWD/tool/keys:/script:ro" \
#     alpine:latest sh /script/sq_check.sh

apk add --no-cache sequoia-sq >/dev/null 2>&1
sq version 2>&1 | head -1
cd /in/edited
for key in signing-subkey rsa3072-expiring protected direct-key; do
  for file in $key.*.public.asc; do
    change=${file#$key.}; change=${change%.public.asc}
    [ "$change" = original ] && continue
    echo "== $key, $change"
    H=$(mktemp -d)
    sq --home $H cert import $file 2>&1 | grep -i "imported\|error\|warn" | head -3
    sq --home $H inspect $file 2>&1 | grep -iE "fingerprint|user ?id|expiration|revoked|revocation|key flags|invalid|error|warning|not (yet )?valid|unusable|subkey" | sed 's/^ *//' 
    sq --home $H cert lint --cert-file $file 2>&1 | tail -2
  done
  echo "== $key, its revocation certificate over the original public key"
  H=$(mktemp -d)
  sq --home $H cert import $key.original.public.asc 2>&1 | tail -1
  sq --home $H cert import $key.rev.asc 2>&1 | grep -v "^$" | tail -3
  f=$(sq --home $H inspect $key.original.public.asc 2>&1 | awk '/Fingerprint/ {print $2; exit}')
  sq --home $H cert export --cert $f > /tmp/merged.asc 2>/dev/null
  sq --home $H inspect /tmp/merged.asc 2>&1 | grep -iE "revoked|revocation|reason|message" | sed 's/^ *//' | head -4
done
