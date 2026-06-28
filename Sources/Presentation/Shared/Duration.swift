import Contract

extension SlideDurationReturn {
    var displayLabel: String {
        switch self {
        case .five: return "5 sec"
        case .ten: return "10 sec"
        case .fifteen: return "15 sec"
        case .thirty: return "30 sec"
        case .sixty: return "60 sec"
        case .manual: return "None"
        }
    }
}
