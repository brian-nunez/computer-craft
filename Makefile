.PHONY: test test-lua test-go test-fixtures test-catalog fmt-check

test: test-lua test-fixtures test-catalog test-go

test-lua:
	bash scripts/test-lua.sh

test-fixtures:
	bash scripts/test-fixtures.sh

test-catalog:
	bash scripts/test-catalog.sh

test-go:
	bash scripts/test-go.sh

fmt-check:
	bash scripts/check-format.sh
