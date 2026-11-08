import AppKit

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }

if let first = args.first, !first.hasPrefix("-psn") {
    exit(CLI.run(args))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
