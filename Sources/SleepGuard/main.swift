import Cocoa
import Foundation

if CommandLine.arguments.contains("--version") {
    print("SleepGuard 1.0.0")
    exit(0)
}

if CommandLine.arguments.contains("--help") {
    print("""
    SleepGuard — Ultra-lightweight macOS keep-awake menu bar utility
    Usage:
      SleepGuard           Launch in menu bar
      SleepGuard --open    Launch and open popover immediately
      SleepGuard --version Show version
    """)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
