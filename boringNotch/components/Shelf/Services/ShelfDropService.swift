//
//  ShelfDropService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropService {
    static func items(from providers: [NSItemProvider]) async -> [ShelfItem] {
        var results: [ShelfItem] = []

        for provider in providers {
            if let item = await processProvider(provider) {
                results.append(item)
            }
        }

        return results
    }
    
    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        if let actualFileURL = await provider.extractFileURL() {
            return await shelfCopy(of: actualFileURL)
        }
        
        if let url = await provider.extractURL() {
            if url.isFileURL {
                return await shelfCopy(of: url)
            } else {
                return await ShelfItem(kind: .link(url: url), isTemporary: false)
            }
            return nil
        }
        
        if let text = await provider.extractText() {
            return await ShelfItem(kind: .text(string: text), isTemporary: false)
        }
        
        if let data = await provider.loadData() {
            if let tempDataURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: provider.suggestedName)),
               let bookmark = createBookmark(for: tempDataURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
            }
            return nil
        }
        
        if let fileURL = await provider.extractItem() {
            if let bookmark = createBookmark(for: fileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
        }
        
        return nil
    }
    
    /// The shelf keeps its own copy, so dragging out or removing never touches the original.
    /// Falls back to referencing the original if the copy fails (e.g. no space).
    private static func shelfCopy(of url: URL) async -> ShelfItem? {
        if let copyURL = await TemporaryFileStorageService.shared.createTempFile(for: .fileCopy(url)),
           let bookmark = createBookmark(for: copyURL) {
            return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
        }
        guard let bookmark = createBookmark(for: url) else { return nil }
        return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
    }

    private static func createBookmark(for url: URL) -> Data? {
        return (try? Bookmark(url: url))?.data
    }
}

