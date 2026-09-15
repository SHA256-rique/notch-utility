# 0019 — Claude usage from local transcripts, not an API

**Status:** Accepted · **Date:** 2026-09-15

## Context

The Claude usage widget needs a token count, a day streak and a weekly chart.

## Decision

Parse `~/.claude/projects/**/*.jsonl` — the transcripts Claude Code already
writes — and aggregate the `usage` objects they contain.

## Why

**There is no usage API that would work here.** The Anthropic API reports usage
for an API key's own traffic; Claude Code subscriptions are not that, and asking
a user to paste an API key so the app can report on work they did with a
*different* credential would be both confusing and wrong.

**It is local, which is the whole premise of this app.** No key, no account
link, no network call. Settings → About lists exactly two things that leave the
Mac, and this does not become a third.

**It is honest.** These are the tokens actually consumed by work done on this
machine, not an estimate derived from message counts or session durations.

**It costs nothing when nobody is looking**, like every other widget here — a
hub registration torn down when the tab closes.

## The implementation decisions that matter

**Line-oriented scanning, not `JSONDecoder`.** A busy month is tens of megabytes
across hundreds of files, and each line is a large object of which we want four
integers and a date. Decoding every line into a Codable model allocates the
entire conversation history in order to throw it away. Scanning for the
`"usage":{...}` fragment and parsing only that is the difference between ~40ms
and several seconds on a real `~/.claude`.

**A brace-balanced extractor, not "scan to the first `}`".** Claude Code nests a
`server_tool_use` object inside `usage`. The naive scan truncates there and
every parse fails — silently, producing a widget that reads zero.

**Cached per file against (size, mtime).** Transcripts are append-only and old
ones never change, so a rescan only re-reads files that grew. Opening the Home
tab repeatedly does not re-walk the disk.

**Days are keyed in the user's local calendar**, not UTC. A streak is a human
concept; bucketing by UTC would end someone's day mid-afternoon.

**Cache reads are excluded from the headline.** They are real tokens, but they
are cheap and enormous — including them makes every other number invisible. The
detail view shows all four counters broken out, and says why.

## Costs we accepted

- **This is a private file format.** It is not an interface, and Anthropic can
  change it. The failure mode is graceful — a widget that reports zero or shows
  "no transcripts found" — and the fix is contained to one parser. The same
  reasoning as `ApprovalPatterns`: prefer the stable transport where one exists,
  accept a fragile one where it does not, and isolate it so repair is cheap.
- Usage from claude.ai or from the API directly is not counted. The widget is
  explicitly about work done on this Mac.
- A user who has never run Claude Code sees an empty-state message rather than a
  widget. Better than a zero that looks like a bug.

## Revisit if

A first-party local usage file or a subscription usage endpoint appears. Either
would be a strictly better source and the swap is contained to
`ClaudeUsageReader`.
