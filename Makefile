.PHONY: test test-lua test-go test-fixtures test-catalog check-fixtures fixtures fmt-check

test: test-lua test-fixtures test-catalog check-fixtures test-go

test-lua:
	bash scripts/test-lua.sh

test-fixtures:
	bash scripts/test-fixtures.sh

test-catalog:
	bash scripts/test-catalog.sh

check-fixtures:
	bash scripts/check-fixtures.sh

fixtures:
	bash scripts/generate-fixtures.sh

test-go:
	bash scripts/test-go.sh

fmt-check:
	bash scripts/check-format.sh
