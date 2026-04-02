import SwiftUI

struct SearchBarView: View {
    @Binding var query: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Filter notifications…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .onExitCommand(perform: onCancel)
    }
}
