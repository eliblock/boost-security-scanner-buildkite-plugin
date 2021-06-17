#!/bin/bash

set -e
set -o pipefail
set -u

set -x

declare VAR_PREFIX=BUILDKITE_PLUGIN_BOOST_SECURITY_SCANNER
declare BOOST_BIN_VERSION=${BOOST_BIN_VERSION:-}

export BOOST_BIN=${BOOST_BIN:-${TMPDIR:-/tmp}/boost.sh}
export BOOST_CLI=${BOOST_CLI:-${TMPDIR:-/tmp}/boost-cli}
export BOOST_ENV=${BOOST_ENV:-${TMPDIR:-/tmp}/boost.env}

log.info ()
{ # $@=message
  printf "$(date +'%H:%m:%S') [\033[34m%s\033[0m] %s\n" "INFO" "${*}";
}

log.error ()
{ # $@=message
  printf "$(date +'%H:%m:%S') [\033[31m%s\033[0m] %s\n" "ERROR" "${*}";
}

config.get ()
{ # $1=key, [$2=default]
  declare _varname=${VAR_PREFIX}_${1}
  declare value=${!_varname:-}
  echo ${value:-${2:-}}
}

env.list ()
{ awk 'BEGIN{for(v in ENVIRON) print v}'; }

env.list.boost ()
{ env.list | grep "^BOOST_"; }

init.config ()
{
  log.info "initializing configuration"
  export BOOST_GIT_BRANCH=${BUILDKITE_BRANCH:-}
  export BOOST_GIT_PROJECT=$(config.get "PROJECT_SLUG")
  export BOOST_GIT_HEAD=${BUILDKITE_COMMIT}
  export BOOST_GIT_BASE=${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}

  if [ -z "${BOOST_API_ENDPOINT:-}" ]; then
    export BOOST_API_ENDPOINT=$(config.get "API_ENDPOINT" "https://api.boostsecurity.io")
  fi

  export BOOST_API_TOKEN=${BOOST_API_TOKEN:-$(config.get "API_TOKEN")}

  if [ -z "${BOOST_GIT_PROJECT:-}" ]; then
    export BOOST_GIT_PROJECT=$(echo "${BUILDKITE_REPO}" | \
      sed -r 's/.*(\@|\/\/)(.*)(\:|\/)([^:\/]*)\/([^\/\.]*)(\.git)?/\4\/\5/'
    )
  fi

  if [ -n "${BUILDKITE_PULL_REQUEST:-}" ] &&
     [ "${BUILDKITE_PULL_REQUEST}" != "false" ];
  then
    export BOOST_GIT_PULL_REQUEST=${BUILDKITE_PULL_REQUEST}
  fi

  if [ -n "${BUILDKITE_PIPELINE_DEFAULT_BRANCH:-}" ]; then
    export BOOST_GIT_MAIN_BRANCH=${BUILDKITE_PIPELINE_DEFAULT_BRANCH}
  fi

  export BOOST_SCANNER_IMAGE=${BOOST_SCANNER_IMAGE:-$(config.get \
    "SCANNER_IMAGE" \
    "706352083976.dkr.ecr.us-east-2.amazonaws.com/scanner" \
  )}
  export BOOST_SCANNER_VERSION=${BOOST_SCANNER_VERSION:-$(config.get \
    "SCANNER_VERSION" \
    "2.0" \
  )}
}

init.cli ()
{
  if [ -f "${BOOST_BIN:-}" ]; then
    return
  fi

  log.info "installing cli to ${BOOST_BIN}"
  declare url=${BOOST_API_ENDPOINT/api/assets}
  declare version=${BOOST_BIN_VERSION:-${BOOST_SCANNER_VERSION}}

  url=${url%*/}
  if [ -d /lib/apk ]; then
    url+="/boost/linux/alpine/amd64/${version}/boost.sh"
  else
    url+="/boost/linux/glibc/amd64/${version}/boost.sh"
  fi

  curl --silent --output "${BOOST_BIN}" "${url}"
  chmod 755 "${BOOST_BIN}"
}

