#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# ---------------------------------------------------------------------
# Define functions used in the script
# ---------------------------------------------------------------------

#
# Version check
#
# Based on the version type, (internal or external),
# attempt to use git ls-remote to obtain the latest tag (version)
# from the appropriate Git repository.  If found, check
# it against the script version.  If different, suggest the
# user update to the version in the Git repository
# which presumes that the Git repository has a version higher
# than the current script version.
#
version_check() {
  _ASHTYPE="${VERSION%-*}" # remove the date portion
  _ASHTYPE="${_ASHTYPE#*-}" # remove the version number portion
  _GITREPO="git@github.com:awslabs/automated-security-helper.git"

  #
  # list the tag values and sort based on "version sort"
  # take the "latest/highest" version
  #
  _REPO_VERSION=$(git ls-remote --tags "${_GITREPO}" 2>/dev/null \
                  | cut -f2 | cut -f3 -d"/" \
                  | sed -E "s/\^\{\}//" \
                  | grep -v "version1.0"| sort -Vr \
                  | head -1 )

  #
  # use VERSION as the script version
  #
  _SCRIPT_VERSION="${VERSION}"

  if [ -n "${_REPO_VERSION}" ]; then # found a version
    if [ "${_REPO_VERSION}" != "${_SCRIPT_VERSION}" ]; then
      echo -e "${YELLOW}ASH version ${_SCRIPT_VERSION} is different from repository version ${_REPO_VERSION} ... consider upgrading${NC}"
    else
      # the ":" below allows the else/fi clause to remain, even if there is no operation listed
      : #   echo "repo version is ${_REPO_VERSION}, current version is ${_SCRIPT_VERSION}"
    fi
  fi
}

print_usage() {
  echo "NAME:"
  echo -e "\t$(basename $0)"
  echo "SYNOPSIS:"
  echo -e "\t$(basename $0) [OPTIONS] --source-dir /path/to/dir --output-dir /path/to/dir"
  echo "OPTIONS:"
  echo -e "\t-v | --version           Prints version number.\n"
  echo -e "\t-p | --preserve-report   Add timestamp to the final report file to avoid overriding it after multiple executions."
  echo -e "\t--source-dir             Path to the directory containing the code/files you wish to scan. Defaults to \$(pwd)"
  echo -e "\t--output-dir             Path to the directory that will contain the report of the scans. Defaults to \$(pwd)"
  echo -e "\t--ext | -extension       Force a file extension to scan. Defaults to identify files automatically."
  echo -e "\t--force                  Rebuild the Docker images of the scanning tools, to make sure software is up-to-date."
  echo -e "\t-q | --quiet             Don't print verbose text about the build process."
  echo -e "\t-c | --no-color          Don't print colorized output."
  echo -e "\t-s | --single-process    Run ash scanners serially rather than as separate, parallel sub-processes."
  echo -e "\t-o | --oci-runner        Use the specified OCI runner instead of docker to run the containerized tools."
  echo -e "\t-f | --finch             Use finch instead of docker to run the containerized tools."
  echo -e "\t                         WARNING: The '--finch|-f' option is deprecated and will be removed in a future"
  echo -e "\t                                  release. Please switch to using '--oci-runner finch' in scripts instead.\n"
  echo -e "For more information please visit https://github.com/awslabs/automated-security-helper"
}

# Find all files in the source directory. Method to list the files will be different if the source is a git repository or not
get_all_files() {

  # This should be
  # git config --global --add safe.directory ${_ASH_SOURCE_DIR} >/dev/null 2>&1
  src_files=()
  pushd . >/dev/null 2>&1
  # cd to the source directory as a starting point
  cd ${_ASH_SOURCE_DIR}
  # Check if the source directory is a git repository and clone it to the run directory
  if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]]; then
    echo "Source is a git repository. Using git ls-files to exclude files from scanning."
    src_files=$(git ls-files)
  else
    echo "Source is not a git repository. Using find to list all files instead."
    src_files=$(find "${_ASH_SOURCE_DIR}" \( -path '*/node_modules*' -prune -o -path '*/cdk.out*' -prune -o -path '*/.venv*' -prune -o -path '*/venv*' -prune \) -o -type f -name '*')
  fi;
  popd >/dev/null 2>&1

  all_files+=( "$src_files" )

}

