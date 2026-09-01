# makecore-actions-runner

The container image makecore runs GitHub Actions jobs in.

```
ghcr.io/upcore-app/makecore-actions-runner:latest
```

## Contents

`ghcr.io/actions/actions-runner` plus:

- `build-essential`, `python3`, `pkg-config`
- `docker-ce-cli`, `docker-buildx-plugin`, `docker-compose-plugin`
- `jq`, `zip`, `unzip`, `git`, `curl`, `ca-certificates`


## Building

Pushes to `main` publish `latest`. Published releases also get semver tags.
Both architectures ship in one manifest.

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t makecore-actions-runner .
```

Pin a different base with `--build-arg RUNNER_VERSION=`.
