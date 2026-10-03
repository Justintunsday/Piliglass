import SwiftUI
import UIKit

@MainActor
struct PiliNativeSearchView<Model: PiliNativeSearchViewState>: View {
  @ObservedObject var model: Model
  @State private var keyword = ""
  @FocusState private var searchFocused: Bool

  private let keywordColumns = [
    GridItem(.adaptive(minimum: 132), spacing: 9, alignment: .leading),
  ]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
        TextField("搜索视频", text: $keyword, onCommit: submit)
          .textFieldStyle(PlainTextFieldStyle())
          .autocapitalization(.none)
          .disableAutocorrection(true)
          .focused($searchFocused)
        if !keyword.isEmpty {
          Button {
            keyword = ""
            model.updateSearchSuggestions("")
            searchFocused = true
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
          }
        }
      }
      .padding(.horizontal, PiliNativeDesign.spaceM)
      .frame(minHeight: PiliNativeDesign.touchTarget)
      .background(PiliNativeDesign.elevatedSurface)
      .clipShape(RoundedRectangle(cornerRadius: PiliNativeDesign.radiusM, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: PiliNativeDesign.radiusM, style: .continuous)
          .stroke(PiliNativeDesign.divider, lineWidth: 1)
      }
      .padding(.horizontal, PiliNativeDesign.spaceM)
      .padding(.vertical, PiliNativeDesign.spaceS)

      searchContent
    }
    .background(PiliNativeDesign.background)
    .navigationBarTitle("搜索", displayMode: .inline)
    .navigationBarItems(
      trailing: Button("搜索", action: submit)
        .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    )
    .onAppear {
      model.loadSearchDiscovery()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
    }
    .onChange(of: keyword) { model.updateSearchSuggestions($0) }
    .onDisappear { model.cancelSearchRequests() }
  }

  @ViewBuilder
  private var searchContent: some View {
    let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty,
       value != model.searchSubmittedKeyword,
       !model.searchSuggestions.isEmpty {
      suggestionsView
    } else if !value.isEmpty, value == model.searchSubmittedKeyword {
      searchResultsView
    } else {
      discoveryView
    }
  }

  private var suggestionsView: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(model.searchSuggestions, id: \.self) { suggestion in
          Button { selectKeyword(suggestion) } label: {
            HStack(spacing: 12) {
              Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
              Text(suggestion).foregroundStyle(.primary)
              Spacer()
              Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Divider().padding(.leading, 48)
        }
      }
    }
  }

  private var discoveryView: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: PiliNativeDesign.spaceXL) {
        if model.searchDiscoveryLoading,
           model.searchTrending.isEmpty,
           model.searchHistory.isEmpty,
           model.searchRecommendations.isEmpty {
          HStack { Spacer(); ProgressView("正在加载搜索内容"); Spacer() }
            .padding(.top, 32)
        }
        if let error = model.searchDiscoveryError {
          HStack {
            Text(piliLocalizedDisplay(error)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("重试", action: model.loadSearchDiscovery)
          }
          .padding(PiliNativeDesign.spaceM)
          .background(PiliNativeDesign.elevatedSurface)
          .clipShape(RoundedRectangle(cornerRadius: PiliNativeDesign.radiusM, style: .continuous))
        }
        if !model.searchTrending.isEmpty {
          keywordSection(title: "大家都在搜", values: model.searchTrending, numbered: true)
        }
        if !model.searchHistory.isEmpty {
          keywordSection(
            title: "搜索历史",
            values: model.searchHistory,
            clearAction: model.clearSearchHistory
          )
        }
        if !model.searchRecommendations.isEmpty {
          keywordSection(title: "搜索发现", values: model.searchRecommendations)
        }
      }
      .frame(maxWidth: 720)
      .padding(.horizontal, PiliNativeDesign.spaceM)
      .padding(.vertical, PiliNativeDesign.spaceL)
      .frame(maxWidth: .infinity)
    }
    .refreshable { model.loadSearchDiscovery() }
  }

  private func keywordSection(
    title: String,
    values: [String],
    numbered: Bool = false,
    clearAction: (() -> Void)? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(piliLocalized(title)).font(PiliNativeDesign.heading)
        Spacer()
        if let clearAction {
          Button(action: clearAction) {
            Label("清空", systemImage: "trash").font(.caption)
          }
          .foregroundStyle(.secondary)
        }
      }
      if numbered {
        LazyVStack(spacing: 0) {
          ForEach(Array(values.enumerated()), id: \.offset) { index, value in
            Button { selectKeyword(value) } label: {
              HStack(spacing: PiliNativeDesign.spaceM) {
                Text(String(index + 1))
                  .font(PiliNativeDesign.subheading.monospacedDigit())
                  .foregroundStyle(index < 3 ? piliAccent : Color(uiColor: .secondaryLabel))
                  .frame(width: 28, alignment: .center)
                Text(value)
                  .font(PiliNativeDesign.body)
                  .lineLimit(1)
                  .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .padding(.horizontal, PiliNativeDesign.spaceM)
              .frame(minHeight: PiliNativeDesign.touchTarget)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if index != values.indices.last {
              Divider().padding(.leading, 60)
            }
          }
        }
        .background(PiliNativeDesign.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: PiliNativeDesign.radiusM, style: .continuous))
      } else {
        LazyVGrid(columns: keywordColumns, alignment: .leading, spacing: PiliNativeDesign.spaceS) {
          ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            Button { selectKeyword(value) } label: {
              HStack(spacing: PiliNativeDesign.spaceS) {
                Text(value)
                  .font(PiliNativeDesign.body)
                  .lineLimit(1)
                  .foregroundStyle(.primary)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, PiliNativeDesign.spaceM)
              .frame(maxWidth: .infinity, minHeight: PiliNativeDesign.touchTarget)
              .background(PiliNativeDesign.elevatedSurface)
              .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .contextMenu {
              if title == "搜索历史" {
                Button(role: .destructive) { model.removeSearchHistory(value) } label: {
                  Label("删除记录", systemImage: "trash")
                }
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var searchResultsView: some View {
    if model.searchLoading && model.searchResults.isEmpty {
      PiliNativeLoadingView(title: "正在搜索")
    } else if let error = model.searchError, model.searchResults.isEmpty {
      PiliNativeErrorView(message: error, retry: submit)
    } else if model.searchResults.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 34))
          .foregroundColor(.secondary)
        Text("没有找到相关视频")
          .font(.subheadline)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.searchResults) { video in
            Button {
              model.openSearchVideo(video, sourceID: "search:\(video.id)")
            } label: {
              HStack(alignment: .top, spacing: 12) {
                PiliRemoteImage(urlString: video.cover)
                  .frame(width: 128, height: 72)
                  .clipped()
                  .clipShape(RoundedRectangle(cornerRadius: PiliNativeDesign.radiusS, style: .continuous))
                  .piliVideoTransitionSource(id: "search:\(video.id)")
                VStack(alignment: .leading, spacing: 6) {
                  Text(video.title).font(.subheadline).foregroundColor(.primary).lineLimit(2)
                  Text(video.owner).font(.caption).foregroundColor(.secondary)
                  if !video.viewText.isEmpty {
                    Text(piliLocalizedFormat("%@ 播放", video.viewText)).font(.caption2).foregroundColor(.secondary)
                  }
                }
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onAppear {
              if video.id == model.searchResults.last?.id { model.loadMoreSearchResults() }
            }
            Divider().padding(.leading, 154)
          }
          if model.searchLoadingMore {
            ProgressView("正在加载更多视频").font(.caption).padding(.vertical, 18)
          } else if let error = model.searchError {
            VStack(spacing: 8) {
              Text(piliLocalizedDisplay(error)).font(.caption).foregroundColor(.secondary)
              Button("重试加载", action: model.loadMoreSearchResults)
                .font(.caption).foregroundColor(piliAccent)
            }
            .padding(.vertical, 14)
          } else if model.searchHasMore {
            Button("加载更多视频", action: model.loadMoreSearchResults)
              .font(.caption).foregroundColor(piliAccent).padding(.vertical, 18)
          }
        }
      }
    }
  }

  private func selectKeyword(_ value: String) {
    keyword = value
    submit()
  }

  private func submit() {
    searchFocused = false
    model.search(keyword)
  }
}
