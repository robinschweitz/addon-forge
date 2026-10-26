package main

import "testing"

// TestSayTextIsNeverACommand needs no realm: peer_say text from a plan is
// spoken by a GM bot, so it must never reach the server as a command (T-026).
func TestSayTextIsNeverACommand(t *testing.T) {
	for _, ok := range []string{"roll", "Roll now: MS 100, OS 99. Don't wait!", "a"} {
		if _, err := sayMessage(ok, ""); err != nil {
			t.Errorf("%q refused: %v", ok, err)
		}
	}
	for _, bad := range []string{".additem 1", "!kick Test", "/rw hi", "roll |cffff0000x", "", " roll",
		"würfel", "roll\nnow", "-roll", "7 roll", string(make([]byte, 61))} {
		if _, err := sayMessage(bad, ""); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	msg, err := sayMessage("roll", itemLink(20513, "Abyssal Crest", 4))
	want := "roll |cffa335ee|Hitem:20513:0:0:0:0:0:0:0:0|h[Abyssal Crest]|h|r"
	if err != nil || msg != want {
		t.Errorf("got %q, %v; want %q", msg, err, want)
	}
	if itemLink(1, "Bad|Name", 4) != "" || itemLink(1, "Bad]Name", 4) != "" || itemLink(1, "", 4) != "" {
		t.Error("an item name with an escape or bracket must not become a link")
	}
}
