#!/usr/bin/env bash

set -u
set -o pipefail

# =============================================================================
# ELASTICSEARCH GENERIC REINDEX
#
# Usage:
#
#   ./reindex_generic.sh ./reindex_config.sh
#
# =============================================================================


# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/reindex_config.sh"

if [[ $# -ge 1 ]]; then
    CONFIG_FILE="$1"
else
    CONFIG_FILE="$DEFAULT_CONFIG"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"


# =============================================================================
# VALIDATE CONFIGURATION
# =============================================================================

REQUIRED_VARS=(
    ES_URL
    SOURCE_PREFIX
    TARGET_PREFIX
    INDEX_PATTERN
    SOURCE_PATTERN
    TARGET_PATTERN
    EXCLUDE_PATTERN
    DRY_RUN
    MAX_PARALLEL
    POLL_INTERVAL
    REQUESTS_PER_SECOND
    SKIP_EXISTING
    VERIFY_EXISTING_TARGET
    REINDEX_EXISTING_ON_COUNT_MISMATCH
    BLOCK_SOURCE_WRITES
    PRESERVE_ORIGINATION_DATE
    DELETE_SOURCE_AFTER_SUCCESS
    ALLOW_SOURCE_DELETE
    PREFLIGHT_CHECK_MAPPINGS
    PREFLIGHT_CHECK_TEMPLATES
    FAIL_ON_TARGET_ILM
    LOG_DIR
    LOG_FILE
    PREFLIGHT_FILE
    RESULT_FILE
)

for VAR in "${REQUIRED_VARS[@]}"; do

    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: variable not configured: ${VAR}" >&2
        exit 1
    fi

done


# =============================================================================
# LOG DIRECTORY
# =============================================================================

mkdir -p "${LOG_DIR}"


# =============================================================================
# LOG FUNCTIONS
# =============================================================================

log() {

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" |
        tee -a "${LOG_FILE}"
}


error() {

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" |
        tee -a "${LOG_FILE}" >&2
}


# =============================================================================
# DEPENDENCIES
# =============================================================================

command -v curl >/dev/null 2>&1 || {

    error "curl not found"
    exit 1

}


command -v jq >/dev/null 2>&1 || {

    error "jq not found"
    exit 1

}


# =============================================================================
# CURL OPTIONS
# =============================================================================

CURL_OPTS=(
    --silent
    --show-error
    --fail-with-body
    --globoff
)


if [[ -n "${CA_CERT:-}" ]]; then

    CURL_OPTS+=(
        --cacert "${CA_CERT}"
    )

elif [[ "${INSECURE_TLS:-false}" == "true" ]]; then

    CURL_OPTS+=(
        -k
    )

fi


if [[ -n "${ES_API_KEY:-}" ]]; then

    CURL_OPTS+=(
        -H "Authorization: ApiKey ${ES_API_KEY}"
    )

elif [[ -n "${ES_USER:-}" ]]; then

    CURL_OPTS+=(
        -u "${ES_USER}:${ES_PASS}"
    )

fi


# =============================================================================
# ELASTICSEARCH API FUNCTIONS
# =============================================================================

es_get() {

    local endpoint="$1"

    curl "${CURL_OPTS[@]}" \
        -H "Content-Type: application/json" \
        "${ES_URL}${endpoint}"
}


es_post() {

    local endpoint="$1"
    local body="$2"

    curl "${CURL_OPTS[@]}" \
        -X POST \
        -H "Content-Type: application/json" \
        "${ES_URL}${endpoint}" \
        -d "${body}"
}


es_put() {

    local endpoint="$1"
    local body="$2"

    curl "${CURL_OPTS[@]}" \
        -X PUT \
        -H "Content-Type: application/json" \
        "${ES_URL}${endpoint}" \
        -d "${body}"
}


es_delete() {

    local endpoint="$1"

    curl "${CURL_OPTS[@]}" \
        -X DELETE \
        -H "Content-Type: application/json" \
        "${ES_URL}${endpoint}"
}


# =============================================================================
# HTTP STATUS CHECK
#
# IMPORTANT:
# --fail-with-body is intentionally NOT used here.
#
# 200 = target exists
# 404 = target does not exist
# other = real HTTP error
# =============================================================================

es_get_status() {

    local endpoint="$1"

    local CURL_STATUS_OPTS=(
        --silent
        --show-error
        --output /dev/null
        --write-out '%{http_code}'
        --globoff
    )


    if [[ -n "${CA_CERT:-}" ]]; then

        CURL_STATUS_OPTS+=(
            --cacert "${CA_CERT}"
        )

    elif [[ "${INSECURE_TLS:-false}" == "true" ]]; then

        CURL_STATUS_OPTS+=(
            -k
        )

    fi


    if [[ -n "${ES_API_KEY:-}" ]]; then

        CURL_STATUS_OPTS+=(
            -H "Authorization: ApiKey ${ES_API_KEY}"
        )

    elif [[ -n "${ES_USER:-}" ]]; then

        CURL_STATUS_OPTS+=(
            -u "${ES_USER}:${ES_PASS}"
        )

    fi


    curl "${CURL_STATUS_OPTS[@]}" \
        "${ES_URL}${endpoint}"
}


# =============================================================================
# CSV HELPERS
# =============================================================================

csv_escape() {

    local value="${1:-}"

    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//\"/\"\"}"

    printf '"%s"' "${value}"
}


write_preflight() {

    local source="$1"
    local target="$2"
    local source_count="$3"
    local target_exists="$4"
    local mapping_ok="$5"
    local template_ok="$6"
    local lifecycle="$7"
    local status="$8"
    local message="$9"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$(date '+%Y-%m-%d %H:%M:%S')")" \
        "$(csv_escape "${source}")" \
        "$(csv_escape "${target}")" \
        "$(csv_escape "${source_count}")" \
        "$(csv_escape "${target_exists}")" \
        "$(csv_escape "${mapping_ok}")" \
        "$(csv_escape "${template_ok}")" \
        "$(csv_escape "${lifecycle}")" \
        "$(csv_escape "${status}")" \
        "$(csv_escape "${message}")" \
        >> "${PREFLIGHT_FILE}"
}


write_result() {

    local source="$1"
    local target="$2"
    local source_count="$3"
    local target_count="$4"
    local created_version="$5"
    local status="$6"
    local task_id="$7"
    local error_msg="$8"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_escape "$(date '+%Y-%m-%d %H:%M:%S')")" \
        "$(csv_escape "${source}")" \
        "$(csv_escape "${target}")" \
        "$(csv_escape "${source_count}")" \
        "$(csv_escape "${target_count}")" \
        "$(csv_escape "${created_version}")" \
        "$(csv_escape "${status}")" \
        "$(csv_escape "${task_id}")" \
        "$(csv_escape "${error_msg}")" \
        >> "${RESULT_FILE}"
}


if [[ ! -f "${PREFLIGHT_FILE}" ]]; then

    echo "timestamp,source_index,target_index,source_count,target_exists,mapping_ok,template_ok,template_lifecycle,status,message" \
        > "${PREFLIGHT_FILE}"

fi


if [[ ! -f "${RESULT_FILE}" ]]; then

    echo "timestamp,source_index,target_index,source_count,target_count,created_version,status,task_id,error" \
        > "${RESULT_FILE}"

fi


# =============================================================================
# TARGET NAME
# =============================================================================

build_target_name() {

    local source_index="$1"

    local remainder="${source_index#${SOURCE_PREFIX}-}"

    printf '%s-%s' \
        "${TARGET_PREFIX}" \
        "${remainder}"
}


# =============================================================================
# SOURCE CREATION DATE
# =============================================================================

get_source_creation_date() {

    local source_index="$1"

    local settings_json

    settings_json="$(
        es_get \
            "/${source_index}/_settings?flat_settings=true&include_defaults=false" \
            2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then
        return 1
    fi


    echo "${settings_json}" |
        jq -r '.[].settings["index.creation_date"] // empty'
}


# =============================================================================
# BLOCK SOURCE WRITES
# =============================================================================

block_source_writes() {

    local source_index="$1"

    local response

    log "[${source_index}] setting index.blocks.write=true"


    response="$(
        es_put \
            "/${source_index}/_settings" \
            '{"index.blocks.write":true}' \
            2>&1
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] impossibile impostare source read-only"

        echo "${response}" |
            tee -a "${LOG_FILE}"

        return 1

    fi


    if ! echo "${response}" |
        jq -e '.acknowledged == true' >/dev/null 2>&1; then

        error "[${source_index}] blocco source non confermato"

        echo "${response}" |
            tee -a "${LOG_FILE}"

        return 1
    fi


    log "[${source_index}] source read-only"

    return 0
}


