package main

import (
	"fmt"
	"io"
	"strings"
)

// The user code, big enough to read from across a desk.
//
// This is not decoration. The one thing a person has to do during a device
// flow is copy eight characters accurately into a browser on another device,
// often on a phone, often while reading them off a laptop behind them. `B` and
// `8` and `S` and `5` at terminal font size is where that goes wrong, and a
// wrong code costs the whole flow and a fresh one.
//
// A 5x5 bitmap per glyph, doubled horizontally because a terminal cell is
// about twice as tall as it is wide and undoubled letters come out squashed.
// Only the characters a device code can contain — GitHub's are uppercase
// letters and digits with a hyphen — and anything outside that set falls back
// to plain text rather than printing a hole.

const bigTypeRows = 5

var bigType = map[rune][bigTypeRows]string{
	'0': {"#####", "#   #", "#   #", "#   #", "#####"},
	'1': {"  #  ", " ##  ", "  #  ", "  #  ", " ### "},
	'2': {"#####", "    #", "#####", "#    ", "#####"},
	'3': {"#####", "    #", " ####", "    #", "#####"},
	'4': {"#   #", "#   #", "#####", "    #", "    #"},
	'5': {"#####", "#    ", "#####", "    #", "#####"},
	'6': {"#####", "#    ", "#####", "#   #", "#####"},
	'7': {"#####", "    #", "   # ", "  #  ", "  #  "},
	'8': {"#####", "#   #", "#####", "#   #", "#####"},
	'9': {"#####", "#   #", "#####", "    #", "#####"},
	'A': {" ### ", "#   #", "#####", "#   #", "#   #"},
	'B': {"#### ", "#   #", "#### ", "#   #", "#### "},
	'C': {" ####", "#    ", "#    ", "#    ", " ####"},
	'D': {"#### ", "#   #", "#   #", "#   #", "#### "},
	'E': {"#####", "#    ", "#### ", "#    ", "#####"},
	'F': {"#####", "#    ", "#### ", "#    ", "#    "},
	'G': {" ####", "#    ", "#  ##", "#   #", " ####"},
	'H': {"#   #", "#   #", "#####", "#   #", "#   #"},
	'I': {"#####", "  #  ", "  #  ", "  #  ", "#####"},
	'J': {"#####", "   # ", "   # ", "#  # ", " ##  "},
	'K': {"#   #", "#  # ", "###  ", "#  # ", "#   #"},
	'L': {"#    ", "#    ", "#    ", "#    ", "#####"},
	'M': {"#   #", "## ##", "# # #", "#   #", "#   #"},
	'N': {"#   #", "##  #", "# # #", "#  ##", "#   #"},
	'O': {" ### ", "#   #", "#   #", "#   #", " ### "},
	'P': {"#### ", "#   #", "#### ", "#    ", "#    "},
	'Q': {" ### ", "#   #", "# # #", "#  # ", " ## #"},
	'R': {"#### ", "#   #", "#### ", "#  # ", "#   #"},
	'S': {" ####", "#    ", " ### ", "    #", "#### "},
	'T': {"#####", "  #  ", "  #  ", "  #  ", "  #  "},
	'U': {"#   #", "#   #", "#   #", "#   #", " ### "},
	'V': {"#   #", "#   #", "#   #", " # # ", "  #  "},
	'W': {"#   #", "#   #", "# # #", "## ##", "#   #"},
	'X': {"#   #", " # # ", "  #  ", " # # ", "#   #"},
	'Y': {"#   #", " # # ", "  #  ", "  #  ", "  #  "},
	'Z': {"#####", "   # ", "  #  ", " #   ", "#####"},
	'-': {"     ", "     ", "#####", "     ", "     "},
}

// BigType renders text as block letters, or returns "" if any character has no
// glyph — the caller falls back to plain text rather than printing a code with
// a gap in it, because a gap in a code is a code that will be typed wrong.
func BigType(text string) string {
	glyphs := make([][bigTypeRows]string, 0, len(text))
	for _, char := range strings.ToUpper(text) {
		glyph, ok := bigType[char]
		if !ok {
			return ""
		}
		glyphs = append(glyphs, glyph)
	}
	if len(glyphs) == 0 {
		return ""
	}

	lines := make([]string, bigTypeRows)
	for row := range bigTypeRows {
		var line strings.Builder
		for i, glyph := range glyphs {
			if i > 0 {
				line.WriteString("  ")
			}
			for _, cell := range glyph[row] {
				if cell == '#' {
					line.WriteString("██")
				} else {
					line.WriteString("  ")
				}
			}
		}
		lines[row] = strings.TrimRight(line.String(), " ")
	}

	return strings.Join(lines, "\n")
}

// WriteUserCode shows the code the way it most wants to be read: big if it can
// be, and always again in plain text underneath so it can be selected, copied
// and pasted. The block letters are for eyes; the plain line is for the mouse.
func WriteUserCode(w io.Writer, code string) {
	s := styleFor(w)

	if big := BigType(code); big != "" {
		fmt.Fprintf(w, "\n%s\n", indent(big, "    "))
	}

	fmt.Fprintf(w, "\n    %s\n", s.bold(code))
}
