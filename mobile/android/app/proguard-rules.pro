# Rules for the release build's shrinker, which Flutter turns on for release
# and which reads this file when it is here.

# The OpenPGP API's classes (src/main/java/org/openintents/openpgp). A
# parcelable is written with its class name, and the mail apps read it into
# their own copy of the class: renamed, an error, a signature result or a
# decryption result would arrive as a class they don't have, and an Autocrypt
# update of theirs would not be read here. They keep their names and members.
-keep class org.openintents.openpgp.** { *; }