# =============================================================================
# VERIFY EXISTING TARGET
#
# return:
#   0 = counts equal
#   1 = API error
#   2 = count mismatch
# =============================================================================

verify_existing_target() {

    local source_index="$1"
    local target_index="$2"

    local source_json
    local target_json

    local source_count
    local target_count


    source_json="$(
        es_get "/${source_index}/_count" 2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then
        return 1
    fi


    target_json="$(
        es_get "/${target_index}/_count" 2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then
        return 1
    fi


    source_count="$(
        echo "${source_json}" |
        jq -r '.count // 0'
    )"


    target_count="$(
        echo "${target_json}" |
        jq -r '.count // 0'
    )"


    log "[${source_index}] existing target source=${source_count} target=${target_count}"


    if [[ "${source_count}" == "${target_count}" ]]; then
        return 0
    fi


    return 2
}


# =============================================================================
# DELETE TARGET
# =============================================================================

delete_target() {

    local target_index="$1"

    local response


    log "[${target_index}] deleting incomplete target"


    response="$(
        es_delete \
            "/${target_index}" \
            2>&1
    )"


    if [[ $? -ne 0 ]]; then

        error "[${target_index}] DELETE target failed"

        echo "${response}" |
            tee -a "${LOG_FILE}"

        return 1
    fi


    if ! echo "${response}" |
        jq -e '.acknowledged == true' >/dev/null 2>&1; then

        error "[${target_index}] DELETE not acknowledged"

        echo "${response}" |
            tee -a "${LOG_FILE}"

        return 1
    fi


    log "[${target_index}] target deleted"

    return 0
}


# =============================================================================
# DELETE SOURCE AFTER SUCCESS
# =============================================================================

delete_source_after_success() {

    local source_index="$1"
    local target_index="$2"
    local source_count="$3"
    local target_count="$4"
    local replicas="$5"
    local created_version="$6"
    local task_id="$7"

    local verify_json
    local verify_count
    local target_status
    local response


    if [[ "${DELETE_SOURCE_AFTER_SUCCESS}" != "true" ]]; then

        log "[${source_index}] source kept"

        return 0
    fi


    if [[ "${ALLOW_SOURCE_DELETE}" != "true" ]]; then

        error "[${source_index}] source deletion blocked"

        error "[${source_index}] ALLOW_SOURCE_DELETE=false"

        return 1
    fi


    if [[ "${source_count}" != "${target_count}" ]]; then

        error "[${source_index}] DELETE ABORT: count mismatch"

        return 1
    fi


    if [[ "${replicas}" != "0" ]]; then

        error "[${source_index}] DELETE ABORT: replicas=${replicas}"

        return 1
    fi


    verify_json="$(
        es_get \
            "/${target_index}/_count" \
            2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] DELETE ABORT: target cannot be verified"

        return 1
    fi


    verify_count="$(
        echo "${verify_json}" |
        jq -r '.count // 0'
    )"


    if [[ "${verify_count}" != "${source_count}" ]]; then

        error "[${source_index}] DELETE ABORT: final count mismatch"

        error "[${source_index}] expected=${source_count}"
        error "[${source_index}] actual=${verify_count}"

        return 1
    fi


    target_status="$(
        es_get_status "/${target_index}"
    )"


    if [[ "${target_status}" != "200" ]]; then

        error "[${source_index}] DELETE ABORT: target HTTP=${target_status}"

        return 1
    fi


    log "[${source_index}] all DELETE checks passed"

    log "[${source_index}] deleting source"


    response="$(
        es_delete \
            "/${source_index}" \
            2>&1
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] source DELETE failed"

        echo "${response}" |
            tee -a "${LOG_FILE}"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "${target_count}" \
            "${created_version}" \
            "SOURCE_DELETE_ERROR" \
            "${task_id}" \
            "${response}"

        return 1
    fi


    if ! echo "${response}" |
        jq -e '.acknowledged == true' >/dev/null 2>&1; then

        error "[${source_index}] source DELETE not acknowledged"

        return 1
    fi


    log "[${source_index}] SOURCE DELETED"

    return 0
}


