# panoramax-configs

NixOS flake that deploys the **Panoramax** open-source street-level imagery platform for [OpenStreetMap Belgium](https://openstreetmap.be), running at **<https://panoramax.osm.be>**.

The flake configures a single Infomaniak VPS to host the Panoramax API, workers, database, website, and image-serving stack via Docker Compose, fronted by Caddy for TLS. Image storage lives on a remote TrueNAS over a NetBird WireGuard mesh. Authentication is OSM OAuth2 only.

## Documentation

- [`SPEC.md`](./SPEC.md) — architecture and the *why* behind each design decision.
- [`DEPLOY.md`](./DEPLOY.md) — step-by-step initial install with runnable commands.
- [`OPERATIONS.md`](./OPERATIONS.md) — making changes after deploy: config, secret rotation, admin onboarding, recovery.
- [`todo.md`](./todo.md) — deferred items.

## Upstream

- [Panoramax API source](https://gitlab.com/panoramax/server/api) — the backend we deploy.
- [Panoramax docs](https://docs.panoramax.fr) — authoritative reference for env vars, settings, and the `panoramax_backend` CLI.

## Invariant

`nix flake check` must pass on a fresh clone of this repo, with **no secrets initialised**. A plaintext `secrets-dummy.yaml` handles fallback; real secrets live in a separate private repository (`panoramax-secrets`) attached to `./secrets/` as a git submodule. See [`SPEC.md` § Secrets](./SPEC.md#secrets).

```bash
# Fresh clone WITHOUT the secrets submodule — verifies the dummy fallback path:
git clone https://github.com/osm-be/panoramax-configs.git
cd panoramax-configs
nix flake check          # passes — the submodule is registered but not initialised
```

For real deploys, the submodule is initialised and the flake URL gets `?submodules=1` so Nix sees the encrypted secrets — see [`DEPLOY.md`](./DEPLOY.md).

## License

MIT (see `LICENSE`).
