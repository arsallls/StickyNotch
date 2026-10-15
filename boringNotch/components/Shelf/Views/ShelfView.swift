//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    @State private var trashTargeted = false
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
                .overlay(alignment: .topTrailing) {
                    if !tvm.isEmpty { trashButton.padding(8) }
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    /// Click removes every item; drag a single file onto it to remove just that one.
    private var trashButton: some View {
        Image(systemName: trashTargeted ? "trash.fill" : "trash")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(trashTargeted ? Color.white : Color.gray)
            .frame(width: 26, height: 26)
            .background(Circle().fill(trashTargeted ? Color.red : Color.white.opacity(0.08)))
            .scaleEffect(trashTargeted ? 1.2 : 1)
            .animation(.smooth(duration: 0.15), value: trashTargeted)
            .overlay(
                TrashDropTarget(
                    isTargeted: $trashTargeted,
                    accepts: { !items(matching: $0).isEmpty },
                    onDrop: { urls in withAnimation(.smooth) { items(matching: urls).forEach { tvm.remove($0) } } },
                    onClick: {
                        withAnimation(.smooth) { tvm.items.forEach { tvm.remove($0) } }
                        selection.clear()
                    }
                )
            )
            .help("Click to remove all files · drag a file here to remove it")
    }

    /// Shelf items whose file is one of `urls` (only files can be trashed by dragging).
    private func items(matching urls: [URL]) -> [ShelfItem] {
        let paths = Set(urls.map { $0.resolvingSymlinksInPath().path })
        return tvm.items.filter { item in
            item.fileURL.map { paths.contains($0.resolvingSymlinksInPath().path) } ?? false
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding()
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    var content: some View {
        Group {
            if tvm.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .symbolVariant(.fill)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white, .gray)
                        .imageScale(.large)
                    
                    Text("Drop files here")
                        .foregroundStyle(.gray)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.medium)
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: spacing) {
                        ForEach(tvm.items) { item in
                            ShelfItemView(item: item)
                                .environmentObject(quickLookService)
                        }
                    }
                }
                .padding(-spacing)
                .scrollIndicators(.never)
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .onAppear {
            ShelfStateViewModel.shared.cleanupInvalidItems()
        }
    }
}

// MARK: - Trash drop target

/// AppKit view so the trash can both take clicks and see the drag session (to fade the dragged file).
struct TrashDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var accepts: ([URL]) -> Bool
    var onDrop: ([URL]) -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> TrashDropView {
        let view = TrashDropView()
        view.registerForDraggedTypes([.fileURL])
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TrashDropView, context: Context) {
        view.accepts = accepts
        view.onDrop = onDrop
        view.onClick = onClick
        let binding = $isTargeted
        view.onTargetChange = { binding.wrappedValue = $0 }
    }
}

final class TrashDropView: NSView {
    var accepts: ([URL]) -> Bool = { _ in false }
    var onDrop: ([URL]) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onTargetChange: (Bool) -> Void = { _ in }
    private var originalImages: [Int: NSImage] = [:]

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        info.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(fileURLs(sender)) else { return [] }
        onTargetChange(true)
        setDragImages(sender, faded: true)
        return operation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(fileURLs(sender)) ? operation(sender) : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChange(false)
        if let sender { setDragImages(sender, faded: false) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard accepts(urls) else { return false }
        onDrop(urls)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onTargetChange(false)
        originalImages.removeAll()
    }

    /// Fade the dragged file while it's over the trash, restore it when it leaves.
    private func setDragImages(_ info: NSDraggingInfo, faded: Bool) {
        info.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
            if faded {
                guard let image = item.imageComponents?.first?.contents as? NSImage else { return }
                self.originalImages[index] = image
                item.setDraggingFrame(item.draggingFrame, contents: image.withAlpha(0.35))
            } else if let image = self.originalImages[index] {
                item.setDraggingFrame(item.draggingFrame, contents: image)
            }
        }
        if !faded { originalImages.removeAll() }
    }
}

private extension NSImage {
    func withAlpha(_ alpha: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
    }
}