# =============================================================================
# INDEX TEMPLATES
# =============================================================================

ALL_INDEX_TEMPLATES='{}'
ALL_COMPONENT_TEMPLATES='{}'


if [[ "${PREFLIGHT_CHECK_TEMPLATES}" == "true" ]]; then

    log "Recupero index template"


    ALL_INDEX_TEMPLATES="$(
        es_get "/_index_template" 2>&1
    )"


    if [[ $? -ne 0 ]]; then

        error "Cannot retrieve index templates"

        echo "${ALL_INDEX_TEMPLATES}" |
            tee -a "${LOG_FILE}"

        exit 1
    fi


    log "Recupero component template"


    ALL_COMPONENT_TEMPLATES="$(
        es_get "/_component_template" 2>&1
    )"


    if [[ $? -ne 0 ]]; then

        error "Cannot retrieve component templates"

        echo "${ALL_COMPONENT_TEMPLATES}" |
            tee -a "${LOG_FILE}"

        exit 1
    fi

fi


# =============================================================================
# CHECK TARGET TEMPLATE
# =============================================================================

check_target_template() {

    local target_index="$1"

    local template_name
    local template_json
    local pattern
    local settings
    local lifecycle
    local rollover

    local component_name
    local component_json
    local component_settings

    local found=false
    local has_ilm=false

    local lifecycle_name=''
    local rollover_alias=''


    while IFS= read -r template_name; do

        [[ -z "${template_name}" ]] && continue


        template_json="$(
            echo "${ALL_INDEX_TEMPLATES}" |
            jq -c \
                --arg name "${template_name}" \
                '
                .index_templates[]
                | select(.name == $name)
                | .index_template
                '
        )"


        while IFS= read -r pattern; do

            [[ -z "${pattern}" ]] && continue


            if [[ "${target_index}" == ${pattern} ]]; then

                found=true

                log "[PREFLIGHT] ${target_index} matches ${template_name} (${pattern})"


                settings="$(
                    echo "${template_json}" |
                    jq -c '.template.settings // {}'
                )"


                lifecycle="$(
                    echo "${settings}" |
                    jq -r '
                        .index.lifecycle.name //
                        .["index.lifecycle.name"] //
                        empty
                    '
                )"


                rollover="$(
                    echo "${settings}" |
                    jq -r '
                        .index.lifecycle.rollover_alias //
                        .["index.lifecycle.rollover_alias"] //
                        empty
                    '
                )"


                if [[ -n "${lifecycle}" ||
                      -n "${rollover}" ]]; then

                    has_ilm=true

                    lifecycle_name="${lifecycle:-none}"
                    rollover_alias="${rollover:-none}"

                fi


                while IFS= read -r component_name; do

                    [[ -z "${component_name}" ]] && continue


                    component_json="$(
                        echo "${ALL_COMPONENT_TEMPLATES}" |
                        jq -c \
                            --arg name "${component_name}" \
                            '
                            .component_templates[]
                            | select(.name == $name)
                            | .component_template
                            '
                    )"


                    component_settings="$(
                        echo "${component_json}" |
                        jq -c '.template.settings // {}'
                    )"


                    lifecycle="$(
                        echo "${component_settings}" |
                        jq -r '
                            .index.lifecycle.name //
                            .["index.lifecycle.name"] //
                            empty
                        '
                    )"


                    rollover="$(
                        echo "${component_settings}" |
                        jq -r '
                            .index.lifecycle.rollover_alias //
                            .["index.lifecycle.rollover_alias"] //
                            empty
                        '
                    )"


                    if [[ -n "${lifecycle}" ||
                          -n "${rollover}" ]]; then

                        has_ilm=true

                        lifecycle_name="${lifecycle:-none}"
                        rollover_alias="${rollover:-none}"

                    fi


                done < <(
                    echo "${template_json}" |
                    jq -r '.composed_of[]?'
                )

            fi


        done < <(
            echo "${template_json}" |
            jq -r '.index_patterns[]?'
        )


    done < <(
        echo "${ALL_INDEX_TEMPLATES}" |
        jq -r '.index_templates[].name'
    )


    if [[ "${has_ilm}" == "true" ]]; then

        printf 'ILM|%s|%s|%s' \
            "${found}" \
            "${lifecycle_name}" \
            "${rollover_alias}"

        return 2

    fi


    printf 'OK|%s||' "${found}"

    return 0
}


# =============================================================================
# PREFLIGHT SINGLE INDEX
# =============================================================================

