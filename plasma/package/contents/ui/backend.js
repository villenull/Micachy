.pragma library

// Where the checkout's bin/ lives. Empty in the repository on purpose:
// cachyos/install-applet writes the real path into the *installed* copy,
// because kpackagetool copies this package out of the checkout and a path
// relative to this file would then point into ~/.local/share. Left empty,
// main.qml falls back to that relative path, which is right only when the
// package is run straight from the checkout (plasmawindowed plasma/package).
var dir = ""
