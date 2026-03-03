#!/bin/bash
LOG_DIR=$1
SIF_PATH=$2
OVERLAY_PATH=$3
SSH_USER=$4
BUILD_JOB_ID=$5
MEMORY=$6
CPUS=$7
TIME=$8
IMAGE=$9
TMP_DIR=${10}
USER_BINDS=${11}
REPO=${12}
COMMIT=${13}
SCRIPT_PATH=${14}
USE_GPU=${15}
EXCLUSIVE=${16}
ACCOUNT=${17:-}
SSH_BIND=${18:-/home/${SSH_USER}/.ssh}
FAKEROOT=${19:-0}

SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/${COMMIT}/${SCRIPT_PATH}"

if [ "$USE_GPU" = "true" ]; then
    GPU_SLURM="#SBATCH --gres=gpu:1"
    GPU_SINGULARITY="--nv"
else
    GPU_SLURM=""
    GPU_SINGULARITY=""
fi

if [ -n "$BUILD_JOB_ID" ]; then
    SLURM_DEPENDENCY="#SBATCH --dependency=afterok:$BUILD_JOB_ID"
else
    SLURM_DEPENDENCY=""
fi

if [ "$EXCLUSIVE" = "true" ]; then
    SBATCH_EXCLUSIVE="#SBATCH --exclusive"
else
    SBATCH_EXCLUSIVE=""
fi

ACCOUNT_DIRECTIVE=""
if [[ -n "$ACCOUNT" ]]; then
    ACCOUNT_DIRECTIVE="#SBATCH --account=${ACCOUNT}"
fi

if [ "$FAKEROOT" -eq 1 ]; then
    FAKEROOT_FLAG="--fakeroot"
else
    FAKEROOT_FLAG=""
fi

MANDATORY_BINDS="${SSH_BIND},${TMP_DIR}:/tmp"
if [ -n "$USER_BINDS" ]; then
    FULL_BINDS="${MANDATORY_BINDS},${USER_BINDS}"
else
    FULL_BINDS="${MANDATORY_BINDS}"
fi

sbatch <<EOF
#!/bin/bash
${SBATCH_EXCLUSIVE}
#SBATCH --job-name=run_${IMAGE}
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mem=${MEMORY}
#SBATCH --time=${TIME}
#SBATCH --cpus-per-task=${CPUS}
#SBATCH --output=${LOG_DIR}/run-${IMAGE}-%j.log
#SBATCH --error=${LOG_DIR}/run-${IMAGE}-%j.err
${GPU_SLURM}
${SLURM_DEPENDENCY}
${ACCOUNT_DIRECTIVE}

set -euo pipefail

curl -fsSL ${SCRIPT_URL} -o \${SLURM_TMPDIR}/entrypoint.sh
chmod +x \${SLURM_TMPDIR}/entrypoint.sh

singularity exec ${GPU_SINGULARITY} ${FAKEROOT_FLAG} \\
  --containall --no-home --cleanenv \\
  --env AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID},AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY},AWS_DEFAULT_REGION=us-east-1 \\
  --overlay ${OVERLAY_PATH}:rw \\
  --bind ${FULL_BINDS},\${SLURM_TMPDIR}:/slurm_tmp \\
  ${SIF_PATH} \\
  bash /slurm_tmp/entrypoint.sh
EOF