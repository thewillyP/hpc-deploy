// The entire per-project deploy definition. A project's deploy/Jenkinsfile
// loads this library and calls hpcDeploy(...) with its config -- there is no
// second config file.
//
// This layer stays thin on purpose: it turns a map into environment
// variables and calls bin/deploy. It does not generate scripts and it does
// not interpolate secrets.
//
// Config keys:
//   image      String   required. base name for job/sif/overlay
//   variants   Map      name -> [dockerUrl: String, gpu: boolean]
//   build      Map      [time:, mem:, cpus:]
//   run        Map      [time:, mem:, cpus:]
//   fakeroot   boolean  default false
//   exclusive  boolean  default false
//   binds      String   comma-separated, passed to singularity --bind
//   tsTag      String   tailscale ACL tag, default 'tag:devenv'
//   tsHostname String   default "<image>-<variant>"
//   runJob     String   REQUIRED. bash, runs on the compute node.
//   buildJob   String   optional. overrides the default singularity build.
//
// runJob/buildJob MUST use ''' ''' (single-quoted), not """ """. Groovy does
// not interpolate single-quoted strings, so $VARS survive to the compute node.

def call(Map cfg) {

    assert cfg.image    : 'hpcDeploy: image is required'
    assert cfg.runJob   : 'hpcDeploy: runJob is required'
    assert cfg.variants : 'hpcDeploy: variants is required'

    // NOTE: parameters only materialise after a job's first build. Expect one
    // throwaway build per project after the controller is rebuilt.
    properties([
        parameters([
            choice(name: 'ACTION',  choices: ['up', 'run', 'build', 'cancel']),
            choice(name: 'CLUSTER', choices: ['torch', 'greene']),
            choice(name: 'VARIANT', choices: cfg.variants.keySet() as List),
            booleanParam(name: 'REBUILD', defaultValue: false,
                description: 'ACTION=up: rebuild the .sif first, chained with afterok'),
            string(name: 'RUN_TIME',    defaultValue: (cfg.run?.time  ?: '06:00:00')),
            string(name: 'RUN_MEM',     defaultValue: (cfg.run?.mem   ?: '16G')),
            string(name: 'RUN_CPUS',    defaultValue: (cfg.run?.cpus  ?: 4).toString()),
            string(name: 'BUILD_TIME',  defaultValue: (cfg.build?.time ?: '00:45:00')),
            string(name: 'BUILD_MEM',   defaultValue: (cfg.build?.mem  ?: '32G')),
            string(name: 'BUILD_CPUS',  defaultValue: (cfg.build?.cpus ?: 8).toString()),
            booleanParam(name: 'EXCLUSIVE', defaultValue: (cfg.exclusive ?: false)),
            booleanParam(name: 'FAKEROOT',  defaultValue: (cfg.fakeroot ?: false)),
        ])
    ])

    node {
        stage('Checkout') {
            checkout scm                                   // the project repo
            dir('.hpc') {                                  // the tool repo
                git url: 'https://github.com/thewillyP/hpc-deploy.git', branch: 'main'
            }
        }

        stage("${params.ACTION} ${params.CLUSTER}/${params.VARIANT}") {

            def v = cfg.variants[params.VARIANT]
            assert v : "unknown variant: ${params.VARIANT}"

            writeFile file: '.hpc-runjob',   text: (cfg.runJob   ?: '')
            writeFile file: '.hpc-buildjob', text: (cfg.buildJob ?: '')

            withEnv([
                "HPC_IMAGE=${cfg.image}",
                "HPC_DOCKER_URL=${v.dockerUrl}",
                "HPC_USE_GPU=${v.gpu ? 1 : 0}",
                "HPC_BUILD_TIME=${params.BUILD_TIME ?: (cfg.build?.time ?: '00:45:00')}",
                "HPC_BUILD_MEM=${params.BUILD_MEM   ?: (cfg.build?.mem  ?: '32G')}",
                "HPC_BUILD_CPUS=${params.BUILD_CPUS ?: (cfg.build?.cpus ?: 8)}",
                "HPC_RUN_TIME=${params.RUN_TIME ?: (cfg.run?.time ?: '06:00:00')}",
                "HPC_RUN_MEM=${params.RUN_MEM  ?: (cfg.run?.mem  ?: '16G')}",
                "HPC_RUN_CPUS=${params.RUN_CPUS ?: (cfg.run?.cpus ?: 4)}",
                "HPC_FAKEROOT=${(params.FAKEROOT  ?: cfg.fakeroot)  ? 1 : 0}",
                "HPC_EXCLUSIVE=${(params.EXCLUSIVE ?: cfg.exclusive) ? 1 : 0}",
                "HPC_BINDS=${cfg.binds ?: ''}",
                "HPC_TS_TAG=${cfg.tsTag ?: 'tag:devenv'}",
                "HPC_TS_HOSTNAME=${cfg.tsHostname ?: "${cfg.image}-${params.VARIANT}"}",
                "HPC_PASS_ENV=${cfg.passEnv ?: ''}",
                // params are NOT in the environment on a job's first build --
                // properties() declares them but the build itself has none.
                // Pass them explicitly so `set -u` does not kill the script.
                "ACTION=${params.ACTION}",
                "CLUSTER=${params.CLUSTER}",
                "VARIANT=${params.VARIANT}",
                "REBUILD=${params.REBUILD ? 1 : 0}",
                "HPC_SSH_TARGET=self",
                "HPC_SSH_DEBUG=0",
            ]) {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding',
                     credentialsId: 'aws-credentials',
                     accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                     secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'],
                    string(credentialsId: 'tailscale-authkey',
                     variable: 'TS_AUTHKEY'),
                ]) {
                    sh '''
                        set +x
                        set -eu
                        REBUILD_FLAG=""
                        [ "${REBUILD}" = "1" ] && REBUILD_FLAG="--rebuild"

                        ./.hpc/bin/deploy "${ACTION}" \
                            --cluster "${CLUSTER}" \
                            --variant "${VARIANT}" \
                            ${REBUILD_FLAG}
                    '''
                }
            }
        }
    }
}