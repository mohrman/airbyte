#!/usr/bin/env bash

set -e
set -x

. tools/lib/lib.sh

USAGE="
Usage: $(basename "$0") <cmd>
For publish, if you want to push the spec to the spec cache, provide a path to a service account key file that can write to the cache.
Available commands:
  scaffold
  test <integration_root_path>
  build  <integration_root_path> [<run_tests>]
  publish  <integration_root_path> [<run_tests>] [--publish_spec_to_cache] [--publish_spec_to_cache_with_key_file <path to keyfile>]
  publish_external  <image_name> <image_version>
"

_check_tag_exists() {
  DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect "$1" > /dev/null
}

_error_if_tag_exists() {
    if _check_tag_exists "$1"; then
      error "You're trying to push a version that was already released ($1). Make sure you bump it up."
    fi
}

cmd_scaffold() {
  echo "Scaffolding connector"
  (
    cd airbyte-integrations/connector-templates/generator &&
    ./generate.sh "$@"
  )
}

# TODO: needs to be able to set alternate tag
cmd_build() {
  local path=$1; shift || error "Missing target (root path of integration) $USAGE"
  [ -d "$path" ] || error "Path must be the root path of the integration"

  echo "Building $path"
  ./gradlew --no-daemon "$(_to_gradle_path "$path" clean)"
  ./gradlew --no-daemon "$(_to_gradle_path "$path" build)"

  # TODO: needs to build correct name
  docker tag "$image_name:dev" "$image_candidate_tag"
}

cmd_test() {
  local path=$1; shift || error "Missing target (root path of integration) $USAGE"
  [ -d "$path" ] || error "Path must be the root path of the integration"

  # TODO: needs to know to use alternate image from cmd_build
  echo "Running integration tests..."
  ./gradlew --no-daemon "$(_to_gradle_path "$path" integrationTest)"
}

# Bumps connector version in Dockerfile, definitions.yaml file, and updates seeds with gradle.
# NOTE: this does NOT update changelogs because the changelog markdown files do not have a reliable machine-readable
# format to automatically handle this. Someday it could though: https://github.com/airbytehq/airbyte/issues/12031
cmd_bump_version() {
  # Take params
  local connector_path
  local bump_version
  connector_path="$1" # Should look like airbyte-integrations/connectors/source-X
  bump_version="$2" || bump_version="patch"

  # Set local constants
  connector_path="airbyte-integrations/connectors/destination-postgres"
  connector=${connector_path#airbyte-integrations/connectors/}
  if [[ "$connector" =~ "source-" ]]; then
    connector_type="source"
  elif [[ "$connector" =~ "destination-" ]]; then
    connector_type="destination"
  else
    echo "Invalid connector_type from $connector"
    exit 1
  fi
  dockerfile="$connector_path/Dockerfile"
  # TODO: Make this based on master, not local branch
  current_version=$(_get_docker_image_version "$dockerfile")
  definitions_path="./airbyte-config/init/src/main/resources/seed/${connector_type}_definitions.yaml"

  # Based on current version, decompose into major, minor, patch
  IFS=. read -r major_version minor_version patch_version <<<"${current_version##*-}"

  ## Create new version
  case "$bump_version" in
    "major")
      ((major_version++))
      minor_version=0
      patch_version=0
      ;;
    "minor")
      ((minor_version++))
      patch_version=0
      ;;
    "patch")
      ((patch_version++))
      ;;
    *)
      echo "Invalid bump_version option: $bump_version. Valid options are major, minor, patch"
      exit 1
  esac

  bumped_version="$major_version.$minor_version.$patch_version"
  if [[ "$current_version" == "$bumped_version" ]]; then
    echo "No change in version"
  else
    echo "Bumped $current_version to $bumped_version"
  fi

  ## Write new version to files
  # Dockerfile
  sed -i "s/$current_version/$bumped_version/g" "$dockerfile"

  # Definitions YAML file
  definitions_check=$(yq e ".. | select(has(\"dockerRepository\")) | select(.dockerRepository == \"$connector\")" "$definitions_path")

  if [[ (-z "$definitions_check") ]]; then
    echo "Could not find $connector in $definitions_path, exiting 1"
    exit 1
  fi

  connector_name=$(yq e ".[] | select(has(\"dockerRepository\")) | select(.dockerRepository == \"$connector\") | .name" "$definitions_path")
  yq e "(.[] | select(.name == \"$connector_name\").dockerImageTag)|=\"$bumped_version\"" -i "$definitions_path"

  # Seed files
  ./gradlew :airbyte-config:init:processResources
}