# shellcheck disable=SC2120
# Find all possible extensions in the $_ASH_SOURCE_DIR directory
map_extensions_and_files() {
  # $_ASH_SOURCE_DIR comes from user input

  # Check the source folder and create a clone of the repository if ASH is running on single container mode
  if [[ "$_ASH_EXEC_MODE" = "local" ]]; then
    pushd . >/dev/null 2>&1
    cd ${_ASH_SOURCE_DIR}

    # On local mode, this configuration will only affect the current container
    git config --global --add safe.directory ${_ASH_SOURCE_DIR} >/dev/null 2>&1
    git config --global --add safe.directory ${_ASH_RUN_DIR} >/dev/null 2>&1
    if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]]; then
      git clone ${_ASH_SOURCE_DIR} ${_ASH_RUN_DIR}
      echo "Repository cloned successfully."
      _ASH_SOURCE_DIR=${_ASH_RUN_DIR}
    else
      echo "No git repository found in source folder."
    fi;
    popd >/dev/null 2>&1
  fi

  all_files=()
  # Retreive all files in the source directory. Files will be populated in the all_files array
  get_all_files

  # Since we're attempting to keep _ASH_SOURCE_DIR clean for new files to support read-only
  # mounting, include the OUTPUT_DIR as well.
  work_files="${all_files}\n$(find "${OUTPUT_DIR}/work" \( -path '*/node_modules*' -prune -o -path '*/cdk.out*' -prune -o -path '*/.venv*' -prune -o -path '*/venv*' -prune \) -o -type f -name '*')"
  all_files+=( "$work_files" )

  extensions_found=()
  files_found=()

  for file in $all_files; do
    file=$(echo "$file" | tr '[:upper:]' '[:lower:]') # lower case all the names

    extension="${file##*.}" # extract the extensions out of each file name.
    filename="${file##*/}" # extract the base filename plus extension

    # add only new extensions, skipping already-found ones.
    if [[ ! "${extensions_found[*]}" =~ ${extension} ]]; then
      extensions_found+=("$extension")
    fi

    # add only new files, skipping already-found ones.
    if [[ ! "${files_found[*]}" =~ ${filename} ]]; then
      files_found+=("$filename")
    fi
  done
}

# Try to locate specific extension type (ie yaml, py) from all the extensions found in $SOURCE_DIR
search_extension() {
  items_to_search=("$@") # passed as parameter to the function
  local item_found=0
  for item in "${items_to_search[@]}"; do
    if [[ "${extensions_found[*]}" =~ ${item} ]]; then
      local item_found=1
      echo "$item_found"
      break
    fi
  done
}

# Validate the input and set default values
# shellcheck disable=SC2120
validate_input() {
  if [[ -z ${PRESERVE_FILE} ]]; then AGGREGATED_RESULTS_REPORT_FILENAME="aggregated_results.txt"; else AGGREGATED_RESULTS_REPORT_FILENAME="aggregated_results-$(date +%s).txt"; fi
  if [[ -z ${FORCE_REBUILD} ]]; then FORCE_REBUILD="false"; fi
  if [[ -z ${SOURCE_DIR} ]]; then SOURCE_DIR="$(pwd)"; else SOURCE_DIR=$(cd "${SOURCE_DIR}"; pwd); fi # Transform any relative path to absolute
  if [[ -z ${OUTPUT_DIR} ]]; then
    OUTPUT_DIR="$(pwd)"
    # Create the OUTPUT_DIR/work recursively if it doesn't already exist.
    # -p flag is included will create missing parent dirs and skip if
    # the dir already exists.
    mkdir -p "${OUTPUT_DIR}/work"
  else
    # Create the OUTPUT_DIR/work recursively if it doesn't already exist.
    # -p flag is included will create missing parent dirs and skip if
    # the dir already exists.
    mkdir -p "${OUTPUT_DIR}/work"
    # The mkdir call needs to be done before absolute path resolution in case
    # OUTPUT_DIR itself doesn't exist yet.
    OUTPUT_DIR=$(cd "${OUTPUT_DIR}"; pwd) # Transform any relative path to absolute
  fi
  CFNRULES_LOCATION=$(cd "${CFNRULES_LOCATION}"; pwd) # Transform any relative path to absolute
  UTILS_LOCATION=$(cd "${UTILS_LOCATION}"; pwd) # Transform any relative path to absolute
}

