AGENT ?= claude
BASH ?= bash
MARKDOWNLINT ?= markdownlint-cli2
YAMLLINT ?= yamllint
CSPELL ?= cspell
RUFF ?= ruff
# Syntax-checks TypeScript by type-stripping it. Pinned and fetched through
# npx by default because no kit installs esbuild, so unlike markdownlint and
# cspell there is no local binary to fall back on. The first fetch on a cold
# npm cache is slow — a minute or more — and every run after it is instant;
# CI sidesteps that by installing esbuild itself and overriding this. Syntax
# only — it neither resolves imports nor checks types.
ESBUILD ?= npx --yes esbuild@0.28.2

# Skill definitions are prose authored to each agent tool's own conventions,
# not this repo's, so the two prose checks below — markdownlint and cspell —
# skip them. Every other check still covers them, so a skill that ships a
# script or a config is still syntax-checked. `**/skills/**` needs `glob`
# magic to match a `skills/` component at any depth — the plain `:!a/b/*` form
# used for plan drafts cannot express "at any depth" without also matching a
# directory that merely ends in "skills".
NO_SKILLS := ':(exclude,glob)**/skills/**'

.PHONY: lint validate test test-unit test-toolchain test-lifecycle publish-dry-run

# Lint tracked files: Markdown (skip plan drafts), JSON, jq filters (parsed
# against null input, so a syntax error fails the build), TypeScript
# (type-stripped by esbuild, so a syntax error fails the build too), YAML,
# shell scripts (shellcheck + bash -n, one file per xargs call), Python (Ruff
# lint and format check, targeting 3.9, the oldest python3 a macOS host has),
# and spell-check (skip plan drafts). Markdown and spell-check also skip skill
# definitions. Assert each kits/<name>/ and mixins/<name>/ holds a <name>.yaml
# descriptor and no v2 spec.yaml, that no two kits share a descriptor stem
# (composed kits stage theirs at /usr/share/sandbox/kit/<stem>/, so a shared
# stem collides), that the files every kit duplicates — the recipe included —
# stay byte-identical across kits, that the Cursor kit's user-scope MCP config
# matches the repo's project-scope one (the sandbox mounts the project, so the
# two sit side by side), that each kit ships its network-block guard files and
# every kit's copy of the jq filter matches kits/sbxclaude's, and that VERSION,
# every kit descriptor's version,
# and CHANGELOG's latest release all agree.
lint:
	git ls-files -z -- '*.md' ':!.claude/plans/*' ':!.cursor/plans/*' ':!tmp/*' $(NO_SKILLS) | xargs -0 $(MARKDOWNLINT)
	git ls-files -z -- '*.json' | xargs -0 -n1 jq empty
	git ls-files -z -- '*.jq' | xargs -0 -n1 sh -c 'jq -n -f "$$1" >/dev/null' --
	git ls-files -z -- '*.ts' | xargs -0 -n1 sh -c '$(ESBUILD) --loader=ts --log-level=warning <"$$1" >/dev/null' --
	git ls-files -z -- '*.yaml' '*.yml' | xargs -0 $(YAMLLINT)
	git ls-files -z -- '*.sh' 'scripts/sbxagent' 'kits/*/files/system/usr/local/bin/gh' | xargs -0 shellcheck --enable=all
	git ls-files -z -- '*.sh' 'scripts/sbxagent' 'kits/*/files/system/usr/local/bin/gh' | xargs -0 -n1 bash -n
	find .claude/skills/read-pi-session-traces -name '*.py' -print0 | xargs -0 $(RUFF) check --target-version py39
	find .claude/skills/read-pi-session-traces -name '*.py' -print0 | xargs -0 $(RUFF) format --check --target-version py39
	git ls-files -z -- ':!.claude/plans/*' ':!.cursor/plans/*' ':!tmp/*' $(NO_SKILLS) | xargs -0 $(CSPELL) --no-progress
	for dir in kits/*/ mixins/*/; do \
		dir="$${dir%/}"; name="$$(basename "$$dir")"; \
		[ -f "$$dir/$$name.yaml" ] || { \
			echo "lint: $$dir has no $$name.yaml descriptor" >&2; exit 1; \
		}; \
		[ ! -e "$$dir/spec.yaml" ] || { \
			echo "lint: $$dir/spec.yaml is a v2 leftover; the descriptor is $$name.yaml" >&2; exit 1; \
		}; \
		cmp -s kits/sbxclaude/.dockerignore "$$dir/.dockerignore" || { \
			echo "lint: $$dir/.dockerignore differs from kits/sbxclaude/.dockerignore" >&2; exit 1; \
		}; \
	done
	dup="$$(for dir in kits/*/ mixins/*/; do basename "$${dir%/}"; done | sort | uniq -d)"; \
	[ -z "$$dup" ] || { \
		echo "lint: descriptor stem(s) used twice: $$dup" >&2; exit 1; \
	}
	for kit in kits/*/; do \
		dir="$${kit%/}"; name="$$(basename "$$dir")"; \
		cmp -s kits/sbxclaude/sbxclaude.dockerfile "$$dir/$$name.dockerfile" || { \
			echo "lint: $$dir/$$name.dockerfile differs from kits/sbxclaude/sbxclaude.dockerfile" >&2; exit 1; \
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
	for guard in \
		sbxclaude:usr/local/lib/sbxagent/network-block.jq \
		sbxclaude:etc/claude-code/managed-settings.json \
		sbxcodex:usr/local/lib/sbxagent/network-block.jq \
		sbxcodex:etc/codex/requirements.toml \
		sbxpi:usr/local/lib/sbxagent/network-block.jq \
		sbxpi:usr/local/lib/sbxagent/network-block.ts; do \
		file="kits/$${guard%%:*}/files/system/$${guard#*:}"; \
		[ -s "$$file" ] || { \
			echo "lint: $$file is missing, so that kit ships without its network-block guard" >&2; exit 1; \
		}; \
	done
	ref=kits/sbxclaude/files/system/usr/local/lib/sbxagent/network-block.jq; \
	for copy in kits/*/files/system/usr/local/lib/sbxagent/network-block.jq; do \
		cmp -s "$$ref" "$$copy" || { \
			echo "lint: $$copy differs from $$ref" >&2; exit 1; \
		}; \
	done
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
	for kit in kits/*/; do \
		spec="$${kit}$$(basename "$${kit%/}").yaml"; \
		spec_version="$$(grep -m1 '^version:' "$$spec" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"; \
		if [ -z "$$spec_version" ]; then \
			echo "lint: could not find version: in $$spec" >&2; exit 1; \
		elif [ "$$spec_version" != "$$repo_version" ]; then \
			echo "lint: $$spec is version $$spec_version but VERSION is $$repo_version" >&2; \
			exit 1; \
		fi; \
	done
	@echo "All lint checks passed."

# Build every kit, and the open-network mixin the wrapper stacks with a second
# --kit, and check each result with kit-tck. Needs Docker with Buildx, network
# access, and kit-tck on PATH. PLATFORMS (e.g. linux/amd64,linux/arm64) builds
# for more than the builder's own platform.
PLATFORMS ?=
validate:
	for dir in kits/*/ mixins/*/; do \
		./scripts/validate-kit.sh "$${dir%/}" $(PLATFORMS) || exit 1; \
	done

# Rehearse the release publish path for every kit: stage a tracked-files-only
# copy, validate and inspect it, and print what would be pushed. No network, no
# registry, no credentials. There is deliberately no target that publishes for
# real — that is the release workflow's job, and a foot-gun next to `make lint`
# is how accidental releases happen.
publish-dry-run:
	for kit in kits/*/; do \
		DRY_RUN=1 ./scripts/publish-kit.sh "$$(basename "$${kit%/}")" \
			"$$(cat VERSION)"; \
	done

