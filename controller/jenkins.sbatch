#!/bin/bash
#SBATCH --job-name=jenkins
#SBATCH --nodes=1
#SBATCH --ntasks=1
# --account --time --mem --cpus-per-task --output come from the sbatch command
# line, which overrides in-script directives.

set -euo pipefail

: "${TS_AUTHKEY:?missing}"
: "${JENKINS_IMAGE:?missing}"
: "${JENKINS_DATA_DIR:?missing}"
: "${AWS_ACCESS_KEY_ID:?missing}"
: "${AWS_SECRET_ACCESS_KEY:?missing}"
: "${TS_API_CLIENT_ID:?missing}"
: "${TS_API_CLIENT_SECRET:?missing}"
: "${JENKINS_ADMIN_USER:?missing}"
: "${JENKINS_ADMIN_PASS:?missing}"
: "${GITHUB_USER:?missing}"
: "${GITHUB_TOKEN:?missing}"

TS_IMG=docker://tailscale/tailscale
TS_SOCK="${SLURM_TMPDIR}/ts.sock"

mkdir -p "$JENKINS_DATA_DIR"

# ---- tailnet ---------------------------------------------------------------
singularity exec "$TS_IMG" tailscaled \
    --tun=userspace-networking \
    --statedir="${SLURM_TMPDIR}/tsstate" \
    --socket="$TS_SOCK" &

for _ in $(seq 60); do
    [ -S "$TS_SOCK" ] \
        && singularity exec "$TS_IMG" tailscale --socket="$TS_SOCK" status >/dev/null 2>&1 \
        && break
    sleep 1
done
[ -S "$TS_SOCK" ] || { echo "tailscaled never came up" >&2; exit 1; }

singularity exec "$TS_IMG" tailscale --socket="$TS_SOCK" up \
    --reset \
    --authkey="$TS_AUTHKEY" \
    --hostname=jenkins \
    --advertise-tags=tag:devenv \
    --accept-risk=lose-ssh

# ---- controller ------------------------------------------------------------
# httpListenAddress=127.0.0.1 is load-bearing: a compute node sits on NYU
# internal network, so an 0.0.0.0 bind would expose Jenkins to it. Bound to
# loopback, tailscaled's inbound forwarding is the only way in.
singularity run --containall --cleanenv --no-home \
    --env JENKINS_OPTS="--httpPort=8080 --httpListenAddress=127.0.0.1" \
    --env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --env AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --env AWS_DEFAULT_REGION=us-east-1 \
    --env TS_API_CLIENT_ID="$TS_API_CLIENT_ID" \
    --env TS_API_CLIENT_SECRET="$TS_API_CLIENT_SECRET" \
    --env JENKINS_ADMIN_USER="$JENKINS_ADMIN_USER" \
    --env JENKINS_ADMIN_PASS="$JENKINS_ADMIN_PASS" \
    --env GITHUB_USER="$GITHUB_USER" \
    --env GITHUB_TOKEN="$GITHUB_TOKEN" \
    --bind "$JENKINS_DATA_DIR":/var/jenkins_home \
    --bind "${SLURM_TMPDIR}":/tmp \
    --bind "/home/${USER}/.ssh" \
    "$JENKINS_IMAGE"