# Execute the main scan logic for specific framework
# The first argument passed to this method is the dockerfile that executes the actual scan
# The remaining arguments (can be treated as *args in python) are the extensions we wish to scan for
run_security_check() {
  local DOCKERFILE_TO_EXECUTE="$1"
  local ITEMS_TO_SCAN=("${@:2}") # take all the array of commands which are the extensions to scan (slice 2nd to end)
  local RUNTIME_CONTAINER_NAME="scan-$RANDOM"

  local _RETURN_CODE=0

   # First lets verify this extension even exists in the $SOURCE_DIR directory
  echo -e "${LPURPLE}Items to scan for in ${GREEN}${DOCKERFILE_TO_EXECUTE}${LPURPLE} are: [ ${RED}""${ITEMS_TO_SCAN[*]}""${LPURPLE} ]${NC}"
  #echo "${EXTENSIONS_USED[@]}" $(search_extension "${ITEMS_TO_SCAN[@]}")

  if [[ " ${ITEMS_TO_SCAN[*]} " =~ " ${FORCED_EXT} " ]] || [[ $(search_extension "${ITEMS_TO_SCAN[@]}") == "1" ]]; then
    set +e # the scan will fail the command if it finds any finding. we don't want it to stop our script execution

    # If ASH is running in local execution mode (e.g. in a container already), call the
    # scripts directly instead of building and running the OCI containers.
    if [[ "$_ASH_EXEC_MODE" = "local" ]]; then
      if [ ${DOCKERFILE_TO_EXECUTE} == 'Dockerfile-git' ]; then
        SCANNER_SCRIPT="git-docker-execute.sh"
      elif [ ${DOCKERFILE_TO_EXECUTE} == 'Dockerfile-py' ]; then
        SCANNER_SCRIPT="py-docker-execute.sh"
      elif [ ${DOCKERFILE_TO_EXECUTE} == 'Dockerfile-yaml' ]; then
        SCANNER_SCRIPT="yaml-docker-execute.sh"
      elif [ ${DOCKERFILE_TO_EXECUTE} == 'Dockerfile-js' ]; then
        SCANNER_SCRIPT="js-docker-execute.sh"
      elif [ ${DOCKERFILE_TO_EXECUTE} == 'Dockerfile-grype' ]; then
        SCANNER_SCRIPT="grype-docker-execute.sh"
      elif [ ${DOCKERFILE_TO_EXECUTE} == 'Dockerfile-cdk' ]; then
        SCANNER_SCRIPT="cdk-docker-execute.sh"
      fi
      FULL_SCANNER_SCRIPT_PATH="${UTILS_LOCATION}/${SCANNER_SCRIPT}"
      echo -e "${LPURPLE}Running ${SCANNER_SCRIPT} ...${NC}"

      cd ${SOURCE_DIR}
      # Invoke the resolved scanner script
      bash -C ${FULL_SCANNER_SCRIPT_PATH}
    else
      echo -e "${LPURPLE}Found one or more of: [ ${RED}""${ITEMS_TO_SCAN[*]}""${LPURPLE} ] items in source dir,${NC} ${GREEN}running ${DOCKERFILE_TO_EXECUTE} ...${NC}"
      ${OCI_RUNNER} build -t "${RUNTIME_CONTAINER_NAME}" -f "${DOCKERFILE_LOCATION}"/"${DOCKERFILE_TO_EXECUTE}" ${DOCKER_EXTRA_ARGS} "${SOURCE_DIR}" > /dev/null
      set +e # the scan will fail the command if it finds any finding. we don't want it to stop our script execution
      ${OCI_RUNNER} run --name "${RUNTIME_CONTAINER_NAME}" -v "${CFNRULES_LOCATION}":/cfnrules:ro -v "${UTILS_LOCATION}":/utils:ro -v "${SOURCE_DIR}":/src:ro -v "${OUTPUT_DIR}":/out:rw --tmpfs /run/ash/src:rw,noexec,nosuid "${RUNTIME_CONTAINER_NAME}"
    fi
    #
    # capture the return code of the command invoked through docker
    #
    _RETURN_CODE=$?
    if [[ ${_RETURN_CODE} -ne 0 ]]; then

      #
      # Note the un-successful completion in RED text
      #
      echo -e "${RED}Dockerfile ${DOCKERFILE_TO_EXECUTE} returned ${_RETURN_CODE}${NC}"

      #
      # If the return code is negative, find the absolute value
      #
      if [[ ${_RETURN_CODE} -lt 0 ]]; then
        let _RETURN_CODE=${_RETURN_CODE}*-1
      fi

    else

      #
      # Note the successful completion in GREEN text
      #
      echo -e "${GREEN}Dockerfile ${DOCKERFILE_TO_EXECUTE} returned ${_RETURN_CODE}${NC}"
    fi

    set -e # from this point, any failure will halt the execution.
    if [[ "$_ASH_EXEC_MODE" != "local" ]]; then
      ${OCI_RUNNER} rm "${RUNTIME_CONTAINER_NAME}" >/dev/null # Let's keep it a clean environment
      ${OCI_RUNNER} rmi "${RUNTIME_CONTAINER_NAME}" >/dev/null # Let's keep it a clean environment
    fi
  else
    echo -e "${LPURPLE}Found ${CYAN}none${LPURPLE} of: [${RED}" "${ITEMS_TO_SCAN[@]}" "${LPURPLE} ] items in source dir, ${CYAN}skipping run${LPURPLE} of ${GREEN}${DOCKERFILE_TO_EXECUTE}${NC}"
    _RETURN_CODE=0
  fi

  #
  # This function was invoked from the main line processing of the ash script.
  # At that invocation (see below), the invocation is made with a trailing &
  # which spawns a sub-process and runs the function (really a copy of the parent process)
  # in the background.
  #
  # To propagate the return code from running the scan to the parent process, this function
  # needs to "exit ${_RETURN_CODE}" rather than setting a global shell variable.
  # Setting the global shell variable in a sub-process will have no effect on the value
  # in the parent process.
  #
  # Return the status by exiting the sub-process with the return code.
  #

  # echo -e "${LPURPLE}Just before exsiting $1 - RC = ${_RETURN_CODE}${NC}"
  if [ ${SINGLE_PROCESS} == 'false' ]; then
    exit ${_RETURN_CODE}
  else
    RETURN_CODE=${_RETURN_CODE}
  fi
}

