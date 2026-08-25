// SPDX-License-Identifier: GPL-2.0-or-later
//
// Source-adapted from Swiftgram/Telegram-iOS revision cf8b23b.
// See ../NOTICE.md for exact upstream paths and attribution.

import SwiftUI
import UIKit

/// Metrics extracted from Swiftgram's chat-list and bubble layout.
public enum SGMessageMetrics {
  public static let chatListAvatarDiameter: CGFloat = 60
  public static let chatListHorizontalInset: CGFloat = 16
  public static let bubbleMaximumWidth: CGFloat = 309
  public static let bubbleCornerRadius: CGFloat = 18
  public static let bubbleMergedCornerRadius: CGFloat = 6
  public static let bubbleEdgeInset: CGFloat = 8
}

public struct SGQuickEmote: Hashable {
  public let token: String
  public let url: URL?

  public init(token: String, url: URL? = nil) {
    self.token = token
    self.url = url
  }
}

/// A reusable chat-list row that keeps the data source outside SwiftgramUI.
public struct SGChatListRow<Avatar: View, Accessory: View>: View {
  private let title: String
  private let subtitle: String
  private let context: String
  private let time: String
  private let isPinned: Bool
  private let titleBadge: String
  private let accentColor: Color
  private let avatar: Avatar
  private let accessory: Accessory

  public init(
    title: String,
    subtitle: String,
    context: String = "",
    time: String,
    isPinned: Bool = false,
    titleBadge: String = "",
    accentColor: Color = .accentColor,
    @ViewBuilder avatar: () -> Avatar,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.subtitle = subtitle
    self.context = context
    self.time = time
    self.isPinned = isPinned
    self.titleBadge = titleBadge
    self.accentColor = accentColor
    self.avatar = avatar()
    self.accessory = accessory()
  }

  public var body: some View {
    HStack(alignment: .center, spacing: 12) {
      avatar
        .frame(
          width: SGMessageMetrics.chatListAvatarDiameter,
          height: SGMessageMetrics.chatListAvatarDiameter
        )

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.primary)
            .lineLimit(1)
          if !titleBadge.isEmpty {
            Text(titleBadge)
              .font(.system(size: 9, weight: .semibold))
              .foregroundColor(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(accentColor)
              .clipShape(Capsule())
          }
          Spacer(minLength: 6)
          Text(time)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        HStack(alignment: .center, spacing: 8) {
          VStack(alignment: .leading, spacing: 3) {
            Text(subtitle)
              .font(.subheadline)
              .foregroundColor(.secondary)
              .lineLimit(context.isEmpty ? 2 : 1)
            if !context.isEmpty {
              Text(context)
                .font(.caption)
                .foregroundColor(Color(UIColor.tertiaryLabel))
                .lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          accessory
        }
      }
    }
    .padding(.leading, SGMessageMetrics.chatListHorizontalInset)
    .padding(.trailing, 12)
    .padding(.vertical, 9)
    .frame(minHeight: 80)
    .background(
      isPinned
        ? Color(UIColor.secondarySystemBackground)
        : Color(UIColor.systemBackground)
    )
    .contentShape(Rectangle())
  }
}

private struct SGMessageBubbleShape: Shape {
  let isOutgoing: Bool
  let showsTail: Bool

  func path(in rect: CGRect) -> Path {
    let tailWidth: CGFloat = showsTail ? 5 : 0
    let bodyRect = CGRect(
      x: isOutgoing ? rect.minX : rect.minX + tailWidth,
      y: rect.minY,
      width: max(0, rect.width - tailWidth),
      height: rect.height
    )
    var result = Path(
      roundedRect: bodyRect,
      cornerSize: CGSize(
        width: SGMessageMetrics.bubbleCornerRadius,
        height: SGMessageMetrics.bubbleCornerRadius
      )
    )
    guard showsTail, rect.height >= 18 else { return result }

    var tail = Path()
    if isOutgoing {
      tail.move(to: CGPoint(x: bodyRect.maxX - 1, y: bodyRect.maxY - 15))
      tail.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: rect.maxY - 2),
        control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - 5)
      )
      tail.addQuadCurve(
        to: CGPoint(x: bodyRect.maxX - 8, y: bodyRect.maxY - 6),
        control: CGPoint(x: bodyRect.maxX - 1, y: bodyRect.maxY)
      )
    } else {
      tail.move(to: CGPoint(x: bodyRect.minX + 1, y: bodyRect.maxY - 15))
      tail.addQuadCurve(
        to: CGPoint(x: rect.minX, y: rect.maxY - 2),
        control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - 5)
      )
      tail.addQuadCurve(
        to: CGPoint(x: bodyRect.minX + 8, y: bodyRect.maxY - 6),
        control: CGPoint(x: bodyRect.minX + 1, y: bodyRect.maxY)
      )
    }
    tail.closeSubpath()
    result.addPath(tail)
    return result
  }
}

