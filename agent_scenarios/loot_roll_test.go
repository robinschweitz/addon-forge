package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
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
	// A dead test character cannot loot (run of 2026-10-20: it had died to a
	// leftover fixture creature, and the plan failed at "loot did not open").
	// .revive leaves a living character as it is.
	revive := func() {
		bot.GM(t, ".revive "+target)
		if member := os.Getenv("FORGE_MEMBER_CHARACTER"); member != "" && safeName.MatchString(member) {
			bot.GM(t, ".revive "+member)
		}
	}
	revive()
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
	// A two-player plan's second client: summoned next to the corpse-to-be (loot
	// is only distributed to members in range) and invited into the party.
	if member := os.Getenv("FORGE_MEMBER_CHARACTER"); member != "" {
		if !safeName.MatchString(member) || member == target {
			t.Fatal("invalid member character")
		}
		bot.GM(t, ".summon "+member)
		if err := bot.World.GroupInvite(member); err != nil {
			t.Fatalf("member group invite: %v", err)
		}
		if err := writeStateAtomic(ready, map[string]any{"status": "member_invite_sent", "bot": bot.Name}); err != nil {
			t.Fatalf("could not publish member invite readiness: %v", err)
		}
		group = bot.WaitGroupList(t, true, 3, 45*time.Second)
		if group.MemberCount < 3 {
			t.Fatal("member character did not join party")
		}
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
	// The raid_lead fixture: the graphical character leads the party, so it
	// can invite, convert to a raid and sort groups like a real raid lead.
	if os.Getenv("FORGE_LEAD_TO_TARGET") == "1" {
		// Characters below level 10 cannot form a raid.
		bot.GM(t, ".character level "+target+" 10")
		if member := os.Getenv("FORGE_MEMBER_CHARACTER"); member != "" {
			bot.GM(t, ".character level "+member+" 10")
		}
		if err := bot.World.GroupSetLeader(master); err != nil {
			t.Fatalf("hand party leadership: %v", err)
		}
		time.Sleep(time.Second)
	}
	creature, item := e2eharness.CreatureGroupLootFixture, e2eharness.ItemGroupLootFixture
	if os.Getenv("FORGE_LOOT_BOE") == "1" {
		creature, item = boeLootCreature, boeLootItem
		requireBoeLoot(t)
	}
	// FR-10.15: the plan's roll must land on the fixture item, so a corpse with
	// another uncommon or better drop (Crimson Templar also drops Essence of
	// Fire and cloth tokens) is removed and a new creature killed.
	var corpse uint64
	for attempt := 1; ; attempt++ {
		corpse = bot.SpawnKillLootable(t, creature, 45*time.Second)
		// Registered after SpawnKillLootable, so it runs before the harness's own
		// cleanup (SQL delete, then an unconfirmed `.npc delete`).
		guid := corpse
		t.Cleanup(func() { removeLiveCorpse(t, bot, guid) })
		extra := corpseExtras(t, bot, corpse, item)
		if len(extra) == 0 {
			t.Logf("corpse 0x%X holds only item %d at or above the master-loot threshold (kill %d)", corpse, item, attempt)
			break
		}
		t.Logf("corpse 0x%X also holds %v at or above the master-loot threshold (kill %d)", corpse, extra, attempt)
		if attempt == maxFixtureKills {
			t.Fatalf("no corpse with only item %d after %d kills", item, maxFixtureKills)
		}
		removeLiveCorpse(t, bot, corpse)
	}
	// The creature spawns next to the level-10 test characters and can kill
	// one before .damage lands (RaidWishlist run 905688594b78, 2026-10-20).
	revive()
	names := corpseNames(t, creature, os.Getenv("FORGE_CLIENT_LOCALE"))
	if err := writeStateAtomic(ready, map[string]any{"status": "master_loot_ready", "item": item, "corpse": corpse, "names": names}); err != nil {
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

// removeLiveCorpse deletes the fixture creature from the running world and
// waits until the bot sees it vanish. The harness deletes only the DB row for
// sure: its `.npc delete` is unconfirmed, and a corpse it missed stayed in the
// world, respawned alive and killed the Northshire guards.
func removeLiveCorpse(t *testing.T, bot *e2eharness.ScenarioBot, guid uint64) {
	if guid == 0 || bot.World == nil || bot.World.IsStopped() {
		t.Errorf("fixture creature 0x%X may still be in the world: bot session gone before cleanup", guid)
		return
	}
	for attempt := 1; attempt <= 3; attempt++ {
		if bot.World.GetObject(guid) == nil {
			t.Logf("fixture creature 0x%X removed from the world", guid)
			return
		}
		_ = bot.World.SendGMCommand(".gm on")
		_ = bot.World.SetTarget(guid)
		time.Sleep(100 * time.Millisecond)
		_ = bot.World.SendGMCommand(".npc delete")
		for end := time.Now().Add(3 * time.Second); time.Now().Before(end); time.Sleep(100 * time.Millisecond) {
			if bot.World.GetObject(guid) == nil {
				t.Logf("fixture creature 0x%X removed from the world (attempt %d)", guid, attempt)
				return
			}
		}
	}
	t.Errorf("fixture creature 0x%X is still in the world after 3 .npc delete attempts; restart the worldserver", guid)
}

// maxFixtureKills bounds the re-kills for a corpse with extra drops: Crimson
// Templar's group-1 loot (one drop per kill, about 37%, nearly all uncommon)
// plus world-loot references give an extra drop in roughly 40% of kills, so
// eight kills fail about once in 1,500 runs.
const maxFixtureKills = 8

// extraDrops lists the drops other than want at or above threshold. An item of
// unknown quality counts, and a corpse without want reports want itself, so
// the fixture never trusts a corpse it could not check.
func extraDrops(items []client.LootItem, want uint32, quality map[uint32]int, threshold int) []uint32 {
	extra, found := []uint32{}, false
	for _, item := range items {
		if item.ItemID == want {
			found = true
			continue
		}
		if q, ok := quality[item.ItemID]; !ok || q >= threshold {
			extra = append(extra, item.ItemID)
		}
	}
	if !found {
		return []uint32{want}
	}
	return extra
}

// corpseExtras opens the corpse's loot as the bot (a group member may look
// under master loot), releases it again and checks every drop's quality with
// a fixed read-only query.
func corpseExtras(t *testing.T, bot *e2eharness.ScenarioBot, corpse uint64, want uint32) []uint32 {
	items, ok := bot.TryOpenLoot(t, corpse, 10*time.Second)
	_ = bot.World.LootRelease(corpse)
	if !ok {
		t.Logf("bot could not open corpse 0x%X to check its loot", corpse)
		return []uint32{want}
	}
	quality := map[uint32]int{}
	if db, err := e2eharness.OpenWorldDB(); err == nil {
		defer db.Close()
		for _, it := range items {
			var q int
			if db.QueryRow("SELECT Quality FROM item_template WHERE entry = ?", it.ItemID).Scan(&q) == nil {
				quality[it.ItemID] = q
			}
		}
	}
	return extraDrops(items, want, quality, int(e2eharness.LootThresholdUncommon))
}

// The boe_loot variant: The Rake (5807), a stock level-10 rare whose loot
// table drops Lionfur Armor (17922, uncommon, binds when equipped) at 100%.
// Stock world data, so no realm change is needed; its other fixed drops are
// grey and stay below the master-loot threshold.
const (
	boeLootCreature uint32 = 5807
	boeLootItem     uint32 = 17922
)

// requireBoeLoot confirms with fixed read-only queries that the realm's world
// data still guarantees the bind-on-equip drop, so a changed loot table fails
// the fixture instead of silently dropping something else.
func requireBoeLoot(t *testing.T) {
	db, err := e2eharness.OpenWorldDB()
	if err != nil {
		t.Fatalf("world DB unavailable to confirm the BoE drop: %v", err)
	}
	defer db.Close()
	var chance float64
	var quality, bonding int
	err = db.QueryRow("SELECT l.Chance, i.Quality, i.bonding FROM creature_loot_template l "+
		"JOIN creature_template c ON c.lootid = l.Entry JOIN item_template i ON i.entry = l.Item "+
		"WHERE c.entry = ? AND l.Item = ? AND l.Reference = 0 AND l.GroupId = 0 AND l.QuestRequired = 0",
		boeLootCreature, boeLootItem).Scan(&chance, &quality, &bonding)
	if err != nil || chance < 100 || quality < int(e2eharness.LootThresholdUncommon) || bonding != 2 {
		t.Fatalf("creature %d no longer drops BoE item %d at 100%% (chance=%v quality=%d bonding=%d err=%v)",
			boeLootCreature, boeLootItem, chance, quality, bonding, err)
	}
}

// msgRandomRoll is MSG_RANDOM_ROLL (AzerothCore Opcodes.h, 0x1FB): the client
// sends uint32 min, uint32 max and the server broadcasts the result to the group.
const msgRandomRoll = 0x1FB

type peerCommand struct {
	Action string `json:"action"`
	Min    uint32 `json:"min"`
	Max    uint32 `json:"max"`
	Text   string `json:"text"`
	Item   uint32 `json:"item"`
}

// sayText is the only text the GM bot may speak for peer_say (SC-014, T-026):
// it starts with a letter, so it is never a GM (. !) or slash command, and it
// holds no '|' escape. Forge checks the same rule before it writes the command.
var sayText = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9 ,.:!?'-]{0,59}$`)

// qualityColors are the 3.3.5a item quality colors (ITEM_QUALITY_COLORS).
var qualityColors = []string{"9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000", "e6cc80", "e6cc80"}

// itemLink builds a client item link from realm item data, or "" when the
// data could break the link.
func itemLink(entry uint32, name string, quality int) string {
	if entry == 0 || name == "" || strings.ContainsAny(name, "|[]") || quality < 0 || quality >= len(qualityColors) {
		return ""
	}
	return fmt.Sprintf("|cff%s|Hitem:%d:0:0:0:0:0:0:0:0|h[%s]|h|r", qualityColors[quality], entry, name)
}

// sayMessage checks the plan's text and appends the bot-built link.
func sayMessage(text, link string) (string, error) {
	if !sayText.MatchString(text) {
		return "", fmt.Errorf("text not allowed")
	}
	if link == "" {
		return text, nil
	}
	return text + " " + link, nil
}

// linkForItem reads the item's name and quality with a fixed read-only query.
func linkForItem(entry uint32) string {
	db, err := e2eharness.OpenWorldDB()
	if err != nil {
		return ""
	}
	defer db.Close()
	var name string
	var quality int
	if err := db.QueryRow("SELECT name, Quality FROM item_template WHERE entry = ?", entry).Scan(&name, &quality); err != nil {
		return ""
	}
	return itemLink(entry, name, quality)
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
	case "say":
		link := ""
		if cmd.Item != 0 {
			if link = linkForItem(cmd.Item); link == "" {
				return "unknown_item"
			}
		}
		message, err := sayMessage(cmd.Text, link)
		if err != nil {
			return "bad_text"
		}
		// The fixture's bot is a Human (RaceHuman above), so it speaks Common;
		// party chat only, never say, yell or a channel.
		if err := bot.World.SendChatMessage(client.ChatMsgParty, client.LangCommon, message); err != nil {
			return "send_failed"
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