# ---------------------------------------------------------------------
# Script processing starts here
# ---------------------------------------------------------------------

set -e
START_TIME=$(date +%s)
VERSION=("1.1.0-e-01Dec2023")
OCI_RUNNER="docker"

# Overrides default OCI Runner used by ASH
[ ! -z "$ASH_OCI_RUNNER" ] && OCI_RUNNER="$ASH_OCI_RUNNER"

# Look for extensions
GIT_EXTENSIONS=("git")
PY_EXTENSIONS=("py" "pyc" "ipynb")
INFRA_EXTENSIONS=("yaml" "yml" "tf" "json" "dockerfile")
CFN_EXTENSIONS=("yaml" "yml" "json" "template")
JS_EXTENSIONS=("js")
GRYPE_EXTENSIONS=("js" "py" "java" "go" "cs" "sh")

DOCKERFILE_LOCATION="$(dirname "${BASH_SOURCE[0]}")"/"helper_dockerfiles"
UTILS_LOCATION="$(dirname "${BASH_SOURCE[0]}")"/"utils"
CFNRULES_LOCATION="$(dirname "${BASH_SOURCE[0]}")"/"appsec_cfn_rules"

#
# for tracking the highest return code from running tools
#
HIGHEST_RC=0

#
# Initialize options
#
COLOR_OUTPUT="true"
FORCED_EXT="false"
SINGLE_PROCESS="false"

#
# Initialize color escape codes
#
LPURPLE='\033[1;35m'
LGRAY='\033[0;37m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#
# Process command-line arguments
#
while (("$#")); do
  case $1 in
  --source-dir)
    shift
    SOURCE_DIR="$1"
    ;;
  --output-dir)
    shift
    OUTPUT_DIR="$1"
    ;;
  --ext | -extension)
    shift
    FORCED_EXT="$1"
    ;;
  --force)
    DOCKER_EXTRA_ARGS="${DOCKER_EXTRA_ARGS} --no-cache"
    ;;
  --quiet | -q)
    DOCKER_EXTRA_ARGS="${DOCKER_EXTRA_ARGS} -q"
    QUIET_OUTPUT="-q"
    ;;
  --single-process | -s)
    SINGLE_PROCESS="true"
    ;;
  --preserve-report | -p)
    PRESERVE_FILE="true"
    ;;
  --no-color | -c)
    COLOR_OUTPUT="false"
    #
    # Set all the colorizing escape sequences to empty strings
    #
    LPURPLE=''
    LGRAY=''
    GREEN=''
    RED=''
    YELLOW=''
    CYAN=''
    NC='' # No Color
    ;;
  --finch | -f)
    OCI_RUNNER="finch"
    echo -e "${YELLOW}WARNING: The '--finch|-f' option is deprecated and will be removed in a future release. Please switch to using '--oci-runner finch|-o finch' in scripts instead${NC}"
    ;;
  --oci-runner | -o)
    shift
    OCI_RUNNER="$1"
    ;;
  --version | -v)
    #
    # Check the version before printing usage and exiting
    #
    version_check

    #
    # Print the version message
    #
    echo "ASH version $VERSION"
    EXITCODE=0
    exit $EXITCODE
    ;;
  --help | -h)
    #
    # Print the usage message
    #
    print_usage

    #
    # Check the version before printing usage and exiting
    #
    version_check

    EXITCODE=0
    exit $EXITCODE
    ;;
  *)
    echo -e "${RED}Unrecognized option: $1${NC}"
    print_usage
    exit 1
    ;;
  esac
  shift
done

#
# Attempt to check the current version of ASH against what is found in
# the appropriate Git repository.
#
version_check

validate_input


# Export _ASH_* env vars for called script access to remove hardcoded paths.
# We default to the env var value if it's already set externally.
# We do this _after_ validate_input is called so that these values are resolved first.
export _ASH_SOURCE_DIR="${_ASH_SOURCE_DIR:-${SOURCE_DIR}}"
export _ASH_OUTPUT_DIR="${_ASH_OUTPUT_DIR:-${OUTPUT_DIR}}"
export _ASH_ROOT_DIR="${_ASH_ROOT_DIR:-${ASH_ROOT_DIR}}"
export _ASH_UTILS_LOCATION="${_ASH_UTILS_LOCATION:-${UTILS_LOCATION}}"
export _ASH_CFNRULES_LOCATION="${_ASH_CFNRULES_LOCATION:-${CFNRULES_LOCATION}}"
export _ASH_RUN_DIR="${_ASH_RUN_DIR:-/run/scan/src}"

#
# Print out the current ASH version to start execution output
#
echo -e "\n${LPURPLE}ASH version ${GREEN}$VERSION${NC}\n"

