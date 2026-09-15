# 0018 — Named widgets over one generic metric tile

**Status:** Accepted · **Supersedes** the generalisation made during the first build · **Date:** 2026-09-15

## Context

The brief named three Home-grid widgets with specific shapes: Revenue ($ total
over 30 days, % change, paid-customer count), Visitors (live count, % change,
30-day sparkline) and Claude usage (tokens, day streak, weekly bar chart).

The first build collapsed all three into one `customMetric` tile: a URL, a
dot-path into the JSON, and whatever number came back rendered large. The
reasoning at the time was recorded in `MetricFetcher`'s header and was not
unreasonable — no vendor SDK, no OAuth dance, no per-vendor breakage, and it
works for a user's own internal endpoint as well as for a SaaS dashboard.

That reasoning was wrong, and it was also not ours to apply: the generalisation
was made without approval, against an explicit spec.

## Decision

Three named widgets with fixed shapes and configurable *sources*. The generic
`customMetric` tile stays, as an opt-in extra rather than as the thing the
named widgets are made of.

## Why the generalisation was wrong

**A tile that renders whatever the endpoint returned cannot know what it is
showing.** It cannot know that a customer count is a count and should not be
abbreviated to "1.2k" at three digits. It cannot know that thirty daily numbers
want a sparkline rather than a single figure. It cannot know that a streak
resets at a gap, that revenue has a previous period worth comparing against, or
that cache-read tokens should be excluded from a headline because they would
swamp it. Every one of those is a judgement about the *meaning* of the data,
and a generic tile has none.

**The result was a debugging tool, not a dashboard.** "Point this at a JSON
endpoint" is a developer affordance. The widgets in the brief were for someone
glancing at a notch between tasks.

**The configuration burden did not go away, it moved.** A generic tile still
needs a URL, headers and a path — the user does all the same work and gets a
worse result. The named widgets ask for less: Revenue needs one key, Visitors
needs a URL and a preset name.

## The split that works

The *shape* is fixed and literal; only the *source* is configurable.

- **Revenue** is hardcoded to Stripe's Charges API. There is one dominant
  payments API and pretending otherwise helps nobody. The endpoint is
  overridable so a user can put a proxy in front of it rather than keeping a
  live key on a laptop.
- **Visitors** has a configurable endpoint with four dot-paths, because there
  genuinely is no universal visitors API — Plausible, Umami, Fathom, GoatCounter
  and a hand-rolled ClickHouse query all answer the same question differently.
  Presets fill the paths in for the common tools, so for most users
  configuration is picking a name from a menu. The widget itself is still
  literal: it always renders a count, a change and thirty daily points.
- **Claude usage** has no configuration at all. See
  [ADR 0019](0019-claude-usage-from-local-transcripts.md).

## Costs we accepted

- Stripe's API shape is now something this codebase knows about, and Stripe can
  change it. Mitigated by pinning `Stripe-Version`, so a breaking change is a
  decision we make rather than one that arrives on a Tuesday.
- Three services instead of one, each with its own polling registration —
  though each still goes through the one hub, so the idle cost is unchanged.
- Someone whose payments run through Paddle or Lemon Squeezy gets no Revenue
  tile and has to use the generic metric tile instead. Acceptable: they are a
  minority, and the generic tile still exists for exactly this case.

## Revisit if

A second payments provider is requested often enough to justify a `RevenueSource`
protocol. The shape of the widget would not change — which is the point of
having fixed it.
