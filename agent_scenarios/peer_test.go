package main

import (
 "encoding/json"
 "fmt"
 "os"
 "regexp"
 "testing"
 "time"

 _ "github.com/go-sql-driver/mysql"
 "github.com/azerothcore/AzerothGhost/e2e/e2eharness"
)

var safeName = regexp.MustCompile(`^[A-Za-z]{2,12}$`)

func TestPeerTargetFixture(t *testing.T) {
 target := os.Getenv("FORGE_TARGET_CHARACTER")
 ready := os.Getenv("FORGE_PEER_READY")
 release := os.Getenv("FORGE_PEER_RELEASE")
 if !safeName.MatchString(target) || ready == "" || release == "" { t.Fatal("invalid target or fixture synchronization paths") }
 bot := e2eharness.NewSolo(t, e2eharness.ScenarioOpts{Prefix:"FPeer", Race:e2eharness.RaceHuman, Class:e2eharness.ClassWarrior, Level:20})
 bot.GM(t, ".appear "+target)
 bot.FlushWorld(t)
 payload, err := json.Marshal(map[string]string{"name":bot.Name,"target":target,"status":"ready"})
 if err != nil {t.Fatal(err)}
 if err := os.WriteFile(ready,payload,0600); err != nil {t.Fatal(err)}
 fmt.Println("FORGE_PEER_READY")
 deadline := time.Now().Add(120*time.Second)
 for time.Now().Before(deadline) {
   if _,err := os.Stat(release); err == nil { return }
   time.Sleep(200*time.Millisecond)
 }
 t.Fatal("GUI addon test did not release fixture before deadline")
}
