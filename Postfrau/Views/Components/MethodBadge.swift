import SwiftUI
import PostfrauCore

extension HTTPMethod {
    /// Colour-coded so the sidebar and tab bar can be scanned without reading.
    var tint: Color {
        switch self {
        case .get: .green
        case .post: .orange
        case .put: .blue
        case .patch: .purple
        case .delete: .red
        case .head, .options: .secondary
        case .custom: .teal
        }
    }

    /// The short form shown in narrow places.
    var badgeText: String {
        switch self {
        case .delete: "DEL"
        case .options: "OPT"
        case .custom(let verb): String(verb.prefix(4))
        default: rawValue
        }
    }
}

/// The small method label used in the sidebar, tab bar and history rows.
struct MethodBadge: View {
    var method: HTTPMethod
    var size: Double = 10

    var body: some View {
        Text(method.badgeText)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(method.tint)
            .monospacedDigit()
            .frame(minWidth: size * 3.2, alignment: .leading)
            .accessibilityLabel("\(method.rawValue) request")
    }
}

/// The coloured status pill in the response header.
struct StatusBadge: View {
    var statusCode: Int
    var reasonPhrase: String

    private var tint: Color {
        switch statusCode {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        case 500...: .red
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text("\(statusCode)").font(.callout.weight(.semibold)).monospacedDigit()
            Text(reasonPhrase).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status \(statusCode) \(reasonPhrase)")
    }
}
