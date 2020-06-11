#!/bin/bash

# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

PLANK_DEPLOYMENT_FILE="${PLANK_DEPLOYMENT_FILE:-}"
# Args for use with GH
GH_ORG="${GH_ORG:-}"
GH_REPO="${GH_REPO:-}"
FORK_GH_REPO="${FORK_GH_REPO:-${GH_REPO}}"
# Args for use with Gerrit
GERRIT_HOST_REPO="${GERRIT_HOST_REPO:-}"

# Set this to something more specific if the repo hosts multiple Prow instances.
# Must be a valid to use as part of a git branch name. (e.g. no spaces)
PROW_INSTANCE_NAME="${PROW_INSTANCE_NAME:-prow}"



# TODO(fejta): rewrite this in a better language REAL SOON  <-lol
main() {
	if [[ $# -lt 1 ]]; then
	    echo "Usage: $(basename "$0") <path to github token or http cookiefile> [git-name] [git-email]" >&2
	    exit 1
	fi
	creds=$1
	shift
	check-args
	ensure-git-config "$@"

	echo "Bumping ${PROW_INSTANCE_NAME} to upstream (prow.k8s.io) version..." >&2
	/bump.sh --upstream

	cd "$(git rev-parse --show-toplevel)"
	old_version=$(git show "HEAD:${PLANK_DEPLOYMENT_FILE}" | extract-version)
	version=$(cat "${PLANK_DEPLOYMENT_FILE}" | extract-version)

	if [[ "${old_version}" == "${version}" ]]; then
		echo "Bump did not change the Prow version. Aborting no-op bump." >&2
		exit 0
	fi
	git add -u
	title="Bump ${PROW_INSTANCE_NAME} from ${old_version} to ${version}"

	if [[ -n "${GH_ORG}" ]]; then
		create-gh-pr
	else
		create-gerrit-pr
	fi

	echo "autobump.sh completed successfully!" >&2
}

user-from-token() {
	user=$(curl -H "Authorization: token $(cat "${token}")" "https://api.github.com/user" 2>/dev/null | sed -n "s/\s\+\"login\": \"\(.*\)\",/\1/p")
}

ensure-git-config() {
  if [[ $# -eq 2 ]]; then
    echo "git config user.name=$1 user.email=$2..." >&2
    git config user.name "$1"
    git config user.email "$2"
  fi
  git config user.name &>/dev/null && git config user.email &>/dev/null && return 0
  echo "ERROR: git config user.name, user.email unset. No defaults provided" >&2
  return 1
}

check-args() {
	if [[ -z "${PLANK_DEPLOYMENT_FILE}" ]]; then
  	echo "ERROR: $PLANK_DEPLOYMENT_FILE must be specified." >&2
  	exit 1
	fi
	if [[ -z "${GERRIT_HOST_REPO}" ]]; then
		if [[ -z "${GH_ORG}" || -z "${GH_REPO}" ]]; then
	  	echo "ERROR: GH_ORG and GH_REPO must be specified to create a GitHub PR." >&2
	  	exit 1
		fi
	else
		if [[ -n "${GH_ORG}" || -n "${GH_REPO}" ]]; then
	  	echo "ERROR: GH_ORG and GH_REPO cannot be used with GERRIT_HOST_REPO." >&2
	  	exit 1
		fi
		if [[ -z "${GERRIT_HOST_REPO}" ]]; then
	  	echo "ERROR: GERRIT_HOST_REPO must be specified to create a Gerrit PR." >&2
	  	exit 1
		fi
	fi
}

create-gh-pr() {
	git commit -m "${title}"

	token="${creds}"
	user-from-token
	
	echo -e "Pushing commit to github.com/${user}/${FORK_GH_REPO}:autobump-${PROW_INSTANCE_NAME}..." >&2
	git push -f "https://${user}:$(cat "${token}")@github.com/${user}/${FORK_GH_REPO}" "HEAD:autobump-${PROW_INSTANCE_NAME}" 2>/dev/null

	echo "Creating PR to merge ${user}:autobump-${PROW_INSTANCE_NAME} into master..." >&2
	comparison=$(extract-commit "${old_version}")...$(extract-commit "${version}")
	/pr-creator \
	  --github-token-path="${token}" \
	  --org="${GH_ORG}" --repo="${GH_REPO}" --branch=master \
	  --title="${title}" --match-title="Bump prow from" \
	  --body="Included changes: https://github.com/kubernetes/test-infra/compare/${comparison}" \
	  --source="${user}:autobump-${PROW_INSTANCE_NAME}" \
	  --confirm
}

create-gerrit-pr() {
  git config http.cookiefile "${creds}"
  git remote add upstream "${GERRIT_HOST_REPO}"

	change="$( echo "${GERRIT_HOST_REPO}; ${PROW_INSTANCE_NAME}; ${old_version}" | git hash-object --stdin)"
	git commit -m "${title}

Change-Id: I${change}"

	git push upstream HEAD:refs/for/master
}

# Convert image: gcr.io/k8s-prow/plank:v20181122-abcd to v20181122-abcd
extract-version() {
  local v=$(grep plank:v "$@")
  echo ${v##*plank:}
}
# Convert v20181111-abcd to abcd
extract-commit() {
  local c=$1
  echo ${c##*-}
}

main "$@"
