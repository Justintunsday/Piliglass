# SwiftgramUI provenance

This module is adapted from the native messaging UI in
[Swiftgram/Telegram-iOS](https://github.com/Swiftgram/Telegram-iOS), revision
`cf8b23b` (retrieved 2026-08-25), especially:

- `submodules/ChatListUI/Sources/Node/ChatListItem.swift`
- `submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift`
- `submodules/TelegramUI/Components/Chat/ChatInputPanelNode/Sources/ChatInputPanelNode.swift`

The original components require Telegram-specific modules such as
`AccountContext`, `Postbox`, `TelegramCore`, `AsyncDisplayKit`, and the Bazel
build graph. This extraction retains their native layout behavior while
accepting application-provided content so PiliGlass can supply Bilibili data.

Telegram for iOS is licensed under GNU GPL version 2 or later. This adapted
module is distributed under GNU GPL version 2 or later and is incorporated in
PiliGlass under GNU GPL version 3. Copyright remains with the original
Swiftgram, Telegram-iOS, and other respective contributors.
