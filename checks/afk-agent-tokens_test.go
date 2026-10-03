// Compiled into the pinned afk-agent source by ./afk-agent-tokens.nix, which
// says why this repository asks it.
package dotfilescheck

import (
	"testing"

	"github.com/corygyarmathy/afk-agent/internal/implement"
	"github.com/corygyarmathy/afk-agent/internal/revise"
	"github.com/corygyarmathy/afk-agent/internal/transition"
)

func TestBuildingTransitionsHoldHeavyBuild(t *testing.T) {
	// The capacity modules/services/afk-agent.nix sets is keyed by this name.
	if transition.HeavyBuild != "heavy-build" {
		t.Fatalf("the heavy-build token is named %q, not the module's heavy-build", transition.HeavyBuild)
	}

	held := map[string]bool{}
	for _, kind := range [][]transition.Transition{
		implement.Transitions(&implement.Deps{}),
		revise.Transitions(&revise.Deps{}),
	} {
		for _, tr := range kind {
			for _, tok := range tr.Tokens {
				if tok == transition.HeavyBuild {
					held[tr.Name] = true
				}
			}
		}
	}

	for _, name := range []string{"implement-run", "implement-gate", "revise-run", "revise-gate"} {
		if !held[name] {
			t.Errorf("%s is not registered holding %s", name, transition.HeavyBuild)
		}
	}
}
