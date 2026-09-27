import Foundation
import HUDKit

// `scratch <command> [key=value ...]`: talks to Scratch's MacHUD control socket.
//
//   scratch hello
//   scratch state
//   echo "some text" | scratch append          # onto the inbox pad, under a timestamp
//   scratch append text="one line" show=1
//   git diff | scratch new title="the diff"
//   scratch list
//   scratch get id=inbox
//   scratch open id=<id>
//   scratch panel mode id=pad compact
//   scratch watch
//   scratch quit

let usage = """
usage: scratch <command> [key=value ...]
  hello | state | help | quit
  panel show|hide|toggle id=pad
  panel frame id=pad x= y= w= h=
  panel mode id=pad full|compact|parked
  append [text=] [id=] [show=1]     text from stdin when text= is absent
  new [text=] [title=] [show=1]     text from stdin when text= is absent and stdin is piped
  open id=                          select a pad and show the panel
  list [query=]                     pads, pinned first then most recent
  get [id=]                         one pad including its body (default: the selected pad)
  body [id=]                        print just the body (default: the selected pad)
  clear [id=]                       empty a pad, keeping it (default: the selected pad)
  action drop "paths=/a%20b.txt|/c.png"   a pad per file, as if dropped on the panel
                                    (percent-encoded paths joined with |, HUDDrop.encode)
  action <verb> [k=v ...]           the long form of the above
  settings get [key=]  |  settings set key=value ...
  watch [events=state]              stream events (Ctrl-C to stop)

Environment: SCRATCH_SOCKET picks the socket name (default scratch).

"""

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "ctl" { arguments.removeFirst() }
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socketName = ProcessInfo.processInfo.environment["SCRATCH_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "scratch"
let path = HUDSocket.path(for: socketName)
/// The server reads request lines of up to 1,000,000 bytes.
let maxPayload = 900_000

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("scratch: \(message)\n".utf8))
    exit(status)
}

/// "not running", or the real reason (a socket path over 103 bytes, ...), then exit 1.
func notReachable(_ error: Error) -> Never {
    FileHandle.standardError.write(Data((HUDSocketClient.failureMessage(for: error, path: path, appName: "scratch") + "\n").utf8))
    exit(1)
}

func readStdin() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else { fail("stdin is not UTF-8 text") }
    return text
}

// Top-level shorthands for the app's actions.
let shorthands: Set<String> = ["append", "new", "open", "list", "get", "body", "clear"]
if shorthands.contains(command) {
    let verb = command == "body" ? "get" : command
    var rest = Array(arguments.dropFirst())
    let hasText = rest.contains { $0.hasPrefix("text=") }
    let piped = isatty(FileHandle.standardInput.fileDescriptor) == 0
    if verb == "append", !hasText {
        if !piped { fail("append needs text= or text on stdin, e.g. `pbpaste | scratch append`", status: 2) }
        rest.append("text=" + readStdin())
    } else if verb == "new", !hasText, piped {
        rest.append("text=" + readStdin())
    }
    if let text = rest.first(where: { $0.hasPrefix("text=") }), text.utf8.count > maxPayload {
        fail("text is too large for the socket (\(text.utf8.count) bytes; limit about \(maxPayload))")
    }
    arguments = ["action", "name=\(verb)"] + rest
    if command == "body" {
        do {
            let response = try HUDSocketClient(path: path, timeout: 0)
                .request("action", args: HUDSocketClient.parseArguments(Array(arguments.dropFirst())))
            guard response["ok"] as? Bool == true, let pad = response["pad"] as? [String: Any],
                  let body = pad["body"] as? String else {
                fail(response["error"] as? String ?? "no such pad")
            }
            FileHandle.standardOutput.write(Data(body.utf8))
            exit(0)
        } catch {
            notReachable(error)
        }
    }
} else if command == "settings", arguments.count > 1, ["get", "set"].contains(arguments[1]) {
    // Send the sub-verb as `action=`, what MacHUD sends. The bare form works as well (the
    // router strips the parser's positional `_` along with `set`/`get`); this keeps the
    // request the same as MacHUD's.
    arguments[1] = "action=\(arguments[1])"
} else if command == "action", arguments.count > 1, !arguments[1].contains("=") {
    // `action append ...` is shorthand for `action name=append ...`.
    arguments[1] = "name=\(arguments[1])"
}

if command == "watch" {
    let args = HUDSocketClient.parseArguments(Array(arguments.dropFirst()))
    do {
        _ = try HUDSocketClient(path: path).subscribe(
            events: args["events"].map { $0.split(separator: ",").map(String.init) },
            onEvent: { event in
                if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                    fflush(stdout)
                }
            },
            onClose: { exit(0) }
        )
    } catch {
        notReachable(error)
    }
    dispatchMain()
}

exit(HUDSocketClient.runCLI(path: path, arguments: arguments, appName: "scratch"))
