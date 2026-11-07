import Foundation

enum TokenCountFormatter {
    static func compact(_ value: Int) -> String {
        if value < 10_000 { return exact(value) }
        let divisor = value >= 100_000_000 ? 100_000_000.0 : 10_000.0
        let suffix = value >= 100_000_000 ? "亿" : "万"
        return (Double(value) / divisor)
            .formatted(.number.locale(Locale(identifier: "zh_CN"))
                .precision(.fractionLength(0...2)).grouping(.never)) + suffix
    }

    static func exact(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "zh_CN")))
    }
}