preflight_index() {

    local source_index="$1"

    local target_index

    local source_json
    local source_count

    local target_status
    local target_exists='false'

    local mapping_ok='SKIPPED'

    local template_ok='SKIPPED'
    local template_lifecycle='false'

    local template_result
    local template_rc

    local status='READY'
    local message='OK'


    target_index="$(
        build_target_name "${source_index}"
    )"


    log "[PREFLIGHT] ${source_index} -> ${target_index}"


    source_json="$(
        es_get "/${source_index}/_count" 2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then

        write_preflight \
            "${source_index}" \
            "${target_index}" \
            "N/A" \
            "N/A" \
            "N/A" \
            "N/A" \
            "N/A" \
            "ERROR" \
            "source count non disponibile"

        return 1
    fi


    source_count="$(
        echo "${source_json}" |
        jq -r '.count // 0'
    )"


    target_status="$(
        es_get_status "/${target_index}"
    )"


    case "${target_status}" in

        200)

            target_exists='true'
            ;;

        404)

            target_exists='false'
            ;;

        *)

            write_preflight \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "unknown" \
                "N/A" \
                "N/A" \
                "N/A" \
                "ERROR" \
                "HTTP target ${target_status}"

            return 1
            ;;

    esac


    if [[ "${PREFLIGHT_CHECK_MAPPINGS}" == "true" ]]; then

        local mapping_json

        mapping_json="$(
            es_get \
                "/${source_index}/_mapping" \
                2>/dev/null
        )"


        if [[ $? -ne 0 ]]; then

            write_preflight \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "${target_exists}" \
                "false" \
                "N/A" \
                "N/A" \
                "ERROR" \
                "mapping non disponibile"

            return 1
        fi


        if echo "${mapping_json}" |
            jq -e \
                --arg index "${source_index}" \
                '.[$index].mappings != null' \
                >/dev/null 2>&1; then

            mapping_ok='true'

        else

            write_preflight \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "${target_exists}" \
                "false" \
                "N/A" \
                "N/A" \
                "ERROR" \
                "mapping non valido"

            return 1
        fi

    fi


    if [[ "${PREFLIGHT_CHECK_TEMPLATES}" == "true" ]]; then

        template_result="$(
            check_target_template "${target_index}"
        )"

        template_rc="$?"


        if [[ "${template_rc}" -eq 2 ]]; then

            template_ok='false'

            template_lifecycle="$(
                echo "${template_result}" |
                awk -F'|' '{print "true:" $3 ":" $4}'
            )"


            write_preflight \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "${target_exists}" \
                "${mapping_ok}" \
                "${template_ok}" \
                "${template_lifecycle}" \
                "ERROR" \
                "target eredita lifecycle/rollover"

            return 1
        fi


        template_ok='true'

    fi


    if [[ "${target_exists}" == "true" ]]; then

        status='SKIP_EXISTING'

        message='target gia esistente; verifica count in fase reale'

    fi


    write_preflight \
        "${source_index}" \
        "${target_index}" \
        "${source_count}" \
        "${target_exists}" \
        "${mapping_ok}" \
        "${template_ok}" \
        "${template_lifecycle}" \
        "${status}" \
        "${message}"


    log "[PREFLIGHT] ${source_index}: ${status}"

    return 0
}


# =============================================================================
# HEADER / SUMMARY
# =============================================================================

log '=================================================================='
log 'ELASTICSEARCH GENERIC REINDEX'
log '=================================================================='

log "ES_URL                          : ${ES_URL}"
log "DRY_RUN                         : ${DRY_RUN}"
log "SOURCE_PREFIX                   : ${SOURCE_PREFIX}"
log "TARGET_PREFIX                   : ${TARGET_PREFIX}"
log "INDEX_PATTERN                   : ${INDEX_PATTERN}"
log "SOURCE_PATTERN                  : ${SOURCE_PATTERN}"
log "TARGET_PATTERN                  : ${TARGET_PATTERN}"
log "EXCLUDE_PATTERN                 : ${EXCLUDE_PATTERN:-<none>}"
log "MAX_PARALLEL                    : ${MAX_PARALLEL}"
log "REQUESTS_PER_SECOND             : ${REQUESTS_PER_SECOND}"
log "POLL_INTERVAL                   : ${POLL_INTERVAL}"
log "PRESERVE_ORIGINATION_DATE       : ${PRESERVE_ORIGINATION_DATE}"
log "BLOCK_SOURCE_WRITES             : ${BLOCK_SOURCE_WRITES}"
log "DELETE_SOURCE_AFTER_SUCCESS     : ${DELETE_SOURCE_AFTER_SUCCESS}"
log "ALLOW_SOURCE_DELETE             : ${ALLOW_SOURCE_DELETE}"

log '=================================================================='


# =============================================================================
# CONNECTION
# =============================================================================

ES_INFO="$(es_get "/" 2>&1)"


if [[ $? -ne 0 ]]; then

    error "Impossibile raggiungere Elasticsearch"

    echo "${ES_INFO}" |
        tee -a "${LOG_FILE}"

    exit 1
fi


ES_VERSION="$(
    echo "${ES_INFO}" |
    jq -r '.version.number // "unknown"'
)"


ES_MAJOR="${ES_VERSION%%.*}"


log "Elasticsearch version: ${ES_VERSION}"


if [[ "${ES_MAJOR}" != "8" ]]; then

    error "Il reindex deve essere eseguito sul cluster Elasticsearch 8"

    exit 1
fi


# =============================================================================
# GET SOURCE INDICES
# =============================================================================

log "Recupero indici tramite:"
log "  ${SOURCE_PATTERN}"


INDICES_JSON="$(
    es_get \
        "/_cat/indices/${SOURCE_PATTERN}?format=json&h=index,docs.count,store.size&s=index" \
        2>&1
)"


if [[ $? -ne 0 ]]; then

    error "Errore recuperando gli indici"

    echo "${INDICES_JSON}" |
        tee -a "${LOG_FILE}"

    exit 1
fi


