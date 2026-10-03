# Runner native boundaries

The app currently supports iOS 16 and Swift 5 language mode. Flutter remains
available until each business domain has a verified native replacement.
See `docs/native-migration/PLAN.md` for cutover and removal gates.

- `Bridge`: Flutter hosting, codec conversion and temporary Dart adapters.
  New domain and feature code must depend on repository contracts rather than
  import Flutter. Player surface containment remains owned by the root host.
- `DesignSystem`: shared semantic colors, typography, spacing and view chrome.
  Components must not own account, network or playback state.
- `Features/Search`: the search view consumes its main-actor state contract.
  The legacy root supplies that contract during repository migration; feature UI
  must not import Flutter or invoke transport directly.
- `Bridge/Models`: temporary presentation DTOs decoded from the legacy channel.
  Keep dictionary/codec details here until typed domain values replace them.
- `Player/Diagnostics`: Runner's Aether log capture and diagnostic export.
- `Player/IO`: Runner's configured CDN byte readers. Aether's `IOReader` callbacks
  execute synchronously on its demux thread; do not call them from UI or an async
  cooperative executor. Preserve seek, cancellation and close semantics.

Add Domain, Data, Networking and Persistence components
as their responsibilities are extracted. Do not create an all-purpose manager
or move Bilibili APIs into `Packages/AetherEngine`.

`// @native-source Native/...` markers in the original root preserve extraction
order for the temporary single-file preview fixtures. `tool/ios_native_sources.py`
reads the actual production files; the full Runner build checks their independent
compilation and Xcode registration. Retire this extraction approach when feature
fixtures compile those modules directly.
