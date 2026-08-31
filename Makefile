BASH ?= bash
MARKDOWNLINT ?= markdownlint-cli2
YAMLLINT ?= yamllint
CSPELL ?= cspell

.PHONY: lint validate test test-unit test-toolchain

# Lint tracked Markdown, JSON, YAML, and shell scripts, and spell-check
# everything tracked.
# `bash -n` only parses its first file argument, so feed it one at a time.
lint:
	git ls-files -z -- '*.md' ':!.claude/plans/*' ':!.cursor/plans/*' | xargs -0 $(MARKDOWNLINT)
	git ls-files -z -- '*.json' | xargs -0 -n1 jq empty
	git ls-files -z -- '*.yaml' '*.yml' | xargs -0 $(YAMLLINT)
	git ls-files -z -- '*.sh' 'scripts/*' | xargs -0 shellcheck --enable=all
	git ls-files -z -- '*.sh' 'scripts/*' | xargs -0 -n1 bash -n
	git ls-files -z | xargs -0 $(CSPELL) --no-progress
	spec_version="$$(grep -m1 '^version:' sbxclaude/spec.yaml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
	changelog_version="$$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
	if [ -z "$$spec_version" ]; then \
		echo "lint: could not find version: in sbxclaude/spec.yaml" >&2; exit 1; \
	elif [ -z "$$changelog_version" ]; then \
		echo "lint: could not find a ## [X.Y.Z] release heading in CHANGELOG.md" >&2; exit 1; \
	elif [ "$$spec_version" != "$$changelog_version" ]; then \
		echo "lint: sbxclaude/spec.yaml is version $$spec_version but CHANGELOG.md's latest release is $$changelog_version" >&2; \
		exit 1; \
	fi
	@echo "All lint checks passed."

# Validate the sandbox kit spec against the current Sandbox Kit schema.
validate:
	./scripts/sbxclaude kit validate

# Run every test
test: test-unit test-toolchain

# Test the wrapper with a fake sbx CLI.
test-unit:
	$(BASH) ./tests/sbxclaude_test.sh

# Smoke-test the installed helper tools inside the live sandbox.
test-toolchain:
	./scripts/sbxclaude exec ./tests/toolchain_test.sh
