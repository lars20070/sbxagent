AGENT ?= claude
BASH ?= bash
MARKDOWNLINT ?= markdownlint-cli2
YAMLLINT ?= yamllint
CSPELL ?= cspell

.PHONY: lint validate test test-unit test-toolchain

# Lint tracked files: Markdown (skip plan drafts), JSON, jq filters (parsed
# against null input, so a syntax error fails the build), YAML, shell scripts
# (shellcheck + bash -n, one file per xargs call), and spell-check (skip plan
# drafts). Assert each kits/<name>/ declares name: <name>, that the files every
# kit duplicates stay byte-identical across kits, that the Cursor kit's
# user-scope MCP config matches the repo's project-scope one (the sandbox mounts
# the project, so the two sit side by side), that the dev-only copy of the
# network-block jq filter stays in sync with the heredoc that actually ships
# it, and that VERSION, every kits/*/spec.yaml version, and CHANGELOG's latest
# release all agree.
lint:
	git ls-files -z -- '*.md' ':!.claude/plans/*' ':!.cursor/plans/*' | xargs -0 $(MARKDOWNLINT)
	git ls-files -z -- '*.json' | xargs -0 -n1 jq empty
	git ls-files -z -- '*.jq' | xargs -0 -n1 sh -c 'jq -n -f "$$1" >/dev/null' --
	git ls-files -z -- '*.yaml' '*.yml' | xargs -0 $(YAMLLINT)
	git ls-files -z -- '*.sh' 'scripts/sbxagent' | xargs -0 shellcheck --enable=all
	git ls-files -z -- '*.sh' 'scripts/sbxagent' | xargs -0 -n1 bash -n
	git ls-files -z -- ':!.claude/plans/*' ':!.cursor/plans/*' | xargs -0 $(CSPELL) --no-progress
	for kit in kits/*/; do \
		dir="$${kit%/}"; name="$$(basename "$$dir")"; \
		grep -qx "name: $$name" "$$dir/spec.yaml" || { \
			echo "lint: $$dir/spec.yaml does not declare 'name: $$name'" >&2; exit 1; \
		}; \
	done
	for shared in home/.gitconfig workspace/.editorconfig; do \
		ref="kits/sbxclaude/files/$$shared"; \
		for kit in kits/*/; do \
			copy="$${kit}files/$$shared"; \
			[ -e "$$copy" ] || { \
				echo "lint: $$copy is missing" >&2; exit 1; \
			}; \
			cmp -s "$$ref" "$$copy" || { \
				echo "lint: $$copy differs from $$ref" >&2; exit 1; \
			}; \
		done; \
	done
	cmp -s .cursor/mcp.json kits/sbxcursor/files/home/.cursor/mcp.json || { \
		echo "lint: kits/sbxcursor/files/home/.cursor/mcp.json differs from .cursor/mcp.json" >&2; \
		exit 1; \
	}
	jq_heredoc="$$(mktemp)"; jq_dev="$$(mktemp)"; \
	trap 'rm -f "$$jq_heredoc" "$$jq_dev"' EXIT; \
	awk '/<<.JQFILTER./{f=1; next} /^        JQFILTER$$/{f=0} f' \
		kits/sbxclaude/spec.yaml | sed 's/^        //' > "$$jq_heredoc"; \
	sed -n '/^# BEGIN-SYNCED/,/^# END-SYNCED/p' \
		kits/sbxclaude/files/network-block.jq | sed '1d;$$d' > "$$jq_dev"; \
	cmp -s "$$jq_heredoc" "$$jq_dev" || { \
		echo "lint: kits/sbxclaude/files/network-block.jq is out of sync with the heredoc in kits/sbxclaude/spec.yaml" >&2; \
		exit 1; \
	}
	if [ ! -f VERSION ]; then \
		echo "lint: VERSION is missing" >&2; exit 1; \
	fi; \
	repo_version="$$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' VERSION)"; \
	if [ -z "$$repo_version" ]; then \
		echo "lint: could not find X.Y.Z in VERSION" >&2; exit 1; \
	fi; \
	changelog_version="$$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
	if [ -z "$$changelog_version" ]; then \
		echo "lint: could not find a ## [X.Y.Z] release heading in CHANGELOG.md" >&2; exit 1; \
	elif [ "$$repo_version" != "$$changelog_version" ]; then \
		echo "lint: VERSION is $$repo_version but CHANGELOG.md's latest release is $$changelog_version" >&2; \
		exit 1; \
	fi; \
	for spec in kits/*/spec.yaml; do \
		spec_version="$$(grep -m1 '^version:' "$$spec" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
		if [ -z "$$spec_version" ]; then \
			echo "lint: could not find version: in $$spec" >&2; exit 1; \
		elif [ "$$spec_version" != "$$repo_version" ]; then \
			echo "lint: $$spec is version $$spec_version but VERSION is $$repo_version" >&2; \
			exit 1; \
		fi; \
	done
	@echo "All lint checks passed."

# Validate every sandbox kit spec against the current Sandbox Kit schema.
validate:
	./scripts/sbxclaude kit validate
	./scripts/sbxcodex kit validate
	./scripts/sbxcursor kit validate

# Run every test
test: test-unit test-toolchain

# Test the wrapper with a fake sbx CLI.
test-unit:
	$(BASH) ./tests/sbxagent_test.sh

# Smoke-test the installed helper tools inside the live sandbox.
# AGENT selects which wrapper (and therefore which sandbox) to run in.
test-toolchain:
	./scripts/sbx$(AGENT) exec ./tests/toolchain_test.sh
