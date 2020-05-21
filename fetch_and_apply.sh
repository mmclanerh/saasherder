#!/bin/bash

TSTAMP=$(date +%Y%m%d_%H%M%S)
TPLDIR="dsaas-templates"
CONF="/home/`whoami`/.kube/config"

if [[ -n "$1" && -n "$2" ]]; then
    KUBE_SERVER="$1"
    KUBE_TOKEN="$2"
fi

SCRIPT_PATH="python ."
if echo ${0} | grep -q "/"; then
    SCRIPT_PATH="python ${0%/*}"
fi

#Figure out if the tool is installed and set CMD accordingly
if which saasherder &> /dev/null; then
    CMD="saasherder"
else
    CMD=${SCRIPT_PATH}/saasherder/cli.py
fi

if [ -z "${DRY_RUN}" ]; then
    DRY_RUN=false
fi

if [ -n "${APPSEC}" ]; then
    echo "=> Deploying to PROD and APPSEC environments"
fi

if [ -z "${ENVIRONMENT}" ]; then
    ENVIRONMENT="None"
fi

# if KUBECONFVER is none, remove this var from the env
if [ "${KUBECONFVER}" == "none" ]; then
  unset KUBECONFVER
fi

# if KUBECONFVER is set, append to the kube conf path (ex: .kube/config-v4)
if [ ! -z "${KUBECONFVER}" ]; then
  CONF="/home/`whoami`/.kube/config-${KUBECONFVER}"
fi

SAAS_CONTEXTS=$(${CMD} config get-contexts)
echo -e "Found contexts:\n${SAAS_CONTEXTS}"

function git_prep {
    # should also check that the git master co is clean
    git checkout master
    git pull --rebase upstream master
}

function oc_apply {
    config=""
    local dryrun_arg=""

    if [[ -n "$KUBE_SERVER" && -n "$KUBE_TOKEN" ]]; then
        config="--server=${KUBE_SERVER} --token=${KUBE_TOKEN}"
    else
        [ -n "${2}" ] && config="--config=${2}"
    fi

    if ${DRY_RUN}; then
        echo "oc $config apply -f $1"
        dryrun_arg="--dry-run"
    fi

    oc $config apply ${dryrun_arg} -f $1
}

function pull_tag {
    local CONTEXT=$1
    local PROCESSED_DIR=$2
    local SAAS_ENV=$3

    local TEMPLATE_DIR=${CONTEXT}-templates

    if ${DRY_RUN}; then
        LOCAL="--local"
    fi

    # lets clear this out to make sure we always have a
    # fresh set of templates, and nothing else left behind
    rm -rf ${TEMPLATE_DIR}; mkdir -p ${TEMPLATE_DIR}

    if [ -e /home/`whoami`/${CONTEXT}-gh-token-`whoami` ]; then GH_TOKEN=" --token "$(cat /home/`whoami`/${CONTEXT}-gh-token-`whoami`); fi

    ${CMD} --context ${CONTEXT} --environment ${SAAS_ENV} pull $GH_TOKEN
    PULL_RTN=$?

    ${CMD} --context ${CONTEXT} --environment ${SAAS_ENV} template --filter Route --output-dir ${PROCESSED_DIR} ${LOCAL} tag
    PROCESS_RTN=$?

    if [ ${PULL_RTN} -ne 0 -o ${PROCESS_RTN} -ne 0 ]; then
        echo "Templates gathering and processing failed, failing job"
        exit 1
    fi
}

for g in `echo ${SAAS_CONTEXTS}`; do
    # get some basics in place, no prep in prod deploy
    CONTEXT=${g}

    if ! ${DRY_RUN}; then
        if [ -z "${KUBECONFVER}" ]; then
          CONF="/home/`whoami`/.kube/cfg-${CONTEXT}"
        else
          CONF="/home/`whoami`/.kube/cfg-${CONTEXT}-${KUBECONFVER}"
        fi
        if [ ! -e ${CONF} ] ; then
            echo "Could not find OpenShift configuration for ${CONTEXT}"; exit 1;
        fi
    fi

    TSTAMPDIR=${CONTEXT}-${TSTAMP}
    mkdir -p ${TSTAMPDIR}

    pull_tag ${CONTEXT} ${TSTAMPDIR} ${ENVIRONMENT}

    FAILED=false
    for f in `ls ${TSTAMPDIR}/*`; do
        oc_apply $f ${CONF}
        if [ $? -ne 0 ]; then
            echo "Failed applying ${f}, failing job"
            exit 1
        fi
    done

    if [ -n "${APPSEC}" ]; then
        TSTAMPDIR_APPSEC="${CONTEXT}-${TSTAMP}-appsec"
        mkdir -p ${TSTAMPDIR_APPSEC}

        pull_tag ${CONTEXT} ${TSTAMPDIR_APPSEC} "appsec"

        for f in `ls ${TSTAMPDIR_APPSEC}/*`; do
            oc_apply $f "${CONF}-appsec"
        done
    fi

    if [ $(find ${TSTAMPDIR}/ -name \*.yaml | wc -l ) -lt 1 ]; then
        # if we didnt apply anything, dont keep the dir around
        rm -rf $TSTAMPDIR
        echo "R: Nothing to apply"
    fi
done


