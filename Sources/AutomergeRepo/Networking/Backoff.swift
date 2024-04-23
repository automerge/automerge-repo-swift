import Foundation

/// A type that provides a computation for a random back-off value based on an integer number of iterations.
public enum Backoff {
    // fibonacci numbers for 0...15
    static let fibonacci = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610]

    /// Returns an integer value that indicates a backoff value.
    ///
    /// The value can be interpreted as the caller desires - milliseconds, seconds, etc -
    /// as it is not a duration.
    ///
    /// - Parameters:
    ///   - step: The number of previous tries
    ///   - withJitter: A Boolean value that indicates whether additional randomness should be applied to the base
    /// backoff value for the step you provide.
    /// - Returns: An integer greater than 0 that represents a growing backoff time.
    public static func delay(_ step: UInt, withJitter: Bool) -> Int {
        let boundedStep = Int(min(15, step))

        if withJitter {
            // pick a range of +/- values that's one fibonacci step lower
            let jitterStep = max(min(15, boundedStep - 1), 0)
            if jitterStep < 1 {
                // picking a random number between -0 and 0 is just silly, and kinda wrong
                // so just return the fibonacci number
                return Self.fibonacci[boundedStep]
            }
            let jitterRange = -1 * Self.fibonacci[jitterStep] ... Self.fibonacci[jitterStep]
            let selectedValue = Int.random(in: jitterRange)
            // no delay should be less than 0
            let adjustedValue = max(0, Self.fibonacci[boundedStep] + selectedValue)
            // max value is 987, min value is 0
            return adjustedValue
        }
        return Self.fibonacci[boundedStep]
    }
}