/// Uses a message's intrinsic width until it reaches Swiftgram's cap, then
/// proposes the capped width again so long text wraps instead of overflowing.
private struct SGIntrinsicWidthCappedLayout: Layout {
  let maximumWidth: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    let availableWidth = max(1, min(proposal.width ?? maximumWidth, maximumWidth))
    let naturalSize = subview.sizeThatFits(.unspecified)
    let width = max(1, min(naturalSize.width, availableWidth))
    let fitted = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    return CGSize(width: ceil(width), height: ceil(fitted.height))
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let subview = subviews.first else { return }
    subview.place(
      at: bounds.origin,
      anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }
}

/// Swiftgram-style incoming/outgoing bubble container.
public struct SGMessageBubble<Content: View>: View {
  private let isOutgoing: Bool
  private let showsTail: Bool
  private let backgroundColor: Color
  private let content: Content

  public init(
    isOutgoing: Bool,
    showsTail: Bool = true,
    backgroundColor: Color,
    @ViewBuilder content: () -> Content
  ) {
    self.isOutgoing = isOutgoing
    self.showsTail = showsTail
    self.backgroundColor = backgroundColor
    self.content = content()
  }

  public var body: some View {
    SGIntrinsicWidthCappedLayout(maximumWidth: SGMessageMetrics.bubbleMaximumWidth) {
      content.fixedSize(horizontal: false, vertical: true)
    }
    .background(
      SGMessageBubbleShape(isOutgoing: isOutgoing, showsTail: showsTail)
        .fill(backgroundColor)
    )
    .clipShape(SGMessageBubbleShape(isOutgoing: isOutgoing, showsTail: showsTail))
  }
}

/// Native composer extracted behind a Bilibili-agnostic callback interface.
public struct SGChatInputPanel: View {
  @Binding private var text: String
  @Binding private var showsEmotes: Bool
  private let isSending: Bool
  private let accentColor: Color
  private let quickEmotes: [SGQuickEmote]
  private let onPhoto: () -> Void
  private let onSend: () -> Void

  public init(
    text: Binding<String>,
    showsEmotes: Binding<Bool>,
    isSending: Bool,
    accentColor: Color,
    quickEmotes: [SGQuickEmote],
    onPhoto: @escaping () -> Void,
    onSend: @escaping () -> Void
  ) {
    _text = text
    _showsEmotes = showsEmotes
    self.isSending = isSending
    self.accentColor = accentColor
    self.quickEmotes = quickEmotes
    self.onPhoto = onPhoto
    self.onSend = onSend
  }

  private var canSend: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
  }

  public var body: some View {
    VStack(spacing: 0) {
      if showsEmotes {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(quickEmotes, id: \.self) { emote in
              Button { text += emote.token } label: {
                Group {
                  if let url = emote.url {
                    AsyncImage(url: url) { phase in
                      if let image = phase.image {
                        image.resizable().scaledToFit()
                      } else {
                        Image(systemName: "face.smiling")
                          .foregroundColor(.secondary)
                      }
                    }
                    .frame(width: 32, height: 32)
                  } else {
                    Text(emote.token)
                      .font(.caption)
                      .padding(.horizontal, 4)
                  }
                }
                .frame(minWidth: 34, minHeight: 34)
                .padding(.horizontal, 4)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              }
              .buttonStyle(PlainButtonStyle())
              .accessibilityLabel(emote.token)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
        Divider()
      }

      HStack(alignment: .bottom, spacing: 9) {
        Button(action: onPhoto) {
          Image(systemName: "photo.on.rectangle.angled")
            .font(.system(size: 19))
            .frame(width: 32, height: 36)
        }
        .disabled(isSending)

        Button { showsEmotes.toggle() } label: {
          Image(systemName: showsEmotes ? "keyboard" : "face.smiling")
            .font(.system(size: 19))
            .frame(width: 30, height: 36)
        }

        TextField("发个消息聊聊呗~", text: $text)
          .textFieldStyle(PlainTextFieldStyle())
          .padding(.horizontal, 13)
          .padding(.vertical, 9)
          .background(Color(UIColor.secondarySystemBackground))
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .submitLabel(.send)
          .onSubmit { if canSend { onSend() } }

        Button(action: onSend) {
          if isSending {
            ProgressView().frame(width: 34, height: 36)
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 30))
              .foregroundColor(canSend ? accentColor : .secondary)
              .frame(width: 34, height: 36)
          }
        }
        .disabled(!canSend)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .background(.ultraThinMaterial)
  }
}
