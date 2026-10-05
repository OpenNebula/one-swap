#!/usr/bin/env bash

set -uo pipefail

CONFIG_DIR="${1:-./configs}"
ONESWAP="${ONESWAP:-oneswap}"

LOG_ROOT="${LOG_ROOT:-./oneswap-test-results}"
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${LOG_ROOT}/${RUN_ID}"

MASTER_LOG="${RUN_DIR}/summary.log"
MASTER_CSV="${RUN_DIR}/timings.csv"

mkdir -p "${RUN_DIR}"

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

meta()
{
    local file="$1"
    local key="$2"

    sed -n \
        "s/^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" \
        "${file}" | head -n1 | xargs
}

source_environment()
{
    # Source inventory comes from vCenter; ESXi settings select a transfer path.
    # Match the VM helper's YAML loading and top-level key normalization.
    ruby -ryaml -e '
        config = YAML.safe_load(File.read(ARGV.fetch(0)),
                                permitted_classes: [Symbol], aliases: true)
        abort "Config must be a YAML mapping" unless config.is_a?(Hash)
        config = config.transform_keys { |key| key.to_s.sub(/^:/, "").to_sym }
        abort "Missing config setting: vcenter" if config[:vcenter].to_s.strip.empty?
        puts "vcenter"
    ' "$1"
}

format_duration()
{

    local total="$1"

    printf '%02d:%02d:%02d' \
        $((total / 3600)) \
        $(((total % 3600) / 60)) \
        $((total % 60))
}

sanitize()
{
    echo "$1" |
        tr '[:upper:]' '[:lower:]' |
        tr ' /+' '---' |
        tr -cd '[:alnum:]_.-'
}

find_template_ids()
{
    local vm="$1"

    local objects
    objects="$(onetemplate list --no-header)" || return 1

    printf '%s\n' "${objects}" |
        grep -F -- "${vm}" |
        awk '{print $1}' |
        sort -n -u || true
}

find_image_ids()
{
    local vm="$1"

    local objects
    objects="$(oneimage list --no-header)" || return 1

    printf '%s\n' "${objects}" |
        grep -F -- "${vm}" |
        awk '{print $1}' |
        sort -n -u || true
}

wait_template_deleted()
{
    local id="$1"
    local timeout=60
    local start

    start="$(date +%s)"

    while onetemplate show "${id}" >/dev/null 2>&1; do
        if (( $(date +%s) - start >= timeout )); then
            echo "ERROR: Template ${id} was not deleted within ${timeout}s"
            return 1
        fi

        sleep 2
    done
}

wait_image_deleted()
{
    local id="$1"
    local timeout=120
    local start

    start="$(date +%s)"

    while oneimage show "${id}" >/dev/null 2>&1; do
        if (( $(date +%s) - start >= timeout )); then
            echo "ERROR: Image ${id} was not deleted within ${timeout}s"
            return 1
        fi

        sleep 2
    done
}

prepare_delta_source()
{
    local vm="$1"
    local config="$2"
    local log="$3"

    {
        echo
        echo "----- Preparing Delta source ${vm} -----"

        ruby ./oneswap_vm_helper.rb snapshots \
            "${vm}" \
            --config-file "${config}"
        local snapshot_rc=$?
        if (( snapshot_rc != 0 )); then
            if (( snapshot_rc == 2 )); then
                echo "Delta migration requires a source VM without existing snapshots."
            fi
            echo "Test aborted before migration."
            return "${snapshot_rc}"
        fi

        ruby ./oneswap_vm_helper.rb power-on \
            "${vm}" \
            --config-file "${config}" || return 1

        ruby ./oneswap_vm_helper.rb wait-tools-ready \
            "${vm}" \
            --config-file "${config}" || return 1

        echo "Delta source preparation completed"
        echo "-----------------------------------------"
    } 2>&1 | tee -a "${log}"

    return "${PIPESTATUS[0]}"
}

