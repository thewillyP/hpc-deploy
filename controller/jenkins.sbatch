#!/bin/bash
#SBATCH --job-name=jenkins
#SBATCH --nodes=1
#SBATCH --ntasks=1
# --account --time --mem --cpus-per-task --output come from the sbatch command
# line, which overrides in-script directives.

set -euo pipefail

: "${TS_AUTHKEY:?missing}"
: "${TS_AUTHKEY_JOBS:?missing}"
: "${JENKINS_IMAGE:?missing}"
: "${JENKINS_DATA_DIR:?missing}"
: "${JENKINS_PORT:?missing}"
: "${JENKINS_SSH_PORT:?missing}"
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
# httpListenAddress=127.0.0.1 keeps Jenkins off the NYU internal network that
# the compute node sits on. It does NOT isolate you from other users on the
# same node: Singularity shares the host network namespace, so their loopback
# is your loopback. Jenkins' own auth (casc.yaml) is what protects it there.
#
# JENKINS_PORT is deliberately not 8080 -- that is the most contended port on
# a shared node, and a collision means Jenkins fails to bind. tailscaled's
# userspace forwarding is same-port, so this is also the tailnet-facing port.
SSHD_KEY="${JENKINS_DATA_DIR}/hostkeys/ssh_host_rsa_key"
mkdir -p "${JENKINS_DATA_DIR}/hostkeys"
[ -f "$SSHD_KEY" ] || ssh-keygen -q -N "" -t rsa -b 4096 -f "$SSHD_KEY"

singularity exec --fakeroot --writable-tmpfs --containall --cleanenv --no-home \
    --bind "$JENKINS_DATA_DIR":/var/jenkins_home \
    --bind "/home/${USER}/.ssh":/root/.ssh \
    "$JENKINS_IMAGE" \
    bash -c 'sed -i "s/^sshd:x:[0-9]*:[0-9]*:/sshd:x:0:0:/" /etc/passwd 2>/dev/null || true
             exec /usr/sbin/sshd -D -e -p '"${JENKINS_SSH_PORT}"' \
               -o PermitUserEnvironment=yes \
               -o PermitTTY=yes \
               -o X11Forwarding=yes \
               -o AllowTcpForwarding=yes \
               -o GatewayPorts=yes \
               -o UsePAM=no \
               -h '"$SSHD_KEY" &

singularity run --containall --cleanenv --no-home \
    --env JENKINS_OPTS="--httpPort=${JENKINS_PORT} --httpListenAddress=127.0.0.1" \
    --env JENKINS_URL="http://jenkins:${JENKINS_PORT}/" \
    --env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    --env AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    --env AWS_DEFAULT_REGION=us-east-1 \
    --env TS_API_CLIENT_ID="$TS_API_CLIENT_ID" \
    --env TS_API_CLIENT_SECRET="$TS_API_CLIENT_SECRET" \
    --env JENKINS_ADMIN_USER="$JENKINS_ADMIN_USER" \
    --env JENKINS_ADMIN_PASS="$JENKINS_ADMIN_PASS" \
    --env GITHUB_USER="$GITHUB_USER" \
    --env GITHUB_TOKEN="$GITHUB_TOKEN" \
    --env TS_AUTHKEY_JOBS="$TS_AUTHKEY_JOBS" \
    --bind "$JENKINS_DATA_DIR":/var/jenkins_home \
    --bind "${SLURM_TMPDIR}":/tmp \
    --bind "/home/${USER}/.ssh" \
    "$JENKINS_IMAGE"
