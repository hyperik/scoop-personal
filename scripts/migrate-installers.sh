#!/bin/bash
export REPOID="thirdparty-private"
export REPO_URL="https://repo.ibboost.com"
export REPO_UPLOAD_URL="$REPO_URL/content/repositories/${REPOID}"
export GROUPID="scoop"

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

download_and_deploy_artifact() {
  local ARTIFACT="${1}"
  local VERSION="${2}"
  local ARCH="${3}"
  local DOWNLOAD_URL="${4}"
  local ARTIFACT_PATH="${5}"
  DOWNLOAD_DIR="local/${ARTIFACT_PATH}"

  if [[ ${DOWNLOAD_URL} = ${REPO_URL}/* ]]; then
    info "${ARTIFACT} / ${VERSION} / ${ARCH} -- noop"
  else
    info "IN PROGRESS: ${ARTIFACT} / ${VERSION} / ${ARCH}"
    PACKAGES_PROCESSED+=("${ARTIFACT} / ${VERSION} / ${ARCH}")

    if [ -d "${DOWNLOAD_DIR}" ]; then
      debug "Deleting existing DOWNLOAD_DIR ${DOWNLOAD_DIR}"
      rm -rf "${DOWNLOAD_DIR}"
    fi

    mkdir -p ${DOWNLOAD_DIR}
    debug "Attempting to download ${DOWNLOAD_URL} -> ${DOWNLOAD_DIR}"

    # Download the package to the download directory
    wget -q $DOWNLOAD_URL -P $DOWNLOAD_DIR
    if [ $? -ne 0 ]; then
      err "Failed to download resource from ${DOWNLOAD_URL}"
      exit 1
    else
      debug "Downloaded successfully to staging file: $(ls "${DOWNLOAD_DIR}")"
    fi

    DOWNLOAD_FILE=$(ls ${DOWNLOAD_DIR})
    DOWNLOAD_FILE_BASE=$(basename -- "$DOWNLOAD_URL")
    DOWNLOAD_FILE_PACKAGING="${DOWNLOAD_FILE_BASE##*.}"
    DOWNLOAD_FILE_BASE="${DOWNLOAD_FILE_BASE%.*}"
    DOWNLOAD_FILE_BASE="${DOWNLOAD_FILE_BASE##*=}"
    ARTIFACTID="${ARTIFACT}"

    # Since we're splitting on classifier and these mingw downloads all have the archive type lzma 
    # we have to split them out into individual downloads so it's clean and we don't have weird looking/tagged artifacts.
    if [[ "${DOWNLOAD_URL}" =~ ^https://downloads.sourceforge.net/project/mingw* ]]; then
      ARTIFACT_DOWNLOAD="${DOWNLOAD_URL##*mingw/}"
      ARTIFACTID=$(echo "${ARTIFACT_DOWNLOAD}" | cut -d "/" -f 3)
      VERSION=$(echo "${ARTIFACT_DOWNLOAD}" | cut -d "/" -f 4)
      VERSION="${VERSION##*${ARTIFACTID}-}"
      ARTIFACT_PATH="${ARTIFACTID}/${VERSION}"
    elif [[ "$DOWNLOAD_URL" =~ ^http://xmlsoft.org/sources/win32/64bit* ]]; then
      # xmllint workaround

      ARTIFACT_DOWNLOAD="${DOWNLOAD_URL##*64bit/}"
      ARTIFACTID=$(echo "${ARTIFACT_DOWNLOAD}" | cut -d "-" -f 1)
      VERSION=$(echo "${ARTIFACT_DOWNLOAD}" | cut -d "-" -f 2)
      VERSION="${VERSION##*${ARTIFACTID}-}"
      ARTIFACT_PATH="${ARTIFACTID}/${VERSION}"
    elif [[ "$ARTIFACT" == vcredist* ]]; then
      # vcredist puts both x86 and x64 downloads in the same architecture so grab the arch so we can separate the downloads
      ARTIFACTID=${DOWNLOAD_FILE_BASE}
      ARTIFACT_PATH="${ARTIFACTID}/${VERSION}"
    elif [[ "$DOWNLOAD_URL" == *.exe.xz ]]; then
      DOWNLOAD_FILE_PACKAGING="xz"
    elif [[ "$DOWNLOAD_URL" == *\.tar\.* ]]; then
      DOWNLOAD_FILE_PACKAGING="tar.${DOWNLOAD_FILE##*.}"
    elif [[ "$DOWNLOAD_URL" == *.jar ]]; then
      # Jenkins special case
      DOWNLOAD_FILE_PACKAGING="jar"

      ZIP_PACKAGED_FILE="${DOWNLOAD_FILE_BASE}.jar"
      mv "${DOWNLOAD_DIR}/${DOWNLOAD_FILE}" "${DOWNLOAD_DIR}/${ZIP_PACKAGED_FILE}"
      DOWNLOAD_FILE="${ZIP_PACKAGED_FILE}"
    elif [[ "$DOWNLOAD_URL" == *_ ]]; then
      # Underscore at the end means the install script doesn't want scoop to extract the package.
      if [[ "$DOWNLOAD_FILE_PACKAGING" != *_  ]]; then
        DOWNLOAD_FILE_PACKAGING="${DOWNLOAD_FILE_PACKAGING}_"
      fi

      ZIP_PACKAGED_FILE="${DOWNLOAD_FILE_BASE}.${DOWNLOAD_FILE_PACKAGING}"
      mv "${DOWNLOAD_DIR}/${DOWNLOAD_FILE}" "${DOWNLOAD_DIR}/${ZIP_PACKAGED_FILE}"
      DOWNLOAD_FILE="${ZIP_PACKAGED_FILE}"
    elif [[ "$DOWNLOAD_URL" == *#/* ]]; then
      # Special URLs that do some processing so aren't a reliable way to retrieve the final extension
      # Instead get the extension from the downloaded file itself
	  
	  # TODO: Processing for dl.7z that extract to exe
      if [[ "$DOWNLOAD_URL" == *dl.7z ]]; then
        # Post download it should extract so add this back and shuffle
        DOWNLOAD_FILE_PACKAGING="7z"
        ZIP_PACKAGED_FILE="${DOWNLOAD_FILE}_dl.7z"
        mv "${DOWNLOAD_DIR}/${DOWNLOAD_FILE}" "${DOWNLOAD_DIR}/${ZIP_PACKAGED_FILE}"
        DOWNLOAD_FILE="${ZIP_PACKAGED_FILE}"
      else
        # Instead get the extension from the downloaded file itself
        DOWNLOAD_FILE_PACKAGING="${DOWNLOAD_FILE##*.}"
      fi
    fi

    REPO_DOWNLOAD_URL="${REPO_URL}/repository/${REPOID}/${GROUPID}/${ARTIFACT_PATH}/${ARTIFACTID}-${VERSION}-${ARCH}.${DOWNLOAD_FILE_PACKAGING}"
    debug "Attempting to upload ${DOWNLOAD_DIR}/${DOWNLOAD_FILE} -> ${REPO_DOWNLOAD_URL}"

    mvn -s local/settings.xml deploy:deploy-file \
      -Durl="${REPO_UPLOAD_URL}" \
      -DrepositoryId="${REPOID}" \
      -DgroupId="${GROUPID}" \
      -DartifactId="${ARTIFACTID}" \
      -Dversion="${VERSION}" \
      -Dpackaging="${DOWNLOAD_FILE_PACKAGING}" \
      -Dclassifier="${ARCH}" \
      -Dfile="${DOWNLOAD_DIR}/${DOWNLOAD_FILE}" || err "Maven deploy returned a non-zero exit code when uploading ${DOWNLOAD_DIR}/${DOWNLOAD_FILE}"

    debug "Clean up DOWNLOAD_FILE after processing is complete -> ${DOWNLOAD_DIR}/${DOWNLOAD_FILE}"
    rm -rf "${DOWNLOAD_DIR}/${DOWNLOAD_FILE}"

    debug "Updating package json file with nexus download url ${DOWNLOAD_URL} -> ${REPO_DOWNLOAD_URL}"
    if [[ "${ARCH}" = "any" ]]; then
      sed -i "s,${DOWNLOAD_URL},${REPO_DOWNLOAD_URL}," "bucket/${ARTIFACT}.json"
    elif [[ "${ARCH}" != "noarch" ]]; then
    
      OLD_DOWNLOAD_URL=$(jq -r ".architecture.\"${ARCH}\".url" "bucket/${ARTIFACT}.json")
      if [[ "${OLD_DOWNLOAD_URL}" =~ ^http.* ]]; then
        debug "Updating multiarch ${ARCH} single url"
        ARCH_URL=".architecture.\"${ARCH}\".url = \"${REPO_DOWNLOAD_URL}\""
        jq "${ARCH_URL}" bucket/"${ARTIFACT}".json > "tmp.json" && mv "tmp.json" "bucket/${ARTIFACT}.json"
      else
        debug "Updating multiarch ${ARCH} multi url"
        # Note: Sometimes the URLs for different architectures are the same but we want them to point to their respective architecture download URLs.
        # So we must extract the architecture urls and process them individually before pushing them back into the bucket.
        jq -r ".architecture.\"${ARCH}\"" "bucket/${ARTIFACT}.json" | tr -d '[:blank:]' | tr -d '\n' > tmp.json
        sed -i "s,${DOWNLOAD_URL},${REPO_DOWNLOAD_URL}," tmp.json
        NEW_DOWNLOAD_URLS=$(cat tmp.json)
        ARCH_URL=".architecture.\"${ARCH}\" = ${NEW_DOWNLOAD_URLS}"
        jq "${ARCH_URL}" bucket/"${ARTIFACT}".json > "tmp.json" && mv "tmp.json" "bucket/${ARTIFACT}.json"
      fi
    else
      sed -i "s,${DOWNLOAD_URL},${REPO_DOWNLOAD_URL}," "bucket/${ARTIFACT}.json"
    fi
  fi

}

process_multiple_urls() {
  local ARTIFACT="${1}"
  local VERSION="${2}"
  local ARTIFACT_PATH="${3}"
  local URL_QUERY_PATH="${4}"
  local ARCH="${5}"

  # The URL variable can be a single download or an array of downloads.
  DOWNLOAD_URLS=($(jq -r "${URL_QUERY_PATH}" bucket/${ARTIFACT}.json | jq -c '.[]'))

  for DOWNLOAD_URL in "${DOWNLOAD_URLS[@]}"; do
    DOWNLOAD_URL=${DOWNLOAD_URL//\"/} # Remove quotes
    download_and_deploy_artifact "${ARTIFACT}" "${VERSION}" "${ARCH}" "${DOWNLOAD_URL}" "${ARTIFACT_PATH}"
  done
}

template_maven_settings() {
  THIRDPARTY_UPLOADER_PASSWORD=$(pass infra/nexus/ibb.tech.thirdpartyuploader)
  mkdir -p local
  cp files/settings.xml local/settings.xml
  sed -i "s/THIRDPARTY_UPLOADER_PASSWORD/$THIRDPARTY_UPLOADER_PASSWORD/" local/settings.xml
}

template_maven_settings

PACKAGES=($(ls -d bucket/*.json))

for PACKAGE in "${PACKAGES[@]}"
do :
  ARTIFACT="$(echo ${PACKAGE::-5} | cut -c8-)"
  
  VERSION=$(jq ".version" bucket/${ARTIFACT}.json)
  VERSION=${VERSION//\"/} # Strip double quote
  ARTIFACT_PATH="${ARTIFACT}/${VERSION}"
  PACKAGES_PROCESSED=()

  info "${ARTIFACT} / ${VERSION}"

  URL=$(jq -r ".url" bucket/${ARTIFACT}.json)
  if [ ! "${URL}" = "null" ]; then
    if [[ "${URL}" =~ ^http.* ]]; then
      download_and_deploy_artifact "${ARTIFACT}" "${VERSION}" "any" "${URL}" "${ARTIFACT_PATH}"
    else 
      process_multiple_urls "${ARTIFACT}" "${VERSION}" "${ARTIFACT_PATH}" ".url" "noarch"
    fi
  else
    ARCHITECTURES=$(jq -r ".architecture" bucket/${ARTIFACT}.json)
    ARCH_TYPES=($(echo ${ARCHITECTURES} | jq -r 'keys_unsorted | @sh'))

    for ARCH in "${ARCH_TYPES[@]}"
    do :
      ARCH=${ARCH//\'/}
      # Workaround for dictionary keys that start numerically.
      DOWNLOAD_URL=$(echo $ARCHITECTURES | jq -r ".\"$ARCH\".url")
      if [[ "${DOWNLOAD_URL}" =~ ^http.* ]]; then
        download_and_deploy_artifact "${ARTIFACT}" "${VERSION}" "${ARCH}" "${DOWNLOAD_URL}" "${ARTIFACT_PATH}"
      else
        process_multiple_urls "${ARTIFACT}" "${VERSION}" "${ARTIFACT_PATH}" ".architecture.\"${ARCH}\".url" "${ARCH}"
      fi
    done
  fi

  # Delete autoupdate field if it exists.
  AUTOUPDATE=$(jq -r ".autoupdate" bucket/${ARTIFACT}.json)
  if [ ! "${AUTOUPDATE}" = "null" ]; then
    jq 'del(.autoupdate)' bucket/${ARTIFACT}.json > bucket/${ARTIFACT}.json.tmp
    mv bucket/${ARTIFACT}.json.tmp bucket/${ARTIFACT}.json
  fi
done

debug "Deleting local download directory after processing complete -> local/"
rm -rf "local/"