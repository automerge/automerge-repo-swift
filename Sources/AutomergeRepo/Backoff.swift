import Foundation

public enum Backoff {
    // fibonacci numbers for 0...15
    static let fibonacci = [0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610]
    
    public static func delay(_ step: UInt, withJitter: Bool) -> Int {
        let boundedStep = Int(min(15, step))
        
        if withJitter {
            // pick a range of +/- values that's one fibonacci step lower
            let jitterStep = max(min(15,boundedStep - 1),0)
            if jitterStep < 1 {
                // picking a random number between -0 and 0 is just silly, and kinda wrong
                // so just return the fibonacci number
                return Self.fibonacci[boundedStep]
            }
            let jitterRange = -1*Self.fibonacci[jitterStep]...Self.fibonacci[jitterStep]
            let selectedValue = Int.random(in: jitterRange)
            // no delay should be less than 0
            let adjustedValue = max(0, Self.fibonacci[boundedStep] + selectedValue)
            // max value is 987, min value is 0
            return adjustedValue
        }
        return Self.fibonacci[boundedStep]
    }
}