# Run every test
test: test-unit test-toolchain

# Test the wrapper with a fake sbx CLI.
test-unit:
	$(BASH) ./tests/sbxagent_test.sh

# Smoke-test the installed helper tools inside the live sandbox.
# AGENT selects which wrapper (and therefore which sandbox) to run in. The
# SBXAGENT_LITE and NETWORK_ALLOWLIST this was run with are what the sandbox
# must report, so set them to the values the sandbox was created with;
# EXPECTED_GITHUB=unbound checks a sandbox created with no GitHub secret.
test-toolchain:
	./scripts/sbx$(AGENT) exec env \
		EXPECTED_SBXAGENT_LITE="$${SBXAGENT_LITE:-}" \
		EXPECTED_NETWORK_ALLOWLIST="$${NETWORK_ALLOWLIST:-}" \
		EXPECTED_GITHUB="$${EXPECTED_GITHUB:-bound}" \
		./tests/toolchain_test.sh

# Prove the trace mount survives the sandbox lifecycle, checked from the host:
# create, write, stop, reattach, and cross-sandbox visibility. Needs a live sbx daemon and
# creates disposable sandboxes of its own, so it is deliberately outside
# `make test` alongside test-toolchain. AGENT selects the kit under test.
test-lifecycle:
	$(BASH) ./tests/lifecycle_test.sh $(AGENT)
