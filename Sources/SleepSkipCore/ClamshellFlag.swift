import Foundation
import IOKit
import IOKit.pwr_mgt

/// Suppresses lid-close sleep without any authorization, by setting
/// `kPMSetClamshellSleepState` (IOPMrootDomain selector 12).
///
/// Measured behaviour (see `docs/CLAMSHELL-RESEARCH.md`):
///
/// - Holds indefinitely while the power source is steady.
/// - **The machine sleeps 6–9 s after a cable is plugged back in with the lid already closed.**
///   powerd re-evaluates the lid on a power change and does not consult this flag on that path.
///   Re-arming every second does not help; the decision is already made by then. Never Sleep
///   has the identical limit.
///
/// Re-arming on power-source changes is still worthwhile: it shortens the exposure when the
/// lid is opened and closed again after a cable swap, and it costs ~52 µs per call.
public enum ClamshellFlag {
    /// Selector 12 on the IOPMrootDomain user client. Declared in the public SDK header
    /// `IOKit/pwr_mgt/IOPMLibDefs.h`, but with no `IOPMLib` wrapper.
    static let setClamshellSleepState: UInt32 = 12

    /// Sets "lid close does not cause sleep". Returns false when the call fails, which is the
    /// only signal available — the flag is not published anywhere readable.
    @discardableResult
    public static func setLidSleepSuppressed(_ suppressed: Bool) -> Bool {
        let connection = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connection != 0 else { return false }
        defer { IOServiceClose(connection) }
        var value: UInt64 = suppressed ? 1 : 0
        let result = IOConnectCallScalarMethod(
            connection,
            setClamshellSleepState,
            &value,
            1,
            nil,
            nil
        )
        return result == KERN_SUCCESS
    }
}
