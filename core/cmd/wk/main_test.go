package main

import "testing"

func TestFlagsAfterPositionalArguments(t *testing.T) {
	command := newCLI("open")
	session := command.set.String("session", "", "")
	fresh := command.set.Bool("new", false, "")
	if err := command.parse([]string{"5346", "--session", "abc", "--new", "--json"}); err != nil {
		t.Fatal(err)
	}
	if len(command.args) != 1 || command.args[0] != "5346" {
		t.Errorf("args = %v", command.args)
	}
	if *session != "abc" || !*fresh || !*command.json {
		t.Errorf("session=%q new=%v json=%v", *session, *fresh, *command.json)
	}
}
