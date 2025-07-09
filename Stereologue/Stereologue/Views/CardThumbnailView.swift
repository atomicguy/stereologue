import SwiftUI
import SwiftData

struct CardThumbnailView: View {
    let card: CardSchemaV1.StereoCard
    
    @State private var thumbnailImage: Image?
    
    var body: some View {
        VStack(spacing: 6) {
            // Card image area
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardColor)
                
                if let thumbnailImage = thumbnailImage {
                    thumbnailImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                } else {
                    // Placeholder
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(3/2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // Card metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                if let author = card.authors.first?.name {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await loadThumbnail()
        }
    }
    
    private var displayTitle: String {
        card.titlePick?.text ?? "Untitled Card"
    }
    
    private var cardColor: Color {
        if let color = ColorUtils.color(from: card.cardColor) {
            return color.opacity(card.colorOpacity)
        } else {
            return ColorUtils.defaultCardColor
        }
    }
    
    private func loadThumbnail() async {
        // For now, just set a placeholder
        // In the future, this would load actual image data
        guard let thumbnailData = card.frontThumbnailData else { return }
        
        thumbnailImage = ImageUtils.loadImage(from: thumbnailData)
    }
}
