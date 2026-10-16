package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/azerothcore/AzerothGhost/client"
	"github.com/azerothcore/AzerothGhost/e2e/e2eharness"
)

// TestLootRollFixture designates the graphical character as master looter and
// leaves a real lootable corpse for the client to open.
func TestLootRollFixture(t *testing.T) {
	target, ready, release := os.Getenv("FORGE_TARGET_CHARACTER"), os.Getenv("FORGE_LOOT_READY"), os.Getenv("FORGE_LOOT_RELEASE")
	if !safeName.MatchString(target) || ready == "" || release == "" {
		t.Fatal("invalid loot fixture synchronization settings")
	}
	bots := e2eharness.NewScenario(t, e2eharness.ScenarioOpts{Prefix: "FLoot", Race: e2eharness.RaceHuman, Class: e2eharness.ClassWarrior, Level: 20, Count: 1})
	bot := bots[0]
	bot.GM(t, ".appear "+target)
	if err := bot.World.GroupInvite(target); err != nil {
		t.Fatalf("group invite: %v", err)
	}
	if err := writeStateAtomic(ready, map[string]any{"status": "invite_sent", "bot": bot.Name}); err != nil {
		t.Fatalf("could not publish invite readiness: %v", err)
	}
	group := bot.WaitGroupList(t, true, 2, 45*time.Second)
	if group.MemberCount < 2 {
		t.Fatal("graphical character did not join party")
	}
	var master uint64
	for _, member := range group.Members {
		if member.Name == target {
			master = member.GUID
		}
	}
	if master == 0 {
		t.Fatal("graphical character GUID missing from group roster")
	}
	bot.SetLootMethod(t, client.LootMethodMasterLoot, master, e2eharness.LootThresholdUncommon)
	corpse := bot.SpawnKillLootable(t, e2eharness.CreatureGroupLootFixture, 45*time.Second)
	names := corpseNames(t, e2eharness.CreatureGroupLootFixture, os.Getenv("FORGE_CLIENT_LOCALE"))
	if err := writeStateAtomic(ready, map[string]any{"status": "master_loot_ready", "item": e2eharness.ItemGroupLootFixture, "corpse": corpse, "names": names}); err != nil {
		t.Fatalf("could not publish loot readiness: %v", err)
	}
	// Plans may run steps (rolls, waits, peer actions) while the loot window
	// stays open. Peer actions arrive as numbered command files.
	commands := os.Getenv("FORGE_LOOT_COMMANDS")
	deadline := time.Now().Add(240 * time.Second)
	next := 1
	for time.Now().Before(deadline) {
		if _, err := os.Stat(release); err == nil {
			return
		}
		if commands != "" {
			path := filepath.Join(commands, fmt.Sprintf("cmd-%03d.json", next))
			if data, err := os.ReadFile(path); err == nil {
				armed := filepath.Join(commands, fmt.Sprintf("cmd-%03d.armed", next))
				result := runPeerCommand(bot, data, func() { _ = writeStateAtomic(armed, map[string]any{"armed": true}) })
				t.Logf("peer command %d: %s -> %s", next, data, result)
				done := filepath.Join(commands, fmt.Sprintf("cmd-%03d.done.json", next))
				if err := writeStateAtomic(done, map[string]any{"result": result}); err != nil {
					t.Fatalf("could not publish peer command result: %v", err)
				}
				next++
				continue
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("loot fixture was not released after client capture")
}

// msgRandomRoll is MSG_RANDOM_ROLL (AzerothCore Opcodes.h, 0x1FB): the client
// sends uint32 min, uint32 max and the server broadcasts the result to the group.
const msgRandomRoll = 0x1FB

type peerCommand struct {
	Action string `json:"action"`
	Min    uint32 `json:"min"`
	Max    uint32 `json:"max"`
}

// runPeerCommand performs one fixed bot action and returns "ok" or a short
// reason. Failures are reported to the plan, never fatal for the fixture.
// armed is called once the bot listens for trade statuses: the graphical client
// must not initiate a trade before that, or BEGIN_TRADE arrives unobserved.
func runPeerCommand(bot *e2eharness.ScenarioBot, data []byte, armed func()) string {
	var cmd peerCommand
	if err := json.Unmarshal(data, &cmd); err != nil {
		return "bad_command"
	}
	switch cmd.Action {
	case "roll":
		if cmd.Min < 1 || cmd.Min > cmd.Max || cmd.Max > 10000 {
			return "bad_range"
		}
		payload := make([]byte, 8)
		binary.LittleEndian.PutUint32(payload[0:], cmd.Min)
		binary.LittleEndian.PutUint32(payload[4:], cmd.Max)
		if err := bot.World.SendPacketRaw(msgRandomRoll, payload); err != nil {
			return "send_failed"
		}
		return "ok"
	case "open_trade":
		// The graphical client initiates; the bot answers BEGIN_TRADE.
		statuses, cancel := watchTrade(bot.World)
		defer cancel()
		armed()
		if !waitStatus(statuses, client.TradeStatusBeginTrade, 15*time.Second) {
			return "no_begin_trade"
		}
		if err := bot.World.BeginTrade(); err != nil {
			return "begin_failed"
		}
		if !waitStatus(statuses, client.TradeStatusOpenWindow, 5*time.Second) {
			return "no_open_window"
		}
		return "ok"
	case "accept_trade":
		statuses, cancel := watchTrade(bot.World)
		defer cancel()
		if err := bot.World.AcceptTrade(); err != nil {
			return "accept_failed"
		}
		if !waitStatus(statuses, client.TradeStatusTradeComplete, 20*time.Second) {
			return "trade_not_completed:" + client.TradeStatusName(bot.World.LastTradeStatus().Status)
		}
		return "ok"
	}
	return "unknown_action"
}

// watchTrade delivers every SMSG_TRADE_STATUS from now on, so short-lived
// statuses are not missed between polls.
func watchTrade(w *client.WorldClient) (<-chan uint32, func()) {
	statuses := make(chan uint32, 32)
	cancel := w.AddTradeStatusHook(func(info client.TradeStatusInfo) {
		select {
		case statuses <- info.Status:
		default:
		}
	})
	return statuses, cancel
}

func waitStatus(statuses <-chan uint32, want uint32, timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case status := <-statuses:
			if status == want {
				return true
			}
		case <-timer.C:
			return false
		}
	}
}

// writeStateAtomic replaces the handshake file in one rename so the polling
// Python side never reads a partially written JSON document.
func writeStateAtomic(path string, state map[string]any) error {
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

var clientLocale = regexp.MustCompile(`^[a-z]{2}[A-Z]{2}$`)

// corpseNames returns the names the graphical client can target the corpse by:
// the server sends creature names in the client's locale, so look that up
// first, then fall back to the default name. Fixed read-only queries only.
func corpseNames(t *testing.T, entry any, locale string) []string {
	names := []string{}
	db, err := e2eharness.OpenWorldDB()
	if err != nil {
		t.Logf("world DB unavailable for corpse names: %v", err)
		return names
	}
	defer db.Close()
	var name string
	if clientLocale.MatchString(locale) && locale != "enUS" && locale != "enGB" {
		err := db.QueryRow("SELECT Name FROM creature_template_locale WHERE entry = ? AND locale = ?", entry, locale).Scan(&name)
		if err == nil && name != "" {
			names = append(names, name)
		} else {
			t.Logf("no %s name for creature %v: %v", locale, entry, err)
		}
	}
	if err := db.QueryRow("SELECT name FROM creature_template WHERE entry = ?", entry).Scan(&name); err == nil && name != "" {
		names = append(names, name)
	}
	return names
}
