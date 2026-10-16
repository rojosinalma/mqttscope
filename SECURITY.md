# Security policy

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/rojosinalma/mqttscope/security/advisories/new)
(the *Security* tab → *Report a vulnerability*). Do not open a public issue. You will get an
acknowledgement within a week and a fix or a statement before any public disclosure.

## Supported versions

Only the latest release receives fixes. Upgrade `ghcr.io/rojosinalma/mqttscope` to the newest
`vX.Y.Z` tag before reporting.

## What the app holds

mqttscope connects to your broker with the credentials you give it and stores a week of every
message it sees. What that means for a deployment, and how to run it safely, is in
[`docs/security.md`](docs/security.md). In short:

1. Broker credentials live in the settings database; they are never logged and the password is
   never returned by the API.
2. There is no built-in authentication. Everything the broker user can read is visible to anyone
   who can reach the port, so bind it to a trusted network or put it behind an authenticating
   reverse proxy.
3. Publishing is off by default (`publish_enabled`); when on, anyone who reaches the UI can publish
   as the broker user.
4. The container runs as a non-root user, needs no capabilities and no Docker socket. Mount only
   the `/app/data` volume.