if [[ -n "${EXCLUDE_PATTERN}" ]]; then

    mapfile -t INDICES < <(

        echo "${INDICES_JSON}" |
        jq -r \
            --arg exclude "${EXCLUDE_PATTERN}" \
            '
            .[]
            | select((.index | contains($exclude)) | not)
            | .index
            ' |
        sort

    )

else

    mapfile -t INDICES < <(

        echo "${INDICES_JSON}" |
        jq -r '.[].index' |
        sort

    )

fi


TOTAL="${#INDICES[@]}"


if [[ "${TOTAL}" -eq 0 ]]; then

    log "Nessun indice da processare"

    exit 0
fi


log "Indici da analizzare: ${TOTAL}"


# =============================================================================
# PREFLIGHT
# =============================================================================

log '=================================================================='
log 'PREFLIGHT START'
log '=================================================================='


PREFLIGHT_FAILED=0


for source_index in "${INDICES[@]}"; do

    if ! preflight_index "${source_index}"; then

        PREFLIGHT_FAILED=1

    fi

done


READY_COUNT="$(
    awk -F',' \
        'NR > 1 && $9 == "\"READY\"" {c++}
         END {print c+0}' \
        "${PREFLIGHT_FILE}"
)"

SKIP_COUNT="$(
    awk -F',' \
        'NR > 1 && $9 == "\"SKIP_EXISTING\"" {c++}
         END {print c+0}' \
        "${PREFLIGHT_FILE}"
)"

ERROR_COUNT="$(
    awk -F',' \
        'NR > 1 && $9 == "\"ERROR\"" {c++}
         END {print c+0}' \
        "${PREFLIGHT_FILE}"
)"


log '=================================================================='
log 'PREFLIGHT SUMMARY'
log '=================================================================='
log "SOURCE INDEXES : ${TOTAL}"
log "READY          : ${READY_COUNT}"
log "SKIP EXISTING  : ${SKIP_COUNT}"
log "ERROR          : ${ERROR_COUNT}"
log "PREFLIGHT FILE : ${PREFLIGHT_FILE}"
log '=================================================================='


if [[ "${PREFLIGHT_FAILED}" -ne 0 ]]; then

    error "PREFLIGHT FALLITO"

    error "Nessuna modifica effettuata"

    exit 2
fi


# =============================================================================
# DRY RUN
# =============================================================================

if [[ "${DRY_RUN}" == "true" ]]; then

    log '=================================================================='
    log 'DRY RUN'
    log '=================================================================='


    printf '\n'

    printf '%-4s %-52s %-52s %12s %10s %20s\n' \
        "#" \
        "SOURCE" \
        "TARGET" \
        "DOCS" \
        "TARGET" \
        "STATUS"


    counter=1


    for source_index in "${INDICES[@]}"; do

        target_index="$(
            build_target_name "${source_index}"
        )"


        source_count="$(
            awk -F',' \
                -v src="${source_index}" \
                '$2 == "\"" src "\"" {print $4; exit}' \
                "${PREFLIGHT_FILE}"
        )"


        target_exists="$(
            awk -F',' \
                -v src="${source_index}" \
                '$2 == "\"" src "\"" {print $5; exit}' \
                "${PREFLIGHT_FILE}"
        )"


        status="$(
            awk -F',' \
                -v src="${source_index}" \
                '$2 == "\"" src "\"" {print $9; exit}' \
                "${PREFLIGHT_FILE}"
        )"


        status="${status%\"}"
        status="${status#\"}"


        printf '%-4s %-52s %-52s %12s %10s %20s\n' \
            "${counter}" \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "${target_exists}" \
            "${status}"


        ((counter++))

    done


    if [[ "${PRESERVE_ORIGINATION_DATE}" == "true" ]]; then

        log "DRY RUN: original index.creation_date will be copied to target index.lifecycle.origination_date"

    else

        log "DRY RUN: origination_date preservation disabled"

    fi


    if [[ "${DELETE_SOURCE_AFTER_SUCCESS}" == "true" &&
          "${ALLOW_SOURCE_DELETE}" == "true" ]]; then

        log "DRY RUN: source deletion ENABLED after successful verification"

    else

        log "DRY RUN: source deletion DISABLED"

    fi


    log "DRY RUN completato"

    log "Nessuna modifica effettuata"

    exit 0
fi


# =============================================================================
# PROCESS SINGLE INDEX
# =============================================================================

