#!/bin/bash

err() {
	local MSG="${1}"

  echo -e "[ERROR] ${MSG}"
}

info() {
	local MSG="${1}"

  echo -e "[INFO] ${MSG}"
}

debug() {
	local MSG="${1}"

  echo -e "[DEBUG] ${MSG}"
}

clone_scoop_repos() {
  mkdir -p scoop

  info "Cloning all scoop repos"
  git clone --depth 1 git@github.com:ScoopInstaller/Extras.git scoop/extras
  git clone --depth 1 git@github.com:ScoopInstaller/Nonportable.git scoop/nonportable
  git clone --depth 1 git@github.com:ScoopInstaller/Java.git scoop/java
  git clone --depth 1 git@github.com:ScoopInstaller/Main.git scoop/main
  git clone --depth 1 git@github.com:niheaven/scoop-sysinternals.git scoop/sysinternals
  git clone --depth 1 git@github.com:ScoopInstaller/Versions.git scoop/versions
}

process_urls() {
  local ARTIFACT="${1}"
  local SCOOP_VERSION="${2}"
  local SCOOP_JSON="${3}"

  jq --arg new_version "${SCOOP_VERSION}" '.version |= $new_version' bucket/${ARTIFACT}.json > bucket/${ARTIFACT}.json.tmp
  mv bucket/${ARTIFACT}.json.tmp bucket/${ARTIFACT}.json

  URL=$(jq -r ".url" ${SCOOP_JSON})
  if [ ! "${URL}" = "null" ]; then
    jq --arg new_url "${URL}" '.url |= $new_url' bucket/${ARTIFACT}.json > bucket/${ARTIFACT}.json.tmp
    mv bucket/${ARTIFACT}.json.tmp bucket/${ARTIFACT}.json
  fi

  EXTRACT_DIR=$(jq -r ".extract_dir" ${SCOOP_JSON})
  if [ ! "${EXTRACT_DIR}" = "null" ]; then
    jq --arg new_extract_dir "${EXTRACT_DIR}" '.extract_dir |= $new_extract_dir' bucket/${ARTIFACT}.json > bucket/${ARTIFACT}.json.tmp
    mv bucket/${ARTIFACT}.json.tmp bucket/${ARTIFACT}.json
  fi
  
  HASH=$(jq -r ".hash" ${SCOOP_JSON})
  if [ ! "${HASH}" = "null" ]; then
    jq --arg new_hash "${HASH}" '.hash |= $new_hash' bucket/${ARTIFACT}.json > bucket/${ARTIFACT}.json.tmp
    mv bucket/${ARTIFACT}.json.tmp bucket/${ARTIFACT}.json
  fi
  
  ARCHITECTURES=$(jq -r ".architecture" ${SCOOP_JSON})
  if [ ! "${ARCHITECTURES}" = "null" ]; then
    jq  ".architecture = ${ARCHITECTURES}" bucket/${ARTIFACT}.json > bucket/${ARTIFACT}.json.tmp
    mv bucket/${ARTIFACT}.json.tmp bucket/${ARTIFACT}.json
  fi
}

if ! command -v mvn &> /dev/null 2>/dev/null; then
  err "mvn not found on PATH"
  exit 1
fi

clone_scoop_repos

UPDATE_PACKAGE_NAMES=()
UPDATE_PACKAGE_DESCRIPTIONS=()
PACKAGES=($(ls -d bucket/*.json))
PADDING="                        "
for PACKAGE in "${PACKAGES[@]}"
do :
  ARTIFACT="$(echo ${PACKAGE::-5} | cut -c8-)"
  IBB_VERSION=$(jq ".version" bucket/${ARTIFACT}.json) 
  IBB_VERSION=${IBB_VERSION//\"/} # Strip double quote

  info "${ARTIFACT} - ${IBB_VERSION} -- in progress"
  SCOOP_JSON=$(ls scoop/*/bucket/$ARTIFACT.json 2> /dev/null)
  SCOOP_SEARCH=$?
  if [ ${SCOOP_SEARCH} -eq 0 ]; then
    SCOOP_VERSION=$(jq ".version" ${SCOOP_JSON})
    SCOOP_VERSION=${SCOOP_VERSION//\"/} # Strip double quote
    
    if [ "${SCOOP_VERSION}" = "${IBB_VERSION}" ]; then
      # Check if this is a new package that isn't in the scoop default repos that hasn't been migrated yet.
      REPO_DOWNLOADED=$(grep repo.ibboost.com bucket/${ARTIFACT}.json | wc -l)
      if [ "$REPO_DOWNLOADED" = "0" ]; then
        UPDATE_PACKAGE_NAMES+=("${ARTIFACT}")
        UPDATE_PACKAGE_DESCRIPTIONS+=("${ARTIFACT_PADDING} ${ARTIFACT} - ${SCOOP_VERSION}")
      else
        info "${ARTIFACT} - ${IBB_VERSION} -- noop"
      fi
    else
      process_urls ${ARTIFACT} ${SCOOP_VERSION} ${SCOOP_JSON}
      info "${ARTIFACT} - ${IBB_VERSION} -> ${SCOOP_VERSION} -- updated"
      UPDATE_PACKAGE_NAMES+=("${ARTIFACT}")
      ARTIFACT_PADDING=$(printf '%s\n' "$ARTIFACT${PADDING:${#ARTIFACT}}")
      UPDATE_PACKAGE_DESCRIPTIONS+=("${ARTIFACT_PADDING} ${ARTIFACT} - ${IBB_VERSION} -> ${SCOOP_VERSION}")
    fi
  else
      # Check if this is a new package that isn't in the scoop default repos that hasn't been migrated yet.
      REPO_DOWNLOADED=$(grep repo.ibboost.com bucket/${ARTIFACT}.json | wc -l)
      if [ "$REPO_DOWNLOADED" = "0" ]; then
        UPDATE_PACKAGE_NAMES+=("${ARTIFACT}")
        UPDATE_PACKAGE_DESCRIPTIONS+=("${ARTIFACT_PADDING} ${ARTIFACT} - ${SCOOP_VERSION}")
      else
        info "${ARTIFACT} - No json package found from scoop repos and package has already been migrated -- noop"
      fi
  fi
  
  # Padding for a new line.
  info
done

debug "Deleting local scoop repos after processing complete -> scoop/"
rm -rf "scoop/"
info "Running migrate installers to download/upload updated packages to repo.ibboost.com"
./scripts/migrate-installers.sh

if [ $? -ne 0 ]; then
  err "migrate-installers.sh failed. Please investigate"
  exit 1
fi

# Commit changes to the packages only if there were any changes processed
NUMBER_OF_PACKAGES_UPDATED=${#UPDATE_PACKAGE_NAMES[@]}
if [ ${NUMBER_OF_PACKAGES_UPDATED} -gt 0 ]; then

  info "Updating package info and pushing to git"
  git add bucket/*
  
  COMMIT_MSG="${NUMBER_OF_PACKAGES_UPDATED} packages updated: "
  for UPDATE in "${UPDATE_PACKAGE_NAMES[@]}"
  do :
    COMMIT_MSG+="${UPDATE} "
  done

  LONG_COMMIT_MSG=""
  for UPDATE in "${UPDATE_PACKAGE_DESCRIPTIONS[@]}"
  do :
    LONG_COMMIT_MSG="\t${UPDATE}\n"
  done

  COMMIT_MSG+="\n$LONG_COMMIT_MSG"
  echo -e $COMMIT_MSG > commit.msg

  git commit --file commit.msg
  rm -f commit.msg
  git push --set-upstream origin main

  if [ $? -ne 0 ]; then
    err "Failed to push commit. Please fix"
    exit 1
  fi
fi

info
info
for UPDATE in "${UPDATE_PACKAGE_DESCRIPTIONS[@]}"; do
  info "${UPDATE}"
done
info
info "${NUMBER_OF_PACKAGES_UPDATED} packages updated"
