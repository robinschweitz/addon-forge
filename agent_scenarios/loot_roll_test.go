package main

import (
	"encoding/json"
	"os"
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
	// Plans may run steps (rolls, waits) while the loot window stays open.
	deadline := time.Now().Add(150 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(release); err == nil {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("loot fixture was not released after client capture")
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