# nosemgrep
IFS=$'\n' # Support directories with spaces, make the loop iterate over newline instead of space
# Extract all zip files to temp dir *within $OUTPUT_DIR* before scanning
for zipfile in $(find "${SOURCE_DIR}" -iname "*.zip");
do
  unzip ${QUIET_OUTPUT} -d "${OUTPUT_DIR}"/work/$(basename "${zipfile%.*}") $zipfile
done

unset IFS

declare -a all_files='' # Variable will be populated inside 'map_extensions_and_files' block

#
# Perform an initial scan of the files in the source directory tree to establish
# which scanners should be set up to be run.
#
map_extensions_and_files

TOTAL_FILES=$(echo "$all_files" | wc -l)

echo -e "ASH found ${TOTAL_FILES} file(s) in the source directory..."
if [ $TOTAL_FILES -gt 1000 ]; then
  echo -e "${RED}Depending on your machine this might take a while...${NC}"
  echo -e "${RED}Waiting 5 seconds in case you want to stop (use CTRL-C)... ${NC}"
  for i in {1..5}
  do
    echo -n "." && sleep 1
  done
  echo -e "${GREEN} Starting now!${NC}";
fi

#
# set up some variables for use further down
#
typeset -a JOBS JOBS_RC
typeset -i i j

#
# Collect all the jobs to be run into a list that can be looped through
#
# JOB_NAMES=("Dockerfile-git" "Dockerfile-py" "Dockerfile-yaml" "Dockerfile-js" "Dockerfile-grype" "Dockerfile-cdk")
JOB_NAMES=("Dockerfile-cdk" "Dockerfile-yaml" "Dockerfile-git" "Dockerfile-py" "Dockerfile-js" "Dockerfile-grype")

#
# Loop through the checks to start, grabbing the right extensions to add in
# and start the check as a background process
#
i=0
for jobName in "${JOB_NAMES[@]}"; do
  if [ ${jobName} == 'Dockerfile-git' ]; then
    JOB_EXTENSIONS=(${GIT_EXTENSIONS[@]})
  elif [ ${jobName} == 'Dockerfile-py' ]; then
    JOB_EXTENSIONS=(${PY_EXTENSIONS[@]})
  elif [ ${jobName} == 'Dockerfile-yaml' ]; then
    JOB_EXTENSIONS=(${INFRA_EXTENSIONS[@]})
  elif [ ${jobName} == 'Dockerfile-js' ]; then
    JOB_EXTENSIONS=(${JS_EXTENSIONS[@]})
  elif [ ${jobName} == 'Dockerfile-grype' ]; then
    JOB_EXTENSIONS=(${GRYPE_EXTENSIONS[@]})
  elif [ ${jobName} == 'Dockerfile-cdk' ]; then
    JOB_EXTENSIONS=(${CFN_EXTENSIONS[@]})
  fi

  # echo -e "${GREEN}run_security_check "${jobName}" "${JOB_EXTENSIONS[@]}" &${NC}"

  if [ ${SINGLE_PROCESS} == 'false' ]; then
    run_security_check "${jobName}" "${JOB_EXTENSIONS[@]}" &
    JOBS[${i}]=$! # Note down the process ID of the child process to use later
  else
    RETURN_CODE=0
    run_security_check "${jobName}" "${JOB_EXTENSIONS[@]}"
    JOBS_RC[${i}]=${RETURN_CODE}
    echo -e "${GREEN}${JOB_NAMES[${i}]}${CYAN} finished with return code ${JOBS_RC[${i}]}${NC}"
  fi

  i=${i}+1
done

