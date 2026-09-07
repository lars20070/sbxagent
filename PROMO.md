# Promo copy

Two versions of the same pitch, answering the question a reader asks first:
if `sbx` already runs Claude Code in a sandbox, why does this exist?

## LinkedIn

`sbx run claude` drops Claude Code into a microVM and stops there. The agent is sandboxed, but it cannot lint the Python it just wrote, screenshot the page it just changed, or render the diagram it just drew — not until someone installs the tools, again, in every new sandbox.

[`sbxagent`](https://github.com/lars20070/sbxagent) ships them pinned: ruff, yamllint, markdownlint-cli2, cspell, Playwright with headless Chromium, mermaid-cli. The same set goes into four kits — Claude Code, Codex, Cursor and Pi — so swapping agents changes the agent, not what it can do.

If you have only run agents from the frontier labs, `sbxpi` is worth an hour. Pi is open source, and it reaches Qwen, DeepSeek, GLM and Kimi through OpenRouter, or Ollama on your own machine.

Would rather bring your own wrapper? Every kit is published to GHCR, so you can run one without cloning anything.

<https://github.com/lars20070/sbxagent>

## Discord

`sbx run claude` sandboxes the agent and stops there. `sbxagent` adds a pinned
toolchain — ruff, cspell, Playwright, mermaid-cli — identical across Claude
Code, Codex, Cursor and Pi, so swapping agents changes the agent, not what it
can do. `sbxpi` runs Pi against Qwen, DeepSeek or a local Ollama.

<https://github.com/lars20070/sbxagent>

## Before posting

Every claim above traces to a file in this repository, with one exception:
**"Pi is open source"**. Nothing in `kits/sbxpi/spec.yaml` or the docs states
Pi's licence — the repo records only the npm package
`@earendil-works/pi-coding-agent`. Check it against pi.dev before the post goes
out.

The copy names tools and models rather than versions, so it does not go stale
on the next release. If the toolchain changes, re-check the names against
`docs/toolchain.md`, and the models against
`kits/sbxpi/files/home/.pi/agent/models.json`.
