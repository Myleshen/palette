import AppKit
import Darwin

// Palette writes tool stdin (`fzf`, providers). A child that exits first turns
// that write into EPIPE, whose default action would kill Palette without a
// crash report. Ignore it once here; the write helpers still report the short
// write so a dead child is visible in palette.log.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