process_index() {

    local source_index="$1"

    local target_index

    local source_json
    local source_count

    local target_status
    local verify_status


    local mapping_json
    local mapping


    local source_creation_date=''
    local origination_date=''


    local create_body
    local create_response


    local reindex_body
    local reindex_endpoint
    local reindex_response


    local task_id
    local task_response

    local completed
    local processed

    local failures
    local failure_detail


    local target_json
    local target_count


    local settings_json
    local created_version
    local replicas


    local target_origination_date


    target_index="$(
        build_target_name "${source_index}"
    )"


    log '=================================================================='
    log "[${source_index}] START -> ${target_index}"
    log '=================================================================='


    # =========================================================================
    # SOURCE COUNT
    # =========================================================================

    source_json="$(
        es_get \
            "/${source_index}/_count" \
            2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] source count error"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "N/A" \
            "N/A" \
            "N/A" \
            "SOURCE_COUNT_ERROR" \
            "" \
            "source count error"

        return 1
    fi


    source_count="$(
        echo "${source_json}" |
        jq -r '.count // 0'
    )"


    log "[${source_index}] source_count=${source_count}"


    # =========================================================================
    # TARGET CHECK
    # =========================================================================

    target_status="$(
        es_get_status "/${target_index}"
    )"


    if [[ "${target_status}" != "200" &&
          "${target_status}" != "404" ]]; then

        error "[${source_index}] target check failed: HTTP ${target_status}"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "N/A" \
            "N/A" \
            "TARGET_CHECK_ERROR" \
            "" \
            "HTTP ${target_status}"

        return 1
    fi


    # =========================================================================
    # EXISTING TARGET
    # =========================================================================

    if [[ "${target_status}" == "200" ]]; then

        log "[${source_index}] target already exists"


        if [[ "${VERIFY_EXISTING_TARGET}" == "true" ]]; then

            verify_existing_target \
                "${source_index}" \
                "${target_index}"

            verify_status=$?


            # -----------------------------------------------------------------
            # EXISTING TARGET COMPLETE
            # -----------------------------------------------------------------

            if [[ "${verify_status}" -eq 0 ]]; then

                log "[${source_index}] existing target is complete"


                settings_json="$(
                    es_get \
                        "/${target_index}/_settings?flat_settings=true&include_defaults=false" \
                        2>/dev/null
                )"


                if [[ $? -ne 0 ]]; then

                    error "[${source_index}] cannot read target settings"

                    return 1

                fi


                replicas="$(
                    echo "${settings_json}" |
                    jq -r '.[].settings["index.number_of_replicas"] // "unknown"'
                )"


                created_version="$(
                    echo "${settings_json}" |
                    jq -r '.[].settings["index.version.created"] // "existing"'
                )"


                if [[ "${replicas}" != "0" ]]; then

                    error "[${source_index}] existing target replicas=${replicas}"

                    write_result \
                        "${source_index}" \
                        "${target_index}" \
                        "${source_count}" \
                        "${source_count}" \
                        "${created_version}" \
                        "EXISTING_TARGET_REPLICAS_ERROR" \
                        "" \
                        "replicas=${replicas}"

                    return 1
                fi


                if [[ "${BLOCK_SOURCE_WRITES}" == "true" ]]; then

                    if ! block_source_writes "${source_index}"; then
                        return 1
                    fi

                fi


                if delete_source_after_success \
                    "${source_index}" \
                    "${target_index}" \
                    "${source_count}" \
                    "${source_count}" \
                    "${replicas}" \
                    "${created_version}" \
                    ""; then


                    write_result \
                        "${source_index}" \
                        "${target_index}" \
                        "${source_count}" \
                        "${source_count}" \
                        "${created_version}" \
                        "SKIPPED_EXISTS_VERIFIED" \
                        "" \
                        ""

                    return 0

                else

                    write_result \
                        "${source_index}" \
                        "${target_index}" \
                        "${source_count}" \
                        "${source_count}" \
                        "${created_version}" \
                        "SKIPPED_EXISTS_DELETE_NOT_EXECUTED" \
                        "" \
                        "source not deleted"

                    return 1

                fi

            fi


            # -----------------------------------------------------------------
            # EXISTING TARGET VERIFY ERROR
            # -----------------------------------------------------------------

            if [[ "${verify_status}" -eq 1 ]]; then

                error "[${source_index}] existing target verification failed"

                write_result \
                    "${source_index}" \
                    "${target_index}" \
                    "${source_count}" \
                    "N/A" \
                    "N/A" \
                    "EXISTING_TARGET_VERIFY_ERROR" \
                    "" \
                    "target verification error"

                return 1

            fi


            # -----------------------------------------------------------------
            # EXISTING TARGET COUNT MISMATCH
            # -----------------------------------------------------------------

            if [[ "${verify_status}" -eq 2 ]]; then

                error "[${source_index}] existing target is incomplete"


                if [[ "${REINDEX_EXISTING_ON_COUNT_MISMATCH}" != "true" ]]; then

                    write_result \
                        "${source_index}" \
                        "${target_index}" \
                        "${source_count}" \
                        "N/A" \
                        "N/A" \
                        "EXISTING_TARGET_COUNT_MISMATCH" \
                        "" \
                        "target count mismatch"

                    return 1
                fi


                if ! delete_target "${target_index}"; then
                    return 1
                fi

            fi

        elif [[ "${SKIP_EXISTING}" == "true" ]]; then

            log "[${source_index}] existing target -> SKIP"

            write_result \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "N/A" \
                "existing" \
                "SKIPPED_EXISTS" \
                "" \
                ""

            return 0

        else

            error "[${source_index}] target already exists"

            return 1

        fi
    fi


    # =========================================================================
    # GET ORIGINAL CREATION DATE
    #
    # This MUST happen before deleting the source.
    # =========================================================================

    if [[ "${PRESERVE_ORIGINATION_DATE}" == "true" ]]; then

        source_creation_date="$(
            get_source_creation_date "${source_index}"
        )"


        if [[ -z "${source_creation_date}" ]]; then

            error "[${source_index}] index.creation_date not available"

            write_result \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "N/A" \
                "N/A" \
                "SOURCE_CREATION_DATE_ERROR" \
                "" \
                "index.creation_date non disponibile"

            return 1

        fi


        if [[ ! "${source_creation_date}" =~ ^[0-9]+$ ]]; then

            error "[${source_index}] invalid index.creation_date=${source_creation_date}"

            write_result \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "N/A" \
                "N/A" \
                "SOURCE_CREATION_DATE_INVALID" \
                "" \
                "creation_date non numerico"

            return 1
        fi


        origination_date="${source_creation_date}"


        log "[${source_index}] original creation_date=${source_creation_date}"

        log "[${source_index}] target origination_date=${origination_date}"

    fi


    # =========================================================================
    # SOURCE READ ONLY
    # =========================================================================

    if [[ "${BLOCK_SOURCE_WRITES}" == "true" ]]; then

        if ! block_source_writes "${source_index}"; then

            write_result \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "N/A" \
                "N/A" \
                "SOURCE_BLOCK_ERROR" \
                "" \
                "source read-only failed"

            return 1
        fi

    fi


    # =========================================================================
    # SOURCE MAPPING
    # =========================================================================

    mapping_json="$(
        es_get \
            "/${source_index}/_mapping" \
            2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] mapping error"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "N/A" \
            "N/A" \
            "MAPPING_ERROR" \
            "" \
            "mapping error"

        return 1
    fi


    mapping="$(
        echo "${mapping_json}" |
        jq -c \
            --arg index "${source_index}" \
            '.[$index].mappings // {}'
    )"


    # =========================================================================
    # CREATE TARGET
    #
    # The target is a new Elasticsearch 8 index.
    #
    # It does NOT inherit the old index's:
    #   - index.version.created
    #   - index.creation_date
    #
    # Only the historical origination date is explicitly preserved.
    # =========================================================================

    if [[ "${PRESERVE_ORIGINATION_DATE}" == "true" ]]; then

        create_body="$(
            jq -n \
                --argjson mappings "${mapping}" \
                --arg origination_date "${origination_date}" \
                '{
                    settings: {
                        number_of_shards: 1,
                        number_of_replicas: 0,
                        "index.lifecycle.origination_date": ($origination_date | tonumber)
                    },
                    mappings: $mappings
                }'
        )"

    else

        create_body="$(
            jq -n \
                --argjson mappings "${mapping}" \
                '{
                    settings: {
                        number_of_shards: 1,
                        number_of_replicas: 0
                    },
                    mappings: $mappings
                }'
        )"

    fi


    log "[${source_index}] creating ${target_index}"


    create_response="$(
        es_put \
            "/${target_index}" \
            "${create_body}" \
            2>&1
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] target creation failed"

        echo "${create_response}" |
            tee -a "${LOG_FILE}"


        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "N/A" \
            "N/A" \
            "CREATE_TARGET_ERROR" \
            "" \
            "${create_response}"

        return 1
    fi


    # =========================================================================
    # REINDEX
    # =========================================================================

    reindex_body="$(
        jq -n \
            --arg source "${source_index}" \
            --arg target "${target_index}" \
            '{
                source: {
                    index: $source
                },
                dest: {
                    index: $target
                },
                conflicts: "proceed"
            }'
    )"


    if [[ "${REQUESTS_PER_SECOND}" == "-1" ]]; then

        reindex_endpoint="/_reindex?wait_for_completion=false&refresh=false"

    else

        reindex_endpoint="/_reindex?wait_for_completion=false&refresh=false&requests_per_second=${REQUESTS_PER_SECOND}"

    fi


    log "[${source_index}] starting reindex"

    log "[${source_index}] ${reindex_endpoint}"


    reindex_response="$(
        es_post \
            "${reindex_endpoint}" \
            "${reindex_body}" \
            2>&1
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] reindex start failed"

        echo "${reindex_response}" |
            tee -a "${LOG_FILE}"


        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "N/A" \
            "N/A" \
            "REINDEX_START_ERROR" \
            "" \
            "${reindex_response}"

        return 1
    fi


    task_id="$(
        echo "${reindex_response}" |
        jq -r '.task // empty'
    )"


    if [[ -z "${task_id}" ]]; then

        error "[${source_index}] task ID not received"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "N/A" \
            "N/A" \
            "NO_TASK_ID" \
            "" \
            "${reindex_response}"

        return 1
    fi


    log "[${source_index}] task=${task_id}"


    # =========================================================================
    # TASK POLLING
    # =========================================================================

    while true; do

        task_response="$(
            es_get \
                "/_tasks/${task_id}" \
                2>/dev/null
        )"


        if [[ $? -ne 0 ]]; then

            error "[${source_index}] task polling failed"

            write_result \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "N/A" \
                "N/A" \
                "TASK_POLL_ERROR" \
                "${task_id}" \
                "task polling error"

            return 1
        fi


        completed="$(
            echo "${task_response}" |
            jq -r '.completed // false'
        )"


        processed="$(
            echo "${task_response}" |
            jq -r '
                (.task.status.created // 0) +
                (.task.status.updated // 0) +
                (.task.status.deleted // 0)
            '
        )"


        log "[${source_index}] task=${task_id} processed=${processed}/${source_count}"


        if [[ "${completed}" == "true" ]]; then
            break
        fi


        sleep "${POLL_INTERVAL}"

    done


    # =========================================================================
    # REINDEX FAILURES
    # =========================================================================

    failures="$(
        echo "${task_response}" |
        jq '.response.failures // [] | length'
    )"


    if [[ "${failures}" -gt 0 ]]; then

        failure_detail="$(
            echo "${task_response}" |
            jq -c '.response.failures'
        )"


        error "[${source_index}] reindex completed with failures"

        echo "${failure_detail}" |
            tee -a "${LOG_FILE}"


        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "N/A" \
            "N/A" \
            "REINDEX_FAILURE" \
            "${task_id}" \
            "${failure_detail}"

        return 1
    fi


    # =========================================================================
    # TARGET COUNT
    # =========================================================================

    target_json="$(
        es_get \
            "/${target_index}/_count" \
            2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] target count error"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "N/A" \
            "N/A" \
            "TARGET_COUNT_ERROR" \
            "${task_id}" \
            "target count error"

        return 1
    fi


    target_count="$(
        echo "${target_json}" |
        jq -r '.count // 0'
    )"


    log "[${source_index}] source_count=${source_count}"
    log "[${source_index}] target_count=${target_count}"


    # =========================================================================
    # COUNT VERIFICATION
    # =========================================================================

    if [[ "${source_count}" != "${target_count}" ]]; then

        error "[${source_index}] COUNT MISMATCH"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "${target_count}" \
            "N/A" \
            "COUNT_MISMATCH" \
            "${task_id}" \
            "source_count != target_count"

        return 1
    fi


    # =========================================================================
    # TARGET SETTINGS
    # =========================================================================

    settings_json="$(
        es_get \
            "/${target_index}/_settings?flat_settings=true&include_defaults=false" \
            2>/dev/null
    )"


    if [[ $? -ne 0 ]]; then

        error "[${source_index}] target settings error"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "${target_count}" \
            "N/A" \
            "TARGET_SETTINGS_ERROR" \
            "${task_id}" \
            "target settings error"

        return 1
    fi


    created_version="$(
        echo "${settings_json}" |
        jq -r '.[].settings["index.version.created"] // "unknown"'
    )"


    replicas="$(
        echo "${settings_json}" |
        jq -r '.[].settings["index.number_of_replicas"] // "unknown"'
    )"


    log "[${source_index}] target version.created=${created_version}"

    log "[${source_index}] target replicas=${replicas}"


    # =========================================================================
    # ORIGINATION DATE VERIFICATION
    # =========================================================================

    if [[ "${PRESERVE_ORIGINATION_DATE}" == "true" ]]; then

        target_origination_date="$(
            echo "${settings_json}" |
            jq -r '.[].settings["index.lifecycle.origination_date"] // empty'
        )"


        log "[${source_index}] target origination_date=${target_origination_date}"


        if [[ "${target_origination_date}" != "${origination_date}" ]]; then

            error "[${source_index}] origination_date mismatch"

            error "[${source_index}] expected=${origination_date}"

            error "[${source_index}] actual=${target_origination_date}"


            write_result \
                "${source_index}" \
                "${target_index}" \
                "${source_count}" \
                "${target_count}" \
                "${created_version}" \
                "ORIGINATION_DATE_MISMATCH" \
                "${task_id}" \
                "expected=${origination_date} actual=${target_origination_date}"

            return 1
        fi

    fi


    # =========================================================================
    # REPLICAS VERIFICATION
    # =========================================================================

    if [[ "${replicas}" != "0" ]]; then

        error "[${source_index}] replicas != 0"

        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "${target_count}" \
            "${created_version}" \
            "REPLICAS_MISMATCH" \
            "${task_id}" \
            "number_of_replicas != 0"

        return 1
    fi


    # =========================================================================
    # DELETE SOURCE
    # =========================================================================

    if ! delete_source_after_success \
        "${source_index}" \
        "${target_index}" \
        "${source_count}" \
        "${target_count}" \
        "${replicas}" \
        "${created_version}" \
        "${task_id}"; then


        write_result \
            "${source_index}" \
            "${target_index}" \
            "${source_count}" \
            "${target_count}" \
            "${created_version}" \
            "SUCCESS_DELETE_NOT_EXECUTED" \
            "${task_id}" \
            "reindex riuscito ma source non cancellato"

        return 1
    fi


    # =========================================================================
    # SUCCESS
    # =========================================================================

    log '=================================================================='
    log "[${source_index}] SUCCESS"
    log "[${source_index}] source_count=${source_count}"
    log "[${source_index}] target_count=${target_count}"
    log "[${source_index}] version.created=${created_version}"
    log "[${source_index}] replicas=${replicas}"

    if [[ "${PRESERVE_ORIGINATION_DATE}" == "true" ]]; then
        log "[${source_index}] origination_date=${origination_date}"
    fi

    log '=================================================================='


    write_result \
        "${source_index}" \
        "${target_index}" \
        "${source_count}" \
        "${target_count}" \
        "${created_version}" \
        "SUCCESS" \
        "${task_id}" \
        ""


    return 0
}


