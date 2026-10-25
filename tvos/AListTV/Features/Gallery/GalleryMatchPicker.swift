import SwiftUI

/// The no-match prompt and the match picker, over any Gallery screen.
struct GalleryMatchPresentation: ViewModifier {
    @ObservedObject var presenter: GalleryMatchPresenter
    let viewModel: GalleryViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                Text("No exact match for “\(presenter.prompt?.name ?? "")”"),
                isPresented: Binding(get: { presenter.prompt != nil }, set: { if !$0 { presenter.prompt = nil } }),
                presenting: presenter.prompt
            ) { subject in
                Button("Show Closest Matches") { presenter.picker = subject }
                Button("Not Now", role: .cancel) {}
            } message: { _ in
                Text("Pick the right title from TMDB’s closest matches. You can also rename its files after it.")
            }
            .sheet(item: $presenter.picker) { subject in
                GalleryMatchPickerView(viewModel: viewModel, subject: subject)
            }
    }
}

/// Steps through picking a match: closest candidates, a preview of the
/// renames the pick calls for, then applying it.
@MainActor
final class GalleryMatchPickerModel: ObservableObject {
    enum Step {
        case searching
        case candidates
        case failed(String)
        case preparing(GalleryCandidate)
        case review(GalleryMatchProposal)
        case applying(done: Int, total: Int)
        case finished(GalleryMatchProposal, GalleryMatchOutcome)
    }

    @Published private(set) var step: Step = .searching
    @Published private(set) var candidates: [GalleryCandidate] = []
    @Published var query: String

    let subject: GalleryMatchSubject
    /// Counted once: a match moves the title's videos to its matched entry.
    let videoCount: Int
    private let viewModel: GalleryViewModel
    private var task: Task<Void, Never>?

    init(viewModel: GalleryViewModel, subject: GalleryMatchSubject) {
        self.viewModel = viewModel
        self.subject = subject
        query = viewModel.parsedMedia(for: subject.title)?.title ?? subject.name
        videoCount = viewModel.videos(for: subject.title).count
    }

    /// The parsed title searches with its looser forms; anything typed searches as is.
    func search(typed: Bool = false) {
        task?.cancel()
        step = .searching
        let query = typed ? query : nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await viewModel.closestCandidates(for: subject.title, query: query)
                guard !Task.isCancelled else { return }
                candidates = found
                step = .candidates
            } catch {
                guard !Task.isCancelled else { return }
                step = .failed(Self.message(error))
            }
        }
    }

    func choose(_ candidate: GalleryCandidate) {
        task?.cancel()
        step = .preparing(candidate)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let proposal = try await viewModel.propose(candidate, for: subject.title)
                guard !Task.isCancelled else { return }
                step = .review(proposal)
            } catch {
                guard !Task.isCancelled else { return }
                step = .failed(Self.message(error))
            }
        }
    }

    func backToCandidates() {
        task?.cancel()
        step = candidates.isEmpty ? .searching : .candidates
        if candidates.isEmpty { search() }
    }

    func apply(_ proposal: GalleryMatchProposal, renaming: Bool) {
        task?.cancel()
        step = .applying(done: 0, total: renaming ? proposal.plan.fileCount : 0)
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await viewModel.apply(proposal, to: subject.title, renaming: renaming) { [weak self] done, total in
                self?.step = .applying(done: done, total: total)
            }
            step = .finished(proposal, outcome)
        }
    }

    func cancel() { task?.cancel() }

    private static func message(_ error: Error) -> String {
        switch error {
        case TMDBError.transport, TMDBError.rateLimited: return "Couldn’t reach TMDB. Try again in a moment."
        case TMDBError.unauthorized: return "TMDB rejected the API key."
        default: return (error as? LocalizedError)?.errorDescription ?? "Something went wrong (\(error))."
        }
    }
}

