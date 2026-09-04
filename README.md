# makecore-actions-runner

The image a makecore machine runs.

```
ghcr.io/upcore-app/makecore-actions-runner:latest
```

A job runs as a virtual machine of its own, so this is a whole operating system
and not a container image. `runnerd` pulls it once per node, unpacks it into a
logical volume, and every job boots a copy-on-write clone of that volume. No job
pulls or unpacks anything.

## Contents

Built on `ubuntu:26.04`:

- **systemd**, as the init of the machine
- **`linux-image-virtual`** and its initramfs — see below
- **Docker Engine**, the daemon and not only the client
- **The GitHub Actions runner**, in `/home/runner`
- **gitlab-runner**, for a machine serving a GitLab repository
- Two Node LTS in `/opt/hostedtoolcache`, Go, JDK 17 and 21, Python 3
- `git`, `git-lfs`, `build-essential`, `curl`, `jq`, `zip`, `unzip`, `rsync`

## The kernel is not optional

`runnerd` copies `/boot/vmlinuz*` and `/boot/initrd.img*` out of this image when
it builds a root disk, and Cloud Hypervisor boots those. An image with no kernel
is refused, rather than producing a disk that boots to nothing.

The initramfs matters as much. This kernel builds `virtio_blk` as a module, so a
guest without one boots and then cannot find its own root disk.

## Why not `ghcr.io/actions/actions-runner`

That image has no init and no kernel, and its entrypoint is the runner itself.
That is what a container needs. A machine has to boot, bring up its own network,
mount its cache disk and start a Docker daemon before any of a job runs, and
none of that has anywhere to happen without an init.

## Nothing starts on its own

`runnerd` writes one systemd unit into the root disk when it builds it, and that
unit runs the job. Docker is masked here on purpose: the unit starts it after
the cache disk is mounted over `/var/lib/docker`. Started at boot instead, the
daemon would make an image store on the root disk, and every job would run cold
while its cache sat unused.

That unit runs as root, and systemd only fills in `HOME` from the passwd entry
of a `User=` it does not have. This image ships a drop-in for it setting
`HOME=/home/runner`, because the runner inherits that environment and so does
every `run:` step of every job — without it a step under `set -u` dies on its
first `$HOME`, and `setup-bun`, npm and pip write their caches nowhere.

## Building

Pushes to `main` publish `latest`. Published releases also get semver tags. Both
architectures ship in one manifest.

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t makecore-actions-runner .
```

Versions are build arguments: `RUNNER_VERSION`, `GITLAB_RUNNER_VERSION`,
`NODE_LTS_A`, `NODE_LTS_B`, `GO_VERSION`.

## Adding a toolchain

Put it in `/opt/hostedtoolcache/<tool>/<version>/<arch>` and touch
`/opt/hostedtoolcache/<tool>/<version>/<arch>.complete`. A `setup-` action finds
it there and downloads nothing. Node is done that way already, and is the
pattern to copy.