# =============================================================================
# REAL EXECUTION
# =============================================================================

if [[ "${DRY_RUN}" == "false" ]]; then

    RUNNING_PIDS=()
    RUNNING_NAMES=()

    ACTIVE=0
    FAILED=0


    for source_index in "${INDICES[@]}"; do

        process_index "${source_index}" &

        pid=$!

        RUNNING_PIDS+=("${pid}")
        RUNNING_NAMES+=("${source_index}")

        ((ACTIVE++))


        if [[ "${ACTIVE}" -ge "${MAX_PARALLEL}" ]]; then

            for i in "${!RUNNING_PIDS[@]}"; do

                pid="${RUNNING_PIDS[$i]}"
                name="${RUNNING_NAMES[$i]}"


                if wait "${pid}"; then

                    log "[${name}] processo terminato OK"

                else

                    error "[${name}] processo terminato ERROR"

                    FAILED=1

                fi

            done


            RUNNING_PIDS=()
            RUNNING_NAMES=()

            ACTIVE=0

        fi

    done


    for i in "${!RUNNING_PIDS[@]}"; do

        pid="${RUNNING_PIDS[$i]}"
        name="${RUNNING_NAMES[$i]}"


        if wait "${pid}"; then

            log "[${name}] processo terminato OK"

        else

            error "[${name}] processo terminato ERROR"

            FAILED=1

        fi

    done

