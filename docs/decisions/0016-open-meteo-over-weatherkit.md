# 0016 — Open-Meteo over WeatherKit

**Status:** Accepted · **Date:** 2026-09-15

## Context

The Weather widget needs current conditions and a daily high/low. WeatherKit is
Apple's first-party framework and the obvious native choice.

## Decision

Open-Meteo (`api.open-meteo.com`), called only while the Home tab is open, with
coordinates rounded before they leave the process.

## Why

**WeatherKit would make the repository un-buildable by anyone who clones it.**
It requires a paid Apple Developer Program membership, a registered App ID with
the WeatherKit capability enabled, and a build signed by that team. A contributor
without a paid account could not compile the project at all. For one widget,
that is a disproportionate barrier — and it conflicts directly with
[ADR 0005](0005-swiftpm-over-xcode-project.md), which exists to keep the build
requirements minimal.

WeatherKit also bills beyond a monthly call quota, which is a strange property
for an open-source utility to have.

**Open-Meteo needs no key and no account**, so the feature works on a fresh
clone with no setup.

## The privacy cost, and what we do about it

This is a third-party service, and that is a real cost that has to be paid down
rather than waved away:

- **Coordinates are rounded to two decimal places (~1.1 km)** *before* they
  leave the process. A temperature reading does not need street-level precision,
  and rounding means the request cannot be used to locate a user's home.
- **The request only happens while the Home tab is open**, with a 15-minute
  cache so re-opening the tab does not re-hit the network.
- **Nothing identifying is sent** — no identifier, no account, no custom
  user-agent.
- **Reverse-geocoding for the display name is done locally** via `CLGeocoder`,
  and the resulting place name is never sent to the weather API.
- **Location is optional.** Without permission the widget shows a "set a
  location" affordance rather than nagging.
- Settings → About states plainly that this is one of only two things that
  leave the machine.

## Costs we accepted

- A third-party dependency at runtime (not at build time), with its own uptime
  and terms.
- Less accurate than WeatherKit in some regions.
- WMO weather codes have to be mapped to SF Symbols by hand, grouped rather than
  exhaustive — the distinction between "slight" and "moderate" drizzle does not
  change which icon a person wants.

## Revisit if

The app ever ships under a paid developer account with a real Developer ID
(needed for notarised distribution anyway). At that point WeatherKit becomes
viable and strictly better on privacy, and the swap is contained to
`WeatherService`. Worth doing then.
