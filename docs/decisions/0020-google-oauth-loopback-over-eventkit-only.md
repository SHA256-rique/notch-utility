# 0020 — Direct Google OAuth, not EventKit alone

**Status:** Accepted · **Date:** 2026-09-15

## Context

The Calendar tab read events through EventKit. EventKit surfaces whatever
calendar accounts macOS knows about, including Google accounts the user has
added in System Settings.

The obvious position is therefore: we already support Google, via the system.

## Decision

Talk to the Google Calendar API directly, with OAuth for installed apps, as an
*addition* to EventKit rather than a replacement. Both sources can be on at
once and their events merge into one list.

## Why

**"Add the account in System Settings" is a fine answer for people who already
have, and no answer at all for anyone else.** It means leaving the app, adding a
system-wide account, and — this is the part that matters — granting macOS access
to the user's mail and contacts as a side effect of wanting to see meetings in
a notch. A macOS Google account is not scoped to calendars.

**The direct grant is exactly as wide as the feature.**
`calendar.readonly`, nothing else. Revoking it is one click in the Google
account page, and it leaves no trace on the system.

## The flow, and why each part of it

**System browser, not an embedded web view.** An embedded view can see the
user's Google password. Even if it does not look, the user has no way to verify
that — and Google blocks embedded user-agents for precisely this reason. The
system browser also reuses an existing Google session, so most sign-ins are two
clicks.

**Loopback redirect, not out-of-band.** Google retired the
`urn:ietf:wg:oauth:2.0:oob` paste-a-code flow and does not permit the implicit
flow for new clients. Loopback is the supported path for native apps, and Google
allows *any* port — which is what lets this use an ephemeral one instead of
squatting on a fixed port that might already be in use.

**PKCE, and it is what actually secures this.** A "client secret" shipped inside
a desktop app is not a secret; anyone can read it out of the binary, and Google
documents installed-app secrets as non-confidential. The verifier never leaves
the process, so a malicious local app that races us to the loopback port still
cannot exchange the code it intercepted. The `state` parameter covers the other
direction — an attacker's code being planted into our session.

**`access_type=offline` with `prompt=consent`.** Without both, Google issues a
refresh token only on the very first authorisation ever. A user who revokes and
re-links would get an access token that expires in an hour and never comes back
— a bug that only appears on the second sign-in, which is the worst possible
time to find it.

**The listener answers one request and shuts down.** It is bound to 127.0.0.1
only, not to every interface, and it is not a web server: anything it does not
recognise gets a 400 and is forgotten.

## Merging, and why we do not deduplicate

The same meeting can legitimately exist in two accounts with different titles.
Fuzzy title-and-time matching would sometimes hide a real second event, which is
a worse failure than showing one twice — so both are shown, with a small source
badge to explain why.

## Costs we accepted

- The user must create their own OAuth client in Google Cloud Console. There is
  no alternative for an unsigned open-source app: a shipped client ID would be
  extracted and abused, and Google's verification process requires a registered
  organisation and a privacy policy.
- A second code path for what looks like one feature. Contained by
  `CalendarEvent`, which is the only type either view sees.
- `Network` and `CryptoKit` are now linked. Both are system frameworks, so
  [ADR 0004](0004-zero-dependencies.md) is unaffected.

## Revisit if

The app ships under a verified developer account. A bundled client ID would then
be viable and would remove the only setup step this feature has.
