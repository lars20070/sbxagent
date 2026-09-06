# Host setup

Credentials and model providers, all configured on the host so the sandbox
never holds a real secret. Only Git over HTTPS applies to every agent; the
rest is `sbxpi`.

## Git over HTTPS

Sandbox network policy allows `github.com:443` but not SSH port 22. Every kit
rewrites `git@github.com:` and `ssh://git@github.com/` remotes to
`https://github.com/` for the sandbox user only, so `git fetch` works without
changing the host checkout's remote URL.

Public repositories need no extra setup. For private repositories, store a
GitHub token on the host so the credential proxy can inject it:

```bash
echo "$(gh auth token)" | sbx secret set github
```

## OpenRouter (`sbxpi`, cloud models)

`sbxpi` is the one kit that needs a model credential of its own: it talks to
OpenRouter rather than to an agent vendor's API. Store the key on the host
twice — once as a plain secret the credential proxy can inject, and again as a
sandbox-scoped custom secret, which works around
[docker/sbx-releases#25](https://github.com/docker/sbx-releases/issues/25):

```bash
echo "$OPENROUTER_API_KEY" | sbx secret set openrouter
sbx secret set-custom --sandbox "$(sbxpi name)" \
  --host openrouter.ai --env OPENROUTER_API_KEY \
  --value "$OPENROUTER_API_KEY"
```

`--sandbox` wants that project's real sandbox name, which is why it is read
from `sbxpi name` rather than written out.

The default model is `qwen/qwen3-coder-next`. It is not available on DeepInfra,
so its `openRouterRouting.ignore` in
[`kits/sbxpi/files/home/.pi/agent/models.json`](../kits/sbxpi/files/home/.pi/agent/models.json)
excludes DeepInfra from routing — OpenRouter picks another backend instead of
forwarding a bring-your-own-key request DeepInfra cannot serve.

`qwen/qwen3-coder`, `moonshotai/kimi-k2.6`, `z-ai/glm-5.2`, and
`deepseek/deepseek-v4-pro` are also defined there, all pinned to the DeepInfra
backend with `allow_fallbacks: false`: an unavailable DeepInfra returns a hard
404 instead of silently rerouting to another provider at another price.

Every upstream provider is reached through OpenRouter and never contacted
directly, so `openrouter.ai` is the only provider host on the allowlist. Change
the default model or any model's routing in `models.json`, not on the command
line — the kit passes no `--provider`/`--model` flags, so `settings.json` is
what decides.

Worth knowing, though it needs no action: if a bring-your-own-key request
fails, OpenRouter may complete it through its own shared capacity and bill
OpenRouter credits. A workspace setting to never use shared capacity closes
that path.

## Ollama (`sbxpi`, local models)

`sbxpi` can also talk to [Ollama](https://ollama.com) running **on your host**,
for work that should not leave the machine or does not warrant a cloud call.
OpenRouter stays the default, so this is opt-in per run and a stopped Ollama
never breaks a session.

Ollama runs on the host, not inside the sandbox, and that is deliberate: the
microVM has no GPU, and models are gigabytes that would be re-pulled on every
rebuild.

Set it up once on the host. Ollama listens on `127.0.0.1` by default, which the
sandbox cannot reach, so it has to be told to listen more widely:

```bash
launchctl setenv OLLAMA_HOST 0.0.0.0   # then restart Ollama; Linux: systemd override
ollama pull qwen2.5-coder:7b
ollama pull qwen3-coder:30b
ollama pull gpt-oss:20b
sbx policy allow network --sandbox "$(sbxpi name)" localhost:11434
```

**`OLLAMA_HOST=0.0.0.0` exposes Ollama to your whole local network, not only to
the sandbox.** Ollama has no authentication, so on an untrusted network bind it
to a specific interface instead, or leave this feature unused.

The `sbx policy allow` line is a host-side step, not something the kit bakes
in, and it cannot be otherwise: the proxy resolves the sandbox's
`host.docker.internal` back to the host's own loopback and checks the rule as
`localhost:11434`, which a kit's allowlist will not accept. Keeping it
`--sandbox`-scoped means only this sandbox gains the path. Undo it with
`sbx policy rm network --sandbox "$(sbxpi name)" --resource localhost:11434`.

Then select it per run, from inside the sandbox:

```bash
pi --provider ollama --model qwen3-coder:30b
```

`qwen3-coder:30b` is the local counterpart of the cloud default: same family as
OpenRouter's `qwen/qwen3-coder`, at a size a laptop can hold. `qwen2.5-coder:7b`
is the fast, small option, and `gpt-oss:20b` the reasoning one.

Two things are non-obvious, and both are already handled in
[`kits/sbxpi/files/home/.pi/agent/models.json`](../kits/sbxpi/files/home/.pi/agent/models.json).
The sandbox has its own `localhost`, so the provider's `baseUrl` points at
`host.docker.internal`, even though the policy rule above names
`localhost:11434` — those are the same connection seen from the two ends.

Adding a model means adding its id to that file and rebuilding: unlike
OpenRouter, a custom provider has no catalogue for Pi to read, so every id must
be listed.