else

    FAILED=0

fi


# =============================================================================
# FINAL SUMMARY
# =============================================================================

SUCCESS_COUNT="$(
    awk -F',' '
        NR > 1 {
            s=$7
            gsub(/^"|"$/, "", s)

            if (s == "SUCCESS") {
                c++
            }
        }

        END {
            print c+0
        }
    ' "${RESULT_FILE}"
)"


ERROR_RESULT_COUNT="$(
    awk -F',' '
        NR > 1 {
            s=$7
            gsub(/^"|"$/, "", s)

            if (
                s != "" &&
                s != "SUCCESS" &&
                s != "SKIPPED_EXISTS" &&
                s != "SKIPPED_EXISTS_VERIFIED"
            ) {
                c++
            }
        }

        END {
            print c+0
        }
    ' "${RESULT_FILE}"
)"


log '=================================================================='
log 'FINAL SUMMARY'
log '=================================================================='
log "SOURCE INDEXES : ${TOTAL}"
log "SUCCESS        : ${SUCCESS_COUNT}"
log "ERROR          : ${ERROR_RESULT_COUNT}"
log "PREFLIGHT      : ${PREFLIGHT_FILE}"
log "RESULT         : ${RESULT_FILE}"
log "LOG            : ${LOG_FILE}"
log '=================================================================='


if [[ "${FAILED}" -ne 0 ]]; then
    exit 1
fi


exit 0
