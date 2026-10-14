package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"testing"
	"time"

	_ "github.com/go-sql-driver/mysql"

	"github.com/azerothcore/AzerothGhost/e2e/e2eharness"
)

var safeName = regexp.MustCompile(`^[A-Za-z]{2,12}$`)

// TestPeerTargetFixture keeps a small group of real protocol clients online
// while ForgeTestBridge checks the graphical WoW client. All Go sessions are
// closed by the upstream harness's testing cleanup after the release signal.
func TestPeerTargetFixture(t *testing.T) {
	target := os.Getenv("FORGE_TARGET_CHARACTER")
	ready := os.Getenv("FORGE_PEER_READY")
	release := os.Getenv("FORGE_PEER_RELEASE")
	if !safeName.MatchString(target) || ready == "" || release == "" {
		t.Fatal("invalid target or fixture synchronization paths")
	}
	count := 1
	if value := os.Getenv("FORGE_PEER_COUNT"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 1 || parsed > 4 {
			t.Fatal("FORGE_PEER_COUNT must be between 1 and 4")
		}
		count = parsed
	}

	bots := e2eharness.NewScenario(t, e2eharness.ScenarioOpts{
		Prefix: "FPeer",
		Race:   e2eharness.RaceHuman,
		Class:  e2eharness.ClassWarrior,
		Level:  20,
		Count:  count,
	})
	names := make([]string, 0, len(bots))
	for _, bot := range bots {
		bot.GM(t, ".appear "+target)
		bot.FlushWorld(t)
		if !safeName.MatchString(bot.Name) {
			t.Fatalf("harness returned invalid peer character name")
		}
		names = append(names, bot.Name)
	}
	if count > 1 {
        e2eharness.FormParty(t, bots[0], bots[1:]...)
        bots[0].WaitGroupList(t, true, count, 10*time.Second)
    }
    if len(names) != count {
		t.Fatalf("harness created %d players, requested %d", len(names), count)
	}

	// Both a legacy single 'name' field and the modern 'names' list are
	// provided to keep the handshake compatible during project upgrades.
	payload, err := json.Marshal(struct {
		Version int      `json:"version"`
		Status  string   `json:"status"`
		Name    string   `json:"name"`
		Names   []string `json:"names"`
		Count   int      `json:"count"`
		Target  string   `json:"target"`
	}{
		Version: 2,
		Status:  "ready",
		Name:    names[0],
		Names:   names,
		Count:   len(names),
		Target:  target,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ready, payload, 0600); err != nil {
		t.Fatal(err)
	}
	fmt.Println("FORGE_PEER_READY")
    // Optional stage marker for a reusable fixture lifecycle. Python writes
    // request-leave only after observing the full party; the bot that leaves
    // is chosen from our own disposable test peers, never the GUI character.
    leave := os.Getenv("FORGE_PEER_LEAVE")
    left := os.Getenv("FORGE_PEER_LEFT")
    didLeave := false

	deadline := time.Now().Add(120 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(release); err == nil {
            return
        }
        if !didLeave && count > 1 && leave != "" && left != "" {
            if _, err := os.Stat(leave); err == nil {
                bots[count-1].LeaveGroup(t)
                bots[count-1].WaitNotInGroup(t, 10*time.Second)
                bots[0].WaitGroupList(t, true, count-1, 10*time.Second)
                if err := os.WriteFile(left, []byte("left"), 0600); err != nil { t.Fatal(err) }
                didLeave = true
            }
        }
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("GUI addon test did not release fixture before deadline")
}
