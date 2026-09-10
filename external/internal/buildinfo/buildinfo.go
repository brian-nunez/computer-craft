// Package buildinfo contains release metadata shared by CraftNet commands.
package buildinfo

// Version is the release this binary is. It is a var rather than a const so a
// release build can stamp the tag into it with -ldflags, and so that a binary
// built any other way says so: a development build reports itself as one rather
// than claiming to be a release nobody cut.
var Version = "0.1.0-dev"

// WireVersion is the CraftNet protocol version this build speaks. It is a
// constant on purpose: changing it is a wire decision, not a build flag.
const WireVersion = 1
