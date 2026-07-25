import Foundation

public enum InputError: Error, Equatable, Sendable {
    case payloadTooLarge
}

public enum BoundedInput {
    public static let maximumPayloadSize = 1_048_576

    public static func read(from handle: FileHandle) throws -> Data {
        let data = try handle.read(upToCount: maximumPayloadSize + 1) ?? Data()
        guard data.count <= maximumPayloadSize else {
            throw InputError.payloadTooLarge
        }
        return data
    }
}
