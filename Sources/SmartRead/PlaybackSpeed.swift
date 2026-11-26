enum PlaybackSpeed: Float, CaseIterable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1
    case faster = 1.2

    var title: String {
        switch self {
        case .half: "0.5×"
        case .threeQuarters: "0.75×"
        case .normal: "原速（1×）"
        case .faster: "1.2×"
        }
    }
}
