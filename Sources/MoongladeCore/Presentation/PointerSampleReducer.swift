public struct PointerContainmentState: Equatable, Sendable {
    public let isInside: Bool
    public let revision: UInt

    public init(isInside: Bool, revision: UInt) {
        self.isInside = isInside
        self.revision = revision
    }
}

public struct PointerSampleReduction: Equatable, Sendable {
    public let location: DisplayPoint
    public let containmentChange: PointerContainmentState?
}

/// Keeps high-frequency pointer coordinates available to imperative movement
/// gates while producing observable state only when containment changes.
public struct PointerSampleReducer: Equatable, Sendable {
    public private(set) var isInside = false
    public private(set) var revision: UInt = 0

    public init() {}

    public mutating func reduce(
        isInside: Bool,
        location: DisplayPoint
    ) -> PointerSampleReduction {
        guard isInside != self.isInside else {
            return PointerSampleReduction(location: location, containmentChange: nil)
        }

        self.isInside = isInside
        revision &+= 1
        return PointerSampleReduction(
            location: location,
            containmentChange: PointerContainmentState(
                isInside: isInside,
                revision: revision
            )
        )
    }
}