assert_no_existing_objects()
{
    local vm="$1"
    local log="$2"

    local templates
    local images

    templates="$(find_template_ids "${vm}")" &&
        images="$(find_image_ids "${vm}")" || {
            echo "ERROR: Cannot verify existing OpenNebula objects for ${vm}" |
                tee -a "${log}"
            return 1
        }

    if [[ -n "${templates}" || -n "${images}" ]]; then
        {
            echo
            echo "ERROR: OpenNebula objects already exist for ${vm}."
            echo "Refusing to start the test because cleanup could delete pre-existing objects."

            if [[ -n "${templates}" ]]; then
                echo
                echo "Existing templates:"
                onetemplate list --no-header | grep -F -- "${vm}" || true
            fi

            if [[ -n "${images}" ]]; then
                echo
                echo "Existing images:"
                oneimage list --no-header | grep -F -- "${vm}" || true
            fi
        } | tee -a "${log}"

        return 1
    fi

    echo "Preflight OK: no existing OpenNebula objects for ${vm}" |
        tee -a "${log}"
}

cleanup_objects()
{
    local vm="$1"
    local cleanup_log="$2"

    local template_ids
    local image_ids
    local id

    {
        echo
        echo "----- OpenNebula cleanup for ${vm} -----"

        template_ids="$(find_template_ids "${vm}")" || return 1

        if [[ -n "${template_ids}" ]]; then
            echo "Templates matching ${vm}:"
            onetemplate list --no-header |
                grep -F -- "${vm}" || true

            # Templates first, because they can reference images.
            while read -r id; do
                [[ -z "${id}" ]] && continue

		echo "Deleting template ${id}"
		onetemplate delete "${id}" || return 1
		wait_template_deleted "${id}" || return 1
		echo "Template ${id} deleted successfully"
            done <<< "${template_ids}"
        else
            echo "No templates matching ${vm}"
        fi

        image_ids="$(find_image_ids "${vm}")" || return 1

        if [[ -n "${image_ids}" ]]; then
            echo "Images matching ${vm}:"
            oneimage list --no-header |
                grep -F -- "${vm}" || true

            while read -r id; do
                [[ -z "${id}" ]] && continue

                echo "Deleting image ${id}"
                oneimage delete "${id}" || return 1
                wait_image_deleted "${id}" || return 1
                echo "Image ${id} deleted successfully"
            done <<< "${image_ids}"
        else
            echo "No images matching ${vm}"
        fi

        echo "Cleanup completed for ${vm}"
        echo "----------------------------------------"
    } 2>&1 | tee -a "${cleanup_log}"

    return "${PIPESTATUS[0]}"
}

validate_delta_source()
{
    local vm="$1"
    local config="$2"
    local log="$3"
    local state

    {
        echo
        echo "----- Validating Delta source ${vm} -----"

        state="$(
            ruby ./oneswap_vm_helper.rb state \
                "${vm}" \
                --config-file "${config}" 2>/dev/null
        )" || return 1

        echo "${state}"

        if [[ "${state}" != *": poweredOff" ]]; then
            echo "ERROR: Source VM is expected to be poweredOff after Delta"
            return 1
        fi

        ruby ./oneswap_vm_helper.rb snapshots \
            "${vm}" \
            --config-file "${config}" || return 1

        echo "Delta source validation completed"
        echo "----------------------------------------"
    } 2>&1 | tee -a "${log}"

    return "${PIPESTATUS[0]}"
}

# ----------------------------------------------------------------------
# Initial validation
# ----------------------------------------------------------------------

if [[ ! -d "${CONFIG_DIR}" ]]; then
    echo "ERROR: Config directory does not exist: ${CONFIG_DIR}"
    exit 1
fi

if ! command -v "${ONESWAP}" >/dev/null 2>&1; then
    echo "ERROR: OneSwap executable not found: ${ONESWAP}"
    exit 1
fi

for cmd in onetemplate oneimage; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: ${cmd}"
        exit 1
    fi
done

