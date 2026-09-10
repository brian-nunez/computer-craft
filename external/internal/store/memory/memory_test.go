package memory_test

import (
	"testing"

	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/store/memory"
	"github.com/brian-nunez/computer-craft/external/internal/store/storetest"
)

func TestMemoryStore(t *testing.T) {
	storetest.Run(t, func(t *testing.T) store.Store {
		return memory.New()
	})
}
