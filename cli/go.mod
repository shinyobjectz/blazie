module github.com/shinyobjectz/blazie/cli

go 1.24

// No requires, and that is the design rather than an accident. Every byte this
// binary needs is in Go's standard library, including the websocket client in
// ws.go — see the note there for why writing ~200 lines of RFC 6455 beat taking
// a dependency for a CLI whose whole promise is `brew install blazie`.