struct GalleryMatchPickerView: View {
    @StateObject private var model: GalleryMatchPickerModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: GalleryViewModel, subject: GalleryMatchSubject) {
        _model = StateObject(wrappedValue: GalleryMatchPickerModel(viewModel: viewModel, subject: subject))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            // One stack, so a step's views share the height top-down.
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(60)
        .frame(width: 1440, height: 940, alignment: .topLeading)
        .glassPanel(cornerRadius: 44)
        .onAppear { model.search() }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 48, weight: .bold))
            Text("“\(model.subject.name)” · \(model.videoCount) video\(model.videoCount == 1 ? "" : "s")")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var title: String {
        switch model.step {
        case .searching, .candidates, .failed, .preparing: "Choose the Right Title"
        case .review: "Rename and Match"
        case .applying: "Applying…"
        case .finished: "Done"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .searching:
            searchBar
            progress("Searching TMDB…")
        case .candidates:
            searchBar
            candidateList
        case let .failed(message):
            searchBar
            VStack(alignment: .leading, spacing: 24) {
                Text(message)
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.secondaryText)
                Button("Try Again") { model.search(typed: true) }
                    .buttonStyle(PillButtonStyle(prominence: .primary))
            }
        case let .preparing(candidate):
            progress("Reading “\(candidate.title)” and its folders…")
        case let .review(proposal):
            review(proposal)
        case let .applying(done, total):
            progress(total > 0 && done < total ? "Renaming \(done + 1) of \(total)…" : "Saving the match…")
        case let .finished(proposal, outcome):
            finished(proposal, outcome)
        }
    }

    // MARK: Candidates

    private var searchBar: some View {
        HStack(spacing: 24) {
            TextField("Search TMDB", text: $model.query)
                .onSubmit { model.search(typed: true) }
                .frame(maxWidth: 900)
                .accessibilityIdentifier("gallery.match.query")
            Button { model.search(typed: true) } label: { Label("Search", systemImage: "magnifyingglass") }
                .buttonStyle(PillButtonStyle())
        }
        .focusSection()
    }

    @ViewBuilder
    private var candidateList: some View {
        if model.candidates.isEmpty {
            Text("TMDB has nothing close to this name. Try a shorter or different search.")
                .font(.system(size: 26))
                .foregroundStyle(Theme.secondaryText)
                .padding(.top, 12)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.candidates) { candidate in
                        Button { model.choose(candidate) } label: {
                            CandidateRow(candidate: candidate)
                        }
                        .buttonStyle(RowButtonStyle(cornerRadius: 22))
                        .accessibilityIdentifier("gallery.match.candidate.\(candidate.tmdbID)")
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: Review

    private func review(_ proposal: GalleryMatchProposal) -> some View {
        let plan = proposal.plan
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 26) {
                ArtworkImage(url: TMDBImage.url(proposal.match.posterPath, size: .poster)) {
                    GeneratedPoster(title: proposal.candidate.title, compact: true)
                }
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text([proposal.match.title ?? proposal.candidate.title, proposal.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 32, weight: .bold))
                    Text(summary(plan, fileTitle: proposal.fileTitle))
                        .font(.system(size: 23))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(3)
                }
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(plan.groups, id: \.video) { group in
                        ForEach([group.video] + group.subtitles, id: \.self) { rename in
                            RenameRow(rename: rename, isSubtitle: rename != group.video)
                        }
                    }
                    ForEach(plan.skipped, id: \.self) { skip in
                        SkipRow(skip: skip)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()

            HStack(spacing: 24) {
                if plan.fileCount > 0 {
                    Button { model.apply(proposal, renaming: true) } label: {
                        Label("Rename \(plan.fileCount) File\(plan.fileCount == 1 ? "" : "s") & Match", systemImage: "pencil")
                    }
                    .buttonStyle(PillButtonStyle(prominence: .primary))
                    .accessibilityIdentifier("gallery.match.rename")
                }
                Button { model.apply(proposal, renaming: false) } label: {
                    Label(plan.fileCount > 0 ? "Match Only" : "Match", systemImage: "checkmark")
                }
                .buttonStyle(PillButtonStyle(prominence: plan.fileCount > 0 ? .secondary : .primary))
                .accessibilityIdentifier("gallery.match.only")
                Button { model.backToCandidates() } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(PillButtonStyle())
            }
            .focusSection()
        }
    }

    private func summary(_ plan: GalleryRenamePlan, fileTitle: String) -> String {
        var parts: [String] = []
        if plan.fileCount > 0 {
            parts.append("Files are renamed after TMDB’s original title, “\(fileTitle)”. Release tags and subtitle pairing are kept, and nothing is overwritten.")
        } else {
            parts.append("Nothing needs renaming.")
        }
        if !plan.unchanged.isEmpty { parts.append("\(plan.unchanged.count) already named this way.") }
        if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) left as they are.") }
        return parts.joined(separator: " ")
    }

    // MARK: Finished

    private func finished(_ proposal: GalleryMatchProposal, _ outcome: GalleryMatchOutcome) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Label(
                outcome.matched ? "Matched to “\(proposal.match.title ?? proposal.candidate.title)”." : "The match couldn’t be saved.",
                systemImage: outcome.matched ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.system(size: 30, weight: .semibold))
            if !outcome.renamed.isEmpty {
                Text("Renamed \(outcome.renamed.count) file\(outcome.renamed.count == 1 ? "" : "s"). The Gallery is reading those folders again.")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.secondaryText)
            }
            if !outcome.failures.isEmpty {
                Text("\(outcome.failures.count) couldn’t be renamed:")
                    .font(.system(size: 24, weight: .semibold))
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(outcome.failures, id: \.self) { SkipRow(skip: $0) }
                    }
                }
                .frame(maxHeight: 420)
            }
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .buttonStyle(PillButtonStyle(prominence: .primary))
                .accessibilityIdentifier("gallery.match.done")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 18) {
            ProgressView()
            Text(text)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.top, 20)
    }
}

private struct CandidateRow: View {
    let candidate: GalleryCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ArtworkImage(url: TMDBImage.url(candidate.posterPath, size: .poster)) {
                GeneratedPoster(title: candidate.title, compact: true)
            }
            .frame(width: 80, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.title)
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 21, weight: .medium))
                    .opacity(0.65)
                    .lineLimit(1)
                if let overview = candidate.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 20))
                        .opacity(0.55)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [candidate.kind == .movie ? "Movie" : "TV Show"]
        if let year = candidate.year { parts.append(String(year)) }
        if let original = candidate.originalTitle, !original.isEmpty, original != candidate.title { parts.append(original) }
        if let rating = candidate.rating, candidate.voteCount > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }
}

private struct RenameRow: View {
    let rename: GalleryRename
    let isSubtitle: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rename.newName)
                .font(.system(size: isSubtitle ? 21 : 23, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("was \(rename.name)")
                .font(.system(size: 19))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, isSubtitle ? 48 : 20)
        .padding(.trailing, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(isFocused ? 0.14 : 0)))
        // Focusable so a long list scrolls with the remote.
        .focusable()
        .accessibilityElement(children: .combine)
    }
}

private struct SkipRow: View {
    let skip: GalleryRenamePlan.Skip

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(skip.path.split(separator: "/").last ?? ""))
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(skip.reason)
                    .font(.system(size: 19))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(isFocused ? 0.14 : 0)))
        .focusable()
        .accessibilityElement(children: .combine)
    }
}