if [ ${SINGLE_PROCESS} == 'false' ]; then
  #
  # Now that the jobs are started, wait for each job to finish, capturing the
  # return code from the background process.  The return code is set by the
  # "exit ${_RETURN_CODE}" at the end of the run_security_check() function.
  #
  i=0
  for pid in "${JOBS[@]}"; do
    echo -e "${CYAN}waiting on ${GREEN}${JOB_NAMES[${i}]}${CYAN} to finish ...${NC}"
    WAIT_ERR=0
    j=5 # number of times to re-try a failed wait
    while wait ${pid} || WAIT_ERR=$?; do
      #
      # This check allows for the "wait" to fail for some reason, if so
      # it will return code 127, which we know will not be returned by the
      # run_security_check() sub-process.
      #
      # So, loop on a wait until the wait succeeds for the job we're waiting on.
      #
      if [ ${WAIT_ERR} -ne 127 ]; then
        JOBS_RC[${i}]=${WAIT_ERR}
        break
      else
        j=${j}-1
        if [ ${j} -gt 0 ]; then
          echo -e "${RED}wait had and error, ${j} retries left, re-waiting ...${NC}"
        else
          JOBS_RC[${i}]=${WAIT_ERR}
          echo -e "${RED}wait had and error, ${j} retries left, skipping wait for ${GREEN}${JOB_NAMES[${i}]}${RED} ...${NC}"
          break
        fi
      fi
    done
    if [ ${JOBS_RC[${i}]} -ne 127 ]; then
      echo -e "${GREEN}${JOB_NAMES[${i}]}${CYAN} finished with return code ${JOBS_RC[${i}]}${NC}"
    else
      echo -e "${GREEN}${JOB_NAMES[${i}]}${RED} wait for completion failed${NC}"
    fi
    i=$i+1
  done
fi

#
# Now that all the jobs are complete, display a final report of
# the return code status for each job that was run.
#
i=0
echo -e "${CYAN}Jobs return code report:${NC}"
for pid in "${JOBS[@]}"; do
  REPORT_COLOR=${GREEN}
  if [ ${JOBS_RC[${i}]} -ne 0 ]; then
    REPORT_COLOR=${RED}
    if [ ${JOBS_RC[${i}]} -gt ${HIGHEST_RC} ]; then
      HIGHEST_RC=${JOBS_RC[${i}]}
    fi
  else
    REPORT_COLOR=${GREEN}
  fi
  printf "${REPORT_COLOR}%32s${CYAN} : %3d${NC}\\n" "${JOB_NAMES[${i}]}" "${JOBS_RC[${i}]}"
  i=$i+1
done

# Cleanup any previous file
rm -f "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"

# if an extension was not found, no report file will be in place, so skip the final report
if [[ $(find "${OUTPUT_DIR}/work" -iname "*_report_result.txt" | wc -l | awk '{print $1}') -gt 0 ]];
then
  # Aggregate the results output files
  for result in "${OUTPUT_DIR}"/work/*_report_result.txt;
  do
    echo "#############################################" >> "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"
    echo "Start of  ${result}" >> "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"
    echo "#############################################" >> "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"
    cat "${result}" >> "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"
    echo "#############################################" >> "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"
    echo "End of  ${result}" >> "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"
    echo -e "#############################################\n\n" >> "${OUTPUT_DIR}"/"${AGGREGATED_RESULTS_REPORT_FILENAME}"
  done

  # Cleanup work directory containing all temp files
  rm -rf "${OUTPUT_DIR}"/work

  echo -e "${GREEN}\nYour final report can be found here:${NC} ${OUTPUT_DIR}/${AGGREGATED_RESULTS_REPORT_FILENAME}"
else
  echo -e "${GREEN}No extensions were found, nothing to scan at the moment.${NC}"
fi

END_TIME=$(date +%s)
TOTAL_EXECUTION=$((END_TIME-START_TIME))

echo -e "${CYAN}ASH execution completed in ${TOTAL_EXECUTION} seconds.${NC}"

RCCOLOR=${GREEN}
if [[ $HIGHEST_RC -gt 0 ]]; then
  RCCOLOR=${RED}
fi
echo -e "${RCCOLOR}Highest return code is $HIGHEST_RC${NC}"

exit $HIGHEST_RC
