package main

import (
	"testing"

	"github.com/azerothcore/AzerothGhost/client"
)

// TestOnlyTheFixtureItemReachesTheThreshold needs no realm (FR-10.15): a
// corpse with another uncommon or better drop must be killed again, because a
// plan's roll could land on that drop instead (release of 2026-10-26).
func TestOnlyTheFixtureItemReachesTheThreshold(t *testing.T) {
	quality := map[uint32]int{20513: 2, 7078: 2, 22527: 1, 20656: 3}
	clean := []client.LootItem{{Index: 0, ItemID: 20513}, {Index: 1, ItemID: 22527}}
	if extra := extraDrops(clean, 20513, quality, 2); len(extra) != 0 {
		t.Errorf("a grey or white extra must not count: %v", extra)
	}
	dirty := []client.LootItem{{Index: 0, ItemID: 7078}, {Index: 1, ItemID: 20513}, {Index: 2, ItemID: 20656}}
	if extra := extraDrops(dirty, 20513, quality, 2); len(extra) != 2 || extra[0] != 7078 || extra[1] != 20656 {
		t.Errorf("uncommon and rare extras must count: %v", extra)
	}
	unknown := []client.LootItem{{Index: 0, ItemID: 20513}, {Index: 1, ItemID: 99999}}
	if extra := extraDrops(unknown, 20513, quality, 2); len(extra) != 1 {
		t.Errorf("an item of unknown quality must count, so the corpse is never trusted blindly: %v", extra)
	}
	if extra := extraDrops([]client.LootItem{{ItemID: 22527}}, 20513, quality, 2); len(extra) != 1 || extra[0] != 20513 {
		t.Errorf("a corpse without the fixture item must be rejected: %v", extra)
	}
}
