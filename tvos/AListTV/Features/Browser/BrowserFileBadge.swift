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
        case .folder: Color(red: 0.98, green: 0.72, blue: 0.36)
        case .video: Color(red: 0.42, green: 0.66, blue: 1.0)
        case .audio: Color(red: 0.78, green: 0.55, blue: 1.0)
        case .image: Color(red: 0.40, green: 0.85, blue: 0.86)
        case .pdf: Color(red: 1.0, green: 0.50, blue: 0.47)
        case .archive, .presentation: Color(red: 0.96, green: 0.62, blue: 0.40)
        case .spreadsheet: Color(red: 0.45, green: 0.85, blue: 0.56)
        case .code: Color(red: 0.55, green: 0.88, blue: 0.75)
        case .text: Color(red: 0.62, green: 0.74, blue: 1.0)
        case .document: Color(white: 0.72)
        }
    }

    var isPlayable: Bool { kind == .video || kind == .audio }

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

        var symbolSize: CGFloat { self == .card ? 64 : 32 }
        var cornerRadius: CGFloat { self == .card ? 24 : 16 }
    }

    let badge: BrowserFileBadge
    let size: Size
    var isFocused = false
    var extensionAlignment: Alignment = .bottomTrailing

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(Color(white: isFocused ? 0.20 : 0.13))
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [badge.tint.opacity(isFocused ? 0.42 : 0.26), badge.tint.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(isFocused ? 0.22 : 0.08), lineWidth: 1)

            Image(systemName: badge.systemImage)
                .font(.system(size: size.symbolSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(badge.tint)

            if size == .card, let fileExtension = badge.displayExtension {
                Text(fileExtension)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: extensionAlignment)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
        }
        .accessibilityHidden(true)
    }
}