init.git ()
{
  log.info "initializing git environment"

  if $(git rev-parse --is-shallow-repository); then
    log.info "detected shallow repository"
    if [ -n "${BOOST_GIT_BASE:-}" ]; then
      log.info "fetching base revision from ${BOOST_GIT_BASE}"
      git fetch --depth=1 origin "${BOOST_GIT_BASE}"
      BOOST_GIT_BASE=$(git rev-parse FETCH_HEAD)

      log.info "fetching additional history items"
      git fetch --filter=blob:none origin "${BOOST_GIT_HEAD}"
      git fetch --negotiation-tip="${BOOST_GIT_BASE}" \
                --no-tags \
                --unshallow \
                origin "${BOOST_GIT_HEAD}"
    else
      log.info "fetching additional history items"
      git fetch --deepen=2 origin "${BOOST_GIT_HEAD}"
    fi
  else
    if [ -n "${BOOST_GIT_BASE:-}" ]; then
      log.info "fetching additional history items"
      git fetch --force origin "${BOOST_GIT_BASE}"
      BOOST_GIT_BASE=$(git rev-parse FETCH_HEAD)
    fi
  fi

  if [ -f ".git/objects/info/alternates" ]; then
    log.info "detected mirrored repository, repacking"
    git repack -a -d
    rm .git/objects/info/alternates
  fi
}

init.env_file ()
{
  log.info "creating env file at ${BOOST_ENV}"

  while read name; do
    echo "${name}=${!name:-}" >> "${BOOST_ENV}"
  done < <(env.list.boost)
}

main.complete ()
{
  init.config
  init.git
  init.cli
  ${BOOST_BIN} scan complete --ci
  ! test -f "${BOOST_BIN:-}" || rm "${BOOST_BIN}"
  ! test -d "${BOOST_CLI:-}" || rm -rf "${BOOST_CLI}"
  ! test -f "${BOOST_ENV:-}" || rm "${BOOST_ENV}"
}

main.exec ()
{
  init.config
  init.git
  init.cli

  if [ -z "${BOOST_EXEC_COMMAND:-}" ]; then
    declare BOOST_EXEC_COMMAND=$(config.get "EXEC_COMMAND")
  fi

  if [ -z "${BOOST_EXEC_COMMAND:-}" ]; then
    log.error "the 'exec_command' option must be defined when in exec mode"
    exit 1
  fi

  declare BOOST_ADDITIONAL_ARGS=${BOOST_ADDITIONAL_ARGS:-$(config.get "ADDITIONAL_ARGS")}
  BOOST_SCANNER_DEBUG=true ${BOOST_BIN} scan ci ${BOOST_ADDITIONAL_ARGS:-} --sarif-cmd "${BOOST_EXEC_COMMAND}"
}

main.scan ()
{
  trap 'main.scan.exit' EXIT

  init.config
  init.git
  init.env_file

  declare BOOST_ADDITIONAL_ARGS=${BOOST_ADDITIONAL_ARGS:-$(config.get "ADDITIONAL_ARGS")}
  declare BOOST_DOCKER_CREATE_ARGS=${BOOST_DOCKER_CREATE_ARGS:-$(config.get "DOCKER_CREATE_ARGS")}
  declare BOOST_EXEC_COMMAND=${BOOST_EXEC_COMMAND:-$(config.get "EXEC_COMMAND")}

  if [ -n "${BOOST_EXEC_COMMAND:-}" ]; then
    log.error "the 'exec_command' option must only be defined in exec mode"
    exit 1
  fi

  log.info "creating scanner container"
  declare cid_file=/tmp/boost-container
  rm -f "${cid_file}"

  declare -a CREATE_ARGS
  CREATE_ARGS=(create
    --cidfile "${cid_file}"
    --env-file "${BOOST_ENV}"
    --entrypoint boost
    --rm ${BOOST_DOCKER_CREATE_ARGS:-}
    --tty \
    "${BOOST_SCANNER_IMAGE}:${BOOST_SCANNER_VERSION}"
    scan ci ${BOOST_ADDITIONAL_ARGS:-} --path /app/mount
  )

  docker pull "${BOOST_SCANNER_IMAGE}:${BOOST_SCANNER_VERSION}"
  docker "${CREATE_ARGS[@]}"

  declare container_id=$(cat "${cid_file}")
  docker cp "${BUILDKITE_BUILD_CHECKOUT_PATH}/." "${container_id}:/app/mount/"

  log.info "starting scanner"
  docker start --attach "${container_id}"
}

main.scan.exit ()
{
  declare cid_file=/tmp/boost-container

  if [ -f "${cid_file}" ]; then
    declare cid=$(cat ${cid_file})

    if [ -n "${cid:-}" ]; then
      docker stop "${cid}" &> /dev/null || true
      docker rm "${cid}" &> /dev/null || true
    fi

    rm "${cid_file}"
  fi

  ! test -f "${BOOST_ENV:-}" || rm "${BOOST_ENV}"
}
