package main

import (
	"database/sql"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/azerothcore/AzerothGhost/e2e/e2eharness"
)

var memberAccount = regexp.MustCompile(`^[A-Z][A-Z0-9]{2,15}$`)
var memberCharacter = regexp.MustCompile(`^[A-Z][a-z]{1,11}$`)

// TestCreateMemberAccount creates the second test player for two-client
// scenarios: a new local account (never an existing one: no credentials are
// reset) and one character on it. The password arrives in the environment
// from Forge, which stores it in Windows Credential Manager; it is never logged.
func TestCreateMemberAccount(t *testing.T) {
	user := strings.ToUpper(os.Getenv("FORGE_MEMBER_USER"))
	password := os.Getenv("FORGE_MEMBER_PASSWORD")
	character := os.Getenv("FORGE_MEMBER_CHAR")
	result := os.Getenv("FORGE_MEMBER_RESULT")
	if !memberAccount.MatchString(user) || len(password) < 8 || len(password) > 16 ||
		!memberCharacter.MatchString(character) || result == "" {
		t.Fatal("invalid member account settings")
	}
	db, err := e2eharness.OpenAuthDB()
	if err != nil {
		t.Fatalf("auth database: %v", err)
	}
	defer db.Close()
	var id int
	switch err := db.QueryRow(`SELECT id FROM account WHERE username=?`, user).Scan(&id); {
	case err == nil:
		t.Fatalf("account %s already exists; refusing to change its credentials", user)
	case err != sql.ErrNoRows:
		t.Fatalf("account lookup: %v", err)
	}
	if err := e2eharness.EnsureAccount(db, user, password); err != nil {
		t.Fatalf("create account: %v", err)
	}
	session, err := e2eharness.LoginBot(t, e2eharness.LoginOptions{
		User: user, Password: password, CharName: character, Race: 1, Class: 1,
	})
	if err != nil {
		t.Fatalf("create character: %v", err)
	}
	name := session.Name
	session.Close()
	if err := writeStateAtomic(result, map[string]any{"status": "created", "account": user, "character": name}); err != nil {
		t.Fatalf("could not publish result: %v", err)
	}
	t.Logf("created account %s with character %s", user, name)
}