cmd_publish() {
  local path=$1; shift || error "Missing target (root path of integration) $USAGE"
  [ -d "$path" ] || error "Path must be the root path of the integration"

  local publish_spec_to_cache
  local spec_cache_writer_sa_key_file

  while [ $# -ne 0 ]; do
    case "$1" in
    --publish_spec_to_cache)
      publish_spec_to_cache=true
      shift 1
      ;;
    --publish_spec_to_cache_with_key_file)
      publish_spec_to_cache=true
      spec_cache_writer_sa_key_file="$2"
      shift 2
      ;;
    *)
      error "Unknown option: $1"
      ;;
    esac
  done

  if [[ ! $path =~ "connectors" ]]
  then
     # Do not publish spec to cache in case this is not a connector
     publish_spec_to_cache=false
  fi

  # setting local variables for docker image versioning
  local image_name; image_name=$(_get_docker_image_name "$path"/Dockerfile)
  local image_version; image_version=$(_get_docker_image_version "$path"/Dockerfile)
  local image_candidate_tag; image_candidate_tag="$image_version-candidate-PR_NUMBER"

  local versioned_image=$image_name:$image_version
  local latest_image=$image_name:latest

  echo "image_name $image_name"
  echo "versioned_image $versioned_image"
  echo "latest_image $latest_image"

  # in case curing the build / tests someone this version has been published.
  _error_if_tag_exists "$versioned_image"

  if [[ "airbyte/normalization" == "${image_name}" ]]; then
    echo "Publishing normalization images (version: $versioned_image)"
    GIT_REVISION=$(git rev-parse HEAD)
    VERSION=$image_version GIT_REVISION=$GIT_REVISION docker-compose -f airbyte-integrations/bases/base-normalization/docker-compose.build.yaml build
    VERSION=$image_version GIT_REVISION=$GIT_REVISION docker-compose -f airbyte-integrations/bases/base-normalization/docker-compose.build.yaml push
    VERSION=latest         GIT_REVISION=$GIT_REVISION docker-compose -f airbyte-integrations/bases/base-normalization/docker-compose.build.yaml build
    VERSION=latest         GIT_REVISION=$GIT_REVISION docker-compose -f airbyte-integrations/bases/base-normalization/docker-compose.build.yaml push
  else
    # Re-tag with production tag
    docker tag "$image_candidate_tag" "$versioned_image"
    docker tag "$image_candidate_tag" "$latest_image"

    echo "Publishing new version ($versioned_image)"
    docker push "$versioned_image"
    docker push "$latest_image"
  fi
  
  # Checking if the image was successfully registered on DockerHub
  # see the description of this PR to understand why this is needed https://github.com/airbytehq/airbyte/pull/11654/
  sleep 5
  TAG_URL="https://hub.docker.com/v2/repositories/${image_name}/tags/${image_version}"
  DOCKERHUB_RESPONSE_CODE=$(curl --silent --output /dev/null --write-out "%{http_code}" ${TAG_URL})
  if [[ "${DOCKERHUB_RESPONSE_CODE}" == "404" ]]; then
    echo "Tag ${image_version} was not registered on DockerHub for image ${image_name}, please try to bump the version again." && exit 1
  fi

  if [[ "true" == "${publish_spec_to_cache}" ]]; then
    echo "Publishing and writing to spec cache."

    # publish spec to cache. do so, by running get spec locally and then pushing it to gcs.
    local tmp_spec_file; tmp_spec_file=$(mktemp)
    docker run --rm "$versioned_image" spec | \
      # 1. filter out any lines that are not valid json.
      jq -R "fromjson? | ." | \
      # 2. grab any json that has a spec in it.
      # 3. if there are more than one, take the first one.
      # 4. if there are none, throw an error.
      jq -s "map(select(.spec != null)) | map(.spec) | first | if . != null then . else error(\"no spec found\") end" \
      > "$tmp_spec_file"

    # use service account key file is provided.
    if [[ -n "${spec_cache_writer_sa_key_file}" ]]; then
      echo "Using provided service account key"
      gcloud auth activate-service-account --key-file "$spec_cache_writer_sa_key_file"
    else
      echo "Using environment gcloud"
    fi

    gsutil cp "$tmp_spec_file" "gs://io-airbyte-cloud-spec-cache/specs/$image_name/$image_version/spec.json"
  else
    echo "Publishing without writing to spec cache."
  fi
}

cmd_publish_external() {
  local image_name=$1; shift || error "Missing target (image name) $USAGE"
  # Get version from the command
  local image_version=$1; shift || error "Missing target (image version) $USAGE"

  echo "image $image_name:$image_version"

  echo "Publishing and writing to spec cache."
  # publish spec to cache. do so, by running get spec locally and then pushing it to gcs.
  local tmp_spec_file; tmp_spec_file=$(mktemp)
  docker run --rm "$image_name:$image_version" spec | \
    # 1. filter out any lines that are not valid json.
    jq -R "fromjson? | ." | \
    # 2. grab any json that has a spec in it.
    # 3. if there are more than one, take the first one.
    # 4. if there are none, throw an error.
    jq -s "map(select(.spec != null)) | map(.spec) | first | if . != null then . else error(\"no spec found\") end" \
    > "$tmp_spec_file"

  echo "Using environment gcloud"

  gsutil cp "$tmp_spec_file" "gs://io-airbyte-cloud-spec-cache/specs/$image_name/$image_version/spec.json"
}

main() {
  assert_root

  local cmd=$1; shift || error "Missing cmd $USAGE"
  cmd_"$cmd" "$@"
}

main "$@"
