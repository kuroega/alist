import SwiftUI

struct BrowserFileBadge {
    enum Kind: Equatable {
        case folder
        case video
        case audio
        case image
        case pdf
        case archive
        case spreadsheet
        case presentation
        case code
        case text
        case document
    }

    let kind: Kind
    let displayExtension: String?

    init(item: AListObject) {
        let fileExtension = Self.fileExtension(for: item.name)
        displayExtension = fileExtension?.uppercased()

        if item.isDirectory {
            kind = .folder
        } else if item.fileType == .video {
            kind = .video
        } else if item.fileType == .audio {
            kind = .audio
        } else if item.fileType == .image {
            kind = .image
        } else if item.fileType == .text {
            kind = Self.kind(for: fileExtension)
        } else {
            kind = Self.kind(for: fileExtension)
        }
    }

    var title: String {
        switch kind {
        case .folder: "Folder"
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .pdf: "PDF document"
        case .archive: "Archive"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .code: "Code file"
        case .text: "Text document"
        case .document: "Document"
        }
    }

    var systemImage: String {
        switch kind {
        case .folder: "folder.fill"
        case .video: "play.rectangle.fill"
        case .audio: "waveform"
        case .image: "photo.fill"
        case .pdf: "doc.richtext.fill"
        case .archive: "archivebox.fill"
        case .spreadsheet: "tablecells.fill"
        case .presentation: "rectangle.on.rectangle.angled"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text.fill"
        case .document: "doc.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .folder: .orange
        case .video: .red
        case .audio: .purple
        case .image: .cyan
        case .pdf: .red
        case .archive, .presentation: .orange
        case .spreadsheet: .green
        case .code: .mint
        case .text: .blue
        case .document: .gray
        }
    }

    var accessibilityDescription: String {
        [title, displayExtension].compactMap { $0 }.joined(separator: ", ")
    }

    private static func kind(for fileExtension: String?) -> Kind {
        switch fileExtension {
        case "pdf": .pdf
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz": .archive
        case "csv", "xls", "xlsx", "numbers": .spreadsheet
        case "ppt", "pptx", "key": .presentation
        case "swift", "go", "py", "rb", "java", "kt", "js", "tsx", "jsx", "json", "xml", "yaml", "yml", "toml", "html", "css", "sh": .code
        case "txt", "md", "rtf", "log", "nfo": .text
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "ts": .video
        case "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus": .audio
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff": .image
        default: .document
        }
    }

    private static func fileExtension(for name: String) -> String? {
        let filename = URL(fileURLWithPath: name).lastPathComponent
        guard !filename.hasPrefix("."),
              let dot = filename.lastIndex(of: "."),
              dot < filename.index(before: filename.endIndex) else {
            return nil
        }
        return String(filename[filename.index(after: dot)...]).lowercased()
    }
}

struct BrowserFileBadgeView: View {
    enum Size {
        case card
        case list

        var symbolSize: CGFloat { self == .card ? 58 : 30 }
        var extensionFont: Font { self == .card ? .caption.weight(.bold) : .caption2.weight(.bold) }
        var cornerRadius: CGFloat { self == .card ? 22 : 16 }
    }

    let badge: BrowserFileBadge
    let size: Size

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [badge.tint.opacity(0.46), badge.tint.opacity(0.14), .white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)

            Image(systemName: badge.systemImage)
                .font(.system(size: size.symbolSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, badge.tint)
                .shadow(color: badge.tint.opacity(0.42), radius: 12)

            if let fileExtension = badge.displayExtension {
                Text(fileExtension)
                    .font(size.extensionFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.24), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size == .card ? 13 : 8)
            }
        }
        .accessibilityHidden(true)
    }
}
