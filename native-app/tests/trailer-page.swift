import Foundation

// Run: swiftc -swift-version 5 Sources/LocalHTTPServer.swift Sources/CatalogSupport.swift tests/trailer-page.swift -o /tmp/trailer-page && /tmp/trailer-page
@main
struct TrailerPageChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        let html = LocalHTTPServer.trailerHTML(videoId: "wXzhEhCOlnM", origin: "http://127.0.0.1:5555")
        check(html.contains("https://www.youtube-nocookie.com/embed/wXzhEhCOlnM?"), "embeds the privacy-enhanced YouTube player for that id")
        check(html.contains("mute=1") && html.contains("autoplay=1") && html.contains("controls=0"), "starts muted, on its own, without controls")
        check(html.contains("origin=http://127.0.0.1:5555"), "gives YouTube a real http origin")
        check(html.contains("sandbox=\"allow-scripts allow-same-origin allow-presentation\""), "the player is sandboxed")
        check(!html.contains("allow-popups") && !html.contains("allow-top-navigation") && !html.contains("allow-forms"), "no popups, top navigation or forms")
        check(html.contains("pointer-events: none"), "the player never takes clicks from the billboard")
        // The page tells its parent whether the video really plays, so a blocked embed never covers the artwork.
        check(html.contains("vibeTrailerState") && html.contains("report('playing')") && html.contains("report('error')"), "reports playing and error to the catalogue")
        check(html.contains("event.source !== parent"), "only the parent window may send it commands")
        // Hosts: the player, its API origin and nothing else.
        let hosts = Set(html.components(separatedBy: "https://").dropFirst().compactMap { $0.components(separatedBy: CharacterSet(charactersIn: "/?\"' ")).first })
        check(hosts == ["www.youtube-nocookie.com"], "only one external host is mentioned: \(hosts)")
        check(!html.contains("<script src"), "no external scripts")
        print("Trailer page passed: player URL, sandbox, state reporting, parent-only commands and a single external host")
    }
}
