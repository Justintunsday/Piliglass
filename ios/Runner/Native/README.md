# Runner native boundaries

The app currently supports iOS 16 and Swift 5 language mode. Flutter remains
available until each business domain has a verified native replacement.
See `docs/native-migration/PLAN.md` for cutover and removal gates.

- `Bridge`: Flutter hosting, codec conversion and temporary Dart adapters.
  New domain and feature code must depend on repository contracts rather than
  import Flutter. Player surface containment remains owned by the root host.
- `Player/Diagnostics`: Runner's Aether log capture and diagnostic export.
- `Player/IO`: Runner's configured CDN byte readers. Aether's `IOReader` callbacks
  execute synchronously on its demux thread; do not call them from UI or an async
  cooperative executor. Preserve seek, cancellation and close semantics.

Add Features, Domain, Data, Networking, Persistence and DesignSystem components
as their responsibilities are extracted. Do not create an all-purpose manager
or move Bilibili APIs into `Packages/AetherEngine`.
