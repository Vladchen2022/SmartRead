enum PlaybackSpeed: Float, CaseIterable {
    case threeQuarters = 0.75
    case normal = 1

    init(savedRate: Float) {
        self = (0.5..<1).contains(savedRate) ? .threeQuarters : .normal
    }

    var title: String {
        switch self {
        case .threeQuarters: "0.75×"
        case .normal: "原速（1×）"
        }
    }
}
