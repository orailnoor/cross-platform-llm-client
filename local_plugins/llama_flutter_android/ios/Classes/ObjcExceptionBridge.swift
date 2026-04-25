import Foundation

enum ObjcExceptionBridge {
    /// Executes `block` and converts any Objective-C NSException into a Swift Error.
    static func `catch`(_ block: @escaping () -> Void) throws {
        if let exception = tryBlock(block) {
            throw NSError(
                domain: "ObjcException",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: exception.reason ?? exception.name.rawValue]
            )
        }
    }
}
