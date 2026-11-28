# Fix live sync and first-response latency

## Why

Three measured behaviours make Palace feel wrong on a release build even though
nothing crashes:

1. A terminal that was already running when Palette relaunched keeps the
   previous palette until the user applies again. The palette files on disk are
   correct; nothing pushes them to the live terminal at launch.
2. The first open of the wallpaper deck decodes fifteen 4K–8K pictures
   serially, taking about 2.0 s before every card has its picture. Cards show
   their palette colour meanwhile, but the hand is visibly incomplete.
3. The first `/bw` of every launch waits ~650 ms for `bw status`, and a cold
   `/gh` waits ~1.1 s because the PR and issue calls run one after the other.

## What changes

- Push the current palette to running terminals once, at launch and after a
  launch repair, without rewriting files or restarting anything.
- Decode wallpaper thumbnails concurrently and warm the visible window, so a
  cold deck is complete in well under a second.
- Prewarm the Bitwarden status at launch and run the two GitHub queries in
  parallel.

## Out of scope

- Cold network latency for GitHub itself (the request time, not the sequencing).
- Screen Recording permission (a system grant, not app behaviour).
- Changing the palette files or the restart policy.
