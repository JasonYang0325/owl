import SwiftUI

struct BookmarkSidebarView: View {
    @ObservedObject var bookmarkVM: BookmarkViewModel
    var onNavigate: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("书签")
                    .font(OWL.buttonFont)
                    .foregroundColor(OWL.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            Divider()
                .padding(.horizontal, 10)

            // Content
            if bookmarkVM.isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if bookmarkVM.bookmarks.isEmpty {
                BookmarkEmptyState()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(bookmarkVM.bookmarks) { bookmark in
                            BookmarkRow(
                                bookmark: bookmark,
                                onSelect: { onNavigate?(bookmark.url) },
                                onDelete: {
                                    Task { await bookmarkVM.removeBookmark(id: bookmark.id) }
                                }
                            )
                        }
                    }
                }
            }
        }
        .task(id: "load") {
            await bookmarkVM.loadAll()
        }
    }
}
