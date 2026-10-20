import SwiftUI

/// iPod Drop's colours, in Apple Music's red. Set explicitly: macOS replaces an app's
/// accent colour with the system accent unless that is set to Multicolor.
extension Color {
    static let brand = Color("AccentColor")
    /// The two ends of Apple Music's icon gradient.
    static let brandLight = Color(red: 0.98, green: 0.35, blue: 0.42)
    static let brandDeep = Color(red: 0.98, green: 0.14, blue: 0.23)
}

extension ShapeStyle where Self == LinearGradient {
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [.brandLight, .brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
