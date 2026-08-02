#!/bin/bash
# Concatenated into every job script by bin/deploy, ahead of the project's
# deploy.conf. The hard parts live here once; projects compose them.

TS_IMG="${TS_IMG:-docker://tailscale/tailscale}"
AWSCLI_IMG="${AWSCLI_IMG:-docker://amazon/aws-cli}"

# ts_up <hostname> <tag>
# Brings up userspace-mode tailscaled and registers this node.
# Requires TS_AUTHKEY in the environment.
ts_up() {
    local hostname="$1" tag="$2"
    : "${TS_AUTHKEY:?ts_up: TS_AUTHKEY not set}"

    export TS_SOCK="${SLURM_TMPDIR}/ts.sock"
    local statedir="${SLURM_TMPDIR}/tsstate"

    singularity exec "$TS_IMG" tailscaled \
        --tun=userspace-networking \
        --statedir="$statedir" \
        --socket="$TS_SOCK" &

    local i
    for i in $(seq 60); do
        [ -S "$TS_SOCK" ] \
            && singularity exec "$TS_IMG" tailscale --socket="$TS_SOCK" status >/dev/null 2>&1 \
            && break
        sleep 1
    done
    [ -S "$TS_SOCK" ] || { echo "ts_up: tailscaled never came up" >&2; return 1; }

    singularity exec "$TS_IMG" tailscale --socket="$TS_SOCK" up \
        --reset \
        --authkey="$TS_AUTHKEY" \
        --hostname="$hostname" \
        --advertise-tags="$tag" \
        --accept-risk=lose-ssh
}

# ssm_env <VAR>=<param-path> ...
# Reads SSM parameters and exports them.
#
# Compute nodes have no aws CLI, so this runs one aws-cli container -- ONE,
# for all parameters, rather than one per parameter.
ssm_env() {
    local pairs=("$@") names=() vars=() pair
    for pair in "${pairs[@]}"; do
        vars+=("${pair%%=*}")
        names+=("${pair#*=}")
    done

    local json
    json="$(singularity run --cleanenv \
        --env AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
        --env AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
        --env AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" \
        "${AWSCLI_IMG}" \
        ssm get-parameters --with-decryption \
            --names "${names[@]}" \
            --query 'Parameters[].[Name,Value]' --output text)"

    local i val
    for i in "${!vars[@]}"; do
        val="$(awk -F'\t' -v n="${names[$i]}" '$1==n {print $2}' <<<"$json")"
        [ -n "$val" ] || { echo "ssm_env: ${names[$i]} not found" >&2; return 1; }
        export "${vars[$i]}=${val}"
    done
}

# sif_run <sif> <cmd...>
# The singularity incantation, once.
# Honours: USE_GPU, FAKEROOT, OVERLAY, BINDS, PASS_ENV
sif_run() {
    local sif="$1"; shift
    local args=(exec --containall --cleanenv --no-home)

    [ "${USE_GPU:-0}" = "1" ]  && args+=(--nv)
    [ "${FAKEROOT:-0}" = "1" ] && args+=(--fakeroot)
    [ -n "${OVERLAY:-}" ]      && args+=(--overlay "${OVERLAY}:rw")

    local binds="${SLURM_TMPDIR}:/tmp"
    [ -z "${OVERLAY:-}" ] && binds="${binds},${SLURM_TMPDIR}:${HOME}"
    [ -n "${BINDS:-}" ]   && binds="${binds},${BINDS}"
    args+=(--bind "$binds")

    # PASS_ENV is a space-separated list of variable NAMES to forward.
    local v
    for v in ${PASS_ENV:-}; do
        args+=(--env "${v}=${!v}")
    done

    singularity "${args[@]}" "$sif" "$@"
}

# overlay_ensure <path>
# Creates a persistent ext3 overlay from the cluster template if absent.
overlay_ensure() {
    local path="$1"
    [ -f "$path" ] && return 0
    : "${OVERLAY_SRC:?overlay_ensure: OVERLAY_SRC not set}"
    cp "$OVERLAY_SRC" "${path}.gz"
    gunzip -f "${path}.gz"
}

# ---------------------------------------------------------------------------
# Defaults. A project overrides either of these by defining a function of the
# same name in its deploy.conf.
# ---------------------------------------------------------------------------

build_job() {
    mkdir -p "$SIF_DIR"
    [ -n "${OVERLAY:-}" ] && overlay_ensure "$OVERLAY"
    singularity build --force "$SIF" "$DOCKER_URL"
}

run_job() {
    echo "run_job: project deploy.conf must define this" >&2
    return 1
}