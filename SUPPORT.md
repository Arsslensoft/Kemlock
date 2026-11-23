# Getting help with Kemlock

## Using the app

- The [README](README.md) says what Kemlock does, how its vault and formats work, and how to import
  from other apps and sync.
- [`mobile/README.md`](mobile/README.md) covers building and running the app.
- [`docs/reproducible-builds.md`](docs/reproducible-builds.md) says how to check that a release was
  built from its source.

## A bug, or an idea

Search the [issues](https://github.com/Arsslensoft/Kemlock/issues), then open one with the
[bug report or feature request form](https://github.com/Arsslensoft/Kemlock/issues/new/choose). If you
have a question the README doesn't answer, open an issue with the `question` label. Kemlock is kept by
one maintainer in their own time, so answers can take a few days.

Please don't paste a master password, a recovery key, a vault file, an export or an OTP secret
anywhere, in an issue or otherwise. Nobody who helps you will ever need one.

## A security problem

Don't open an issue. Follow the [security policy](.github/SECURITY.md): a private report through a
GitHub security advisory.

## Other repositories

- The sync server: [Kemlock-Server](https://github.com/Arsslensoft/Kemlock-Server).
- The browser extension: [Kemlock-browser](https://github.com/Arsslensoft/Kemlock-browser).

## Lost access to a vault

A vault is sealed with its master password, and Kemlock can't open it without it. Only a Recovery Kit
made earlier, or an export or a sync copy you kept, can bring it back. No one, including the maintainer,
can open it for you.
