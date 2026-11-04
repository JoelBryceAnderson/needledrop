import Archive
import SwiftUI

/// The idle screen: a slowly drifting mosaic of every album played, most recent first,
/// with play counts, and a line or two about what's been on the turntable.
struct LibraryWallView: View {
    let library: Library?
    @State private var albums: [AlbumSummary] = []
    @State private var images: [Int64: NSImage] = [:]
    @State private var moments: [String] = []
    private let rows = 3

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geometry in
                let u = min(geometry.size.width / 64, geometry.size.height / 40)
                let tile = (geometry.size.height - u * 9) / CGFloat(rows)
                let columns = max(1, Int((Double(albums.count) / Double(rows)).rounded(.up)))
                let stripWidth = CGFloat(columns) * (tile + u)
                // Drift left ~one tile every 8 s; repeat the strip so it never runs out.
                let offset = stripWidth > 0 ? CGFloat(context.date.timeIntervalSinceReferenceDate * Double(tile + u) / 8)
                    .truncatingRemainder(dividingBy: stripWidth) : 0
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    if albums.isEmpty {
                        Text("Play a record")
                            .font(.system(size: u * 3, weight: .bold, design: .serif))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let copies = Int((geometry.size.width / stripWidth).rounded(.up)) + 1
                        HStack(spacing: u) {
                            ForEach(0..<(columns * copies), id: \.self) { column in
                                VStack(spacing: u) {
                                    ForEach(0..<rows, id: \.self) { row in
                                        let index = (column % columns) * rows + row
                                        if index < albums.count {
                                            AlbumTile(album: albums[index], image: images[albums[index].albumID], size: tile, u: u)
                                        } else {
                                            Color.clear.frame(width: tile, height: tile)
                                        }
                                    }
                                }
                            }
                        }
                        .offset(x: -offset, y: -u * 3)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, u * 2)
                        moments(u: u)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func moments(u: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: u * 0.3) {
            ForEach(moments, id: \.self) { line in
                Text(line)
                    .font(.system(size: u * 1.6, weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, u * 3)
        .padding(.vertical, u * 1.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.7))
    }

    private func load() async {
        guard let library else { return }
        let albums = (try? library.albumsByRecentPlay()) ?? []
        var images: [Int64: NSImage] = [:]
        for album in albums {
            if let path = album.artworkPath, let image = NSImage(contentsOfFile: path) { images[album.albumID] = image }
        }
        var moments: [String] = []
        let month = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        if let top = try? library.mostPlayedAlbum(since: month) {
            moments.append("Most spun this month: \(top.title) — \(top.artist) (\(top.plays) plays)")
        }
        if let past = try? library.albumsPlayedOnThisDay().first {
            let year = Calendar.current.component(.year, from: past.lastPlayed)
            moments.append("On this day in \(year): \(past.title) — \(past.artist)")
        }
        self.albums = albums
        self.images = images
        self.moments = moments
    }
}

private struct AlbumTile: View {
    let album: AlbumSummary
    let image: NSImage?
    let size: CGFloat
    let u: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.15)
                Text(album.title)
                    .font(.system(size: u * 1.4, weight: .bold, design: .serif))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(u)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Text("×\(album.plays)")
                .font(.system(size: u * 1.5, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, u * 0.6)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(u * 0.6)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: u * 0.4))
    }
}