mapfile -t CONFIGS < <(
    find "${CONFIG_DIR}" -maxdepth 1 -type f \
        \( -name '*.yaml' -o -name '*.yml' \) |
        sort
)

if (( ${#CONFIGS[@]} == 0 )); then
    echo "ERROR: No YAML configs found in ${CONFIG_DIR}"
    exit 1
fi

# ----------------------------------------------------------------------
# Summary files
# ----------------------------------------------------------------------

cat > "${MASTER_CSV}" <<'EOF'
test_name,vm,environment,migration_method,transfer_method,target_storage,config,status,exit_code,duration_seconds,duration,downtime_seconds,downtime,start_time,end_time,log
EOF

{
    echo "OneSwap migration test run"
    echo "Run ID:       ${RUN_ID}"
    echo "Started:      $(date --iso-8601=seconds)"
    echo "Config dir:   ${CONFIG_DIR}"
    echo "OneSwap:      ${ONESWAP}"
    echo "Tests found:  ${#CONFIGS[@]}"
    echo
} | tee "${MASTER_LOG}"

# ----------------------------------------------------------------------
# Run matrix
# ----------------------------------------------------------------------

TEST_NUMBER=0

for config in "${CONFIGS[@]}"; do

    ((TEST_NUMBER++))

    VM_NAME="$(meta "${config}" TEST_VM)"
    ENV_NAME="$(meta "${config}" TEST_ENV)"
    METHOD="$(meta "${config}" TEST_METHOD)"
    TRANSFER="$(meta "${config}" TEST_TRANSFER)"
    STORAGE="$(meta "${config}" TEST_STORAGE)"

    if [[ -z "${VM_NAME}" ||
          -z "${METHOD}" ||
          -z "${TRANSFER}" ||
          -z "${STORAGE}" ]]; then

        echo "ERROR: Missing TEST_* metadata in ${config}" |
            tee -a "${MASTER_LOG}"

        exit 1
    fi

    if ! SOURCE_ENV="$(source_environment "${config}" 2>>"${MASTER_LOG}")"; then
        echo "ERROR: Cannot derive source environment from ${config}" |
            tee -a "${MASTER_LOG}"
        exit 1
    fi

    # TEST_ENV is a display label only; source behavior uses VM_NAME/config.
    ENV_NAME="${ENV_NAME:-${SOURCE_ENV}}"

    TEST_NAME="$(
        sanitize "${VM_NAME}_${ENV_NAME}_${METHOD}_${TRANSFER}_${STORAGE}"
    )"

    RUN_LOG="${RUN_DIR}/${TEST_NUMBER}_${TEST_NAME}.log"

    if ! assert_no_existing_objects "${VM_NAME}" "${RUN_LOG}"; then
        exit 2
    fi

    if [[ "${METHOD}" == "delta" ]]; then
      if ! prepare_delta_source "${VM_NAME}" "${config}" "${RUN_LOG}"; then
        echo "PREPARATION_FAILED: ${TEST_NAME}: Failed to prepare Delta source ${VM_NAME}; migration was not started." |
            tee -a "${MASTER_LOG}" "${RUN_LOG}"
        # No migration duration/start time exists for a preparation failure.
        printf '%s,%s,%s,%s,%s,%s,%s,PREPARATION_FAILED,2,,,,,,%s,%s\n' \
            "${TEST_NAME}" "${VM_NAME}" "${ENV_NAME}" "${METHOD}" \
            "${TRANSFER}" "${STORAGE}" "$(basename "${config}")" \
            "$(date --iso-8601=seconds)" "${RUN_LOG}" >> "${MASTER_CSV}"
        exit 2
      fi
    fi

    # Delta downtime monitor.
    DOWNTIME_FILE=""
    DOWNTIME_MONITOR_PID=""
    DOWNTIME_SECONDS=""
    DOWNTIME_HMS=""

    if [[ "${METHOD}" == "delta" ]]; then
      DOWNTIME_FILE="${RUN_DIR}/${TEST_NUMBER}_${TEST_NAME}.downtime_start"
      rm -f "${DOWNTIME_FILE}"

      ruby ./oneswap_vm_helper.rb wait-powered-off \
        "${VM_NAME}" \
        --timestamp-file "${DOWNTIME_FILE}" \
        --config-file "${config}" \
        >> "${RUN_LOG}" 2>&1 &

      DOWNTIME_MONITOR_PID=$!
    fi

    {
        echo
        echo "============================================================"
        echo "Test ${TEST_NUMBER}/${#CONFIGS[@]}"
        echo "Test name:       ${TEST_NAME}"
        echo "VM:              ${VM_NAME}"
        echo "Environment:     ${ENV_NAME}"
        echo "Migration:       ${METHOD}"
        echo "Transfer:        ${TRANSFER}"
        echo "Target storage:  ${STORAGE}"
        echo "Config:          ${config}"
        echo "Prepared:        $(date --iso-8601=seconds)"
        echo "Log:             ${RUN_LOG}"
        echo "============================================================"
        echo
    } | tee -a "${MASTER_LOG}" "${RUN_LOG}"

    # --------------------------------------------------------------
    # Run OneSwap
    # --------------------------------------------------------------

    END_TIME_FILE="${RUN_DIR}/${TEST_NUMBER}_${TEST_NAME}.migration_end"

    if [[ "${METHOD}" == "delta" ]]; then
      START_TIME="$(date --iso-8601=seconds)"
      START_EPOCH="$(date +%s)"
      {
          "${ONESWAP}" convert "${VM_NAME}" \
             --delta \
             --config-file "${config}"
          COMMAND_RC=$?
          date +%s > "${END_TIME_FILE}"
          exit "${COMMAND_RC}"
      } 2>&1 | tee -a "${RUN_LOG}"

      RC="${PIPESTATUS[0]}"
    else
      START_TIME="$(date --iso-8601=seconds)"
      START_EPOCH="$(date +%s)"
      {
          "${ONESWAP}" convert "${VM_NAME}" \
             --config-file "${config}"
          COMMAND_RC=$?
          date +%s > "${END_TIME_FILE}"
          exit "${COMMAND_RC}"
      } 2>&1 | tee -a "${RUN_LOG}"

      RC="${PIPESTATUS[0]}"
    fi

    # Stop migration timer before post-validation.
    END_EPOCH="$(cat "${END_TIME_FILE}")"
    END_TIME="$(date --date="@${END_EPOCH}" --iso-8601=seconds)"

    DURATION=$((END_EPOCH - START_EPOCH))
    DURATION_HMS="$(format_duration "${DURATION}")"

    # --------------------------------------------------------------
    # Delta downtime result
    # --------------------------------------------------------------

    if [[ "${METHOD}" == "delta" ]]; then
        if kill -0 "${DOWNTIME_MONITOR_PID}" 2>/dev/null; then
            kill "${DOWNTIME_MONITOR_PID}" 2>/dev/null || true
            wait "${DOWNTIME_MONITOR_PID}" 2>/dev/null || true
        else
            wait "${DOWNTIME_MONITOR_PID}" 2>/dev/null || true
        fi

        if [[ -s "${DOWNTIME_FILE}" ]]; then
            DOWNTIME_START="$(cat "${DOWNTIME_FILE}")"

            if [[ "${DOWNTIME_START}" =~ ^[0-9]+$ ]] &&
               (( DOWNTIME_START <= END_EPOCH )); then

                DOWNTIME_SECONDS=$((END_EPOCH - DOWNTIME_START))
                DOWNTIME_HMS="$(format_duration "${DOWNTIME_SECONDS}")"
            else
                echo "ERROR: Invalid Delta downtime timestamp: ${DOWNTIME_START}" |
                    tee -a "${MASTER_LOG}" "${RUN_LOG}"

                (( RC == 0 )) && RC=5
            fi
        else
            echo "ERROR: Delta downtime start was not captured." |
                tee -a "${MASTER_LOG}" "${RUN_LOG}"

            (( RC == 0 )) && RC=5
        fi
    fi

    # --------------------------------------------------------------
    # Delta post-validation
    # --------------------------------------------------------------

    if (( RC == 0 )) && [[ "${METHOD}" == "delta" ]]; then
        if ! validate_delta_source "${VM_NAME}" "${config}" "${RUN_LOG}"; then
            {
                echo
                echo "ERROR: Delta conversion completed, but source VM validation failed."
            } | tee -a "${MASTER_LOG}" "${RUN_LOG}"

            RC=4
        fi
    fi

    # Inspect snapshots even when conversion or timing failed; never remove them.
    if (( RC != 0 )) && [[ "${METHOD}" == "delta" ]]; then
        if ! ruby ./oneswap_vm_helper.rb snapshots "${VM_NAME}" \
            --config-file "${config}" >> "${RUN_LOG}" 2>&1; then
            echo "ERROR: Delta snapshot check failed; stopping for manual inspection." |
                tee -a "${MASTER_LOG}" "${RUN_LOG}"
        fi
    fi

    # RC can change during downtime/post validation.
    if (( RC == 0 )); then
        STATUS="PASS"
    else
        STATUS="FAIL"
    fi

    {
        echo
        echo "Conversion result:"
        echo "  Status:   ${STATUS}"
        echo "  Exit:     ${RC}"
        echo "  Duration: ${DURATION_HMS} (${DURATION}s)"

        if [[ "${METHOD}" == "delta" && -n "${DOWNTIME_SECONDS}" ]]; then
            echo "  Downtime: ${DOWNTIME_HMS} (${DOWNTIME_SECONDS}s)"
        fi

        echo "  Ended:    ${END_TIME}"
        echo
    } | tee -a "${RUN_LOG}" "${MASTER_LOG}"

    # --------------------------------------------------------------
    # Cleanup created OpenNebula objects before next test
    # --------------------------------------------------------------

    if ! cleanup_objects "${VM_NAME}" "${RUN_LOG}"; then
        {
            echo
            echo "FATAL: Cleanup failed after ${TEST_NAME}."
            echo "Stopping test sequence to avoid contaminating following runs."
        } | tee -a "${MASTER_LOG}" "${RUN_LOG}"

        exit 2
    fi

    # --------------------------------------------------------------
    # Master timing/result CSV
    # --------------------------------------------------------------

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%s,%s,%s,%s,%s,%s\n' \
        "${TEST_NAME}" \
        "${VM_NAME}" \
        "${ENV_NAME}" \
        "${METHOD}" \
        "${TRANSFER}" \
        "${STORAGE}" \
        "$(basename "${config}")" \
        "${STATUS}" \
        "${RC}" \
        "${DURATION}" \
        "${DURATION_HMS}" \
        "${DOWNTIME_SECONDS}" \
        "${DOWNTIME_HMS}" \
        "${START_TIME}" \
        "${END_TIME}" \
        "${RUN_LOG}" \
        >> "${MASTER_CSV}"

    # --------------------------------------------------------------
    # Stop matrix after a failed conversion
    # --------------------------------------------------------------

    if (( RC != 0 )); then
        {
            echo
            echo "FATAL: Conversion failed for ${TEST_NAME}."
            echo "Stopping matrix to avoid running the next test with possible leftover conversion data."
        } | tee -a "${MASTER_LOG}" "${RUN_LOG}"

        exit 3
    fi

    echo "Completed ${TEST_NUMBER}/${#CONFIGS[@]}: ${TEST_NAME}" |
        tee -a "${MASTER_LOG}"
done

# ----------------------------------------------------------------------
# Final summary
# ----------------------------------------------------------------------

{
    echo
    echo "============================================================"
    echo "All tests completed"
    echo "Finished: $(date --iso-8601=seconds)"
    echo "Logs:     ${RUN_DIR}"
    echo "Summary:  ${MASTER_LOG}"
    echo "Timings:  ${MASTER_CSV}"
    echo "============================================================"
} | tee -a "${MASTER_LOG}"
