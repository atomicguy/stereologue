// DesignSystemTypes.swift
// Liquid Glass design system types and extensions

import SwiftUI

// MARK: - Liquid Glass Design System
struct CollectionTheme {
    let primaryColor: Color
    let accentColor: Color
    let glassMorphism: GlassMorphismStyle
    let typography: TypographyStyle
    
    static let `default` = CollectionTheme(
        primaryColor: .blue,
        accentColor: .orange,
        glassMorphism: GlassMorphismStyle.standard,
        typography: .modern
    )
}

struct GlassMorphismStyle {
    let blur: Double
    let opacity: Double
    let saturation: Double
    let borderWidth: Double
    let cornerRadius: Double
    
    static let standard = GlassMorphismStyle(
        blur: 10,
        opacity: 0.8,
        saturation: 1.0,
        borderWidth: 0.5,
        cornerRadius: 12
    )
    
    static let subtle = GlassMorphismStyle(
        blur: 5,
        opacity: 0.6,
        saturation: 0.8,
        borderWidth: 0.25,
        cornerRadius: 8
    )
    
    static let dramatic = GlassMorphismStyle(
        blur: 20,
        opacity: 0.9,
        saturation: 1.2,
        borderWidth: 1.0,
        cornerRadius: 16
    )
}

// MARK: - Visual Density
enum VisualDensity: CaseIterable {
    case spacious, comfortable, compact, dense
    
    var itemSpacing: Double {
        switch self {
        case .spacious: return 24
        case .comfortable: return 16
        case .compact: return 12
        case .dense: return 8
        }
    }
    
    var itemSize: CGSize {
        switch self {
        case .spacious: return CGSize(width: 200, height: 300)
        case .comfortable: return CGSize(width: 160, height: 240)
        case .compact: return CGSize(width: 120, height: 180)
        case .dense: return CGSize(width: 80, height: 120)
        }
    }
    
    var gridColumns: Int {
        switch self {
        case .spacious: return 2
        case .comfortable: return 3
        case .compact: return 4
        case .dense: return 6
        }
    }
}

// MARK: - Typography
enum TypographyStyle {
    case elegant, modern, classic, playful
    
    var font: Font {
        switch self {
        case .elegant: return .custom("Optima", size: 16)
        case .modern: return .system(.body, design: .rounded)
        case .classic: return .system(.body, design: .serif)
        case .playful: return .system(.body, design: .rounded, weight: .medium)
        }
    }
    
    var headingFont: Font {
        switch self {
        case .elegant: return .custom("Optima", size: 24, relativeTo: .title)
        case .modern: return .system(.title, design: .rounded, weight: .semibold)
        case .classic: return .system(.title, design: .serif, weight: .bold)
        case .playful: return .system(.title, design: .rounded, weight: .heavy)
        }
    }
    
    var captionFont: Font {
        switch self {
        case .elegant: return .custom("Optima", size: 12, relativeTo: .caption)
        case .modern: return .system(.caption, design: .rounded)
        case .classic: return .system(.caption, design: .serif)
        case .playful: return .system(.caption, design: .rounded, weight: .medium)
        }
    }
}

// MARK: - Color Extensions
extension Color {
    static let cardDefault: Color = {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }()
    
    var adaptiveVariant: Color {
        // Create adaptive color variants based on environment
        #if os(macOS)
        return self.opacity(0.9)
        #elseif os(visionOS)
        return self.opacity(0.7)
        #else
        return self.opacity(0.8)
        #endif
    }
    
    func glassMorphism(style: GlassMorphismStyle) -> some View {
        Rectangle()
            .fill(self.opacity(style.opacity))
            .background(.thinMaterial)
            .blur(radius: style.blur)
            .saturation(style.saturation)
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .stroke(.white.opacity(0.3), lineWidth: style.borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
    }
    
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        
        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        var a: CGFloat = 1.0
        
        let length = hexSanitized.count
        
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        if length == 6 {
            r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            b = CGFloat(rgb & 0x0000FF) / 255.0
        } else if length == 8 {
            r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
            g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(rgb & 0x000000FF) / 255.0
        } else {
            return nil
        }
        
        self.init(red: r, green: g, blue: b, opacity: a)
    }
    
    func toHex() -> String? {
        #if os(macOS)
        guard let components = NSColor(self).cgColor.components else { return nil }
        #else
        guard let components = UIColor(self).cgColor.components else { return nil }
        #endif
        
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        
        return String(format: "#%02lX%02lX%02lX", 
                     lroundf(r * 255), 
                     lroundf(g * 255), 
                     lroundf(b * 255))
    }
}

// MARK: - Animation Presets
extension Animation {
    static let liquidGlass: Animation = .interpolatingSpring(
        mass: 1.0,
        stiffness: 100.0,
        damping: 10.0,
        initialVelocity: 0.0
    )
    
    static let subtleFloat: Animation = .easeInOut(duration: 2.0).repeatForever(autoreverses: true)
    
    static let glassShimmer: Animation = .linear(duration: 1.5).repeatForever(autoreverses: false)
}

// MARK: - Collection Insights
struct CollectionInsights {
    let totalCards: Int
    let dateRange: DateInterval?
    let topSubjects: [String]
    let topAuthors: [String]
    let geographicSpread: [String]
    let completenessScore: Double
    let lastActivity: Date
    
    var completenessText: String {
        let percentage = Int(completenessScore * 100)
        return "\(percentage)% complete"
    }
    
    var dateRangeText: String {
        guard let dateRange = dateRange else { return "Various periods" }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        
        return "\(formatter.string(from: dateRange.start)) - \(formatter.string(from: dateRange.end))"
    }
}

// MARK: - Adaptive Layout
struct AdaptiveLayout {
    let density: VisualDensity
    let itemsPerRow: Int
    let spacing: Double
    
    static func optimal(for containerWidth: Double, itemCount: Int) -> AdaptiveLayout {
        let density: VisualDensity
        let itemsPerRow: Int
        
        switch (containerWidth, itemCount) {
        case (0..<600, _):
            density = .compact
            itemsPerRow = 2
        case (600..<900, 0..<20):
            density = .comfortable
            itemsPerRow = 3
        case (600..<900, _):
            density = .compact
            itemsPerRow = 4
        case (900..<1200, 0..<50):
            density = .spacious
            itemsPerRow = 4
        case (900..<1200, _):
            density = .comfortable
            itemsPerRow = 5
        default:
            density = .comfortable
            itemsPerRow = 6
        }
        
        return AdaptiveLayout(
            density: density,
            itemsPerRow: itemsPerRow,
            spacing: density.itemSpacing
        )
    }
}
