#!/usr/bin/env bash

set -u
set -o pipefail


SCRIPT_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")" &&
    pwd
)"


CONFIG_FILE="${SCRIPT_DIR}/reindex_config.sh"
REINDEX_SCRIPT="${SCRIPT_DIR}/reindex_generic.sh"


###############################################################################
# CHECK FILE
###############################################################################

if [[ ! -f "$CONFIG_FILE" ]]; then

    echo "ERROR: configurazione non trovata:"
    echo "$CONFIG_FILE"

    exit 1
fi


if [[ ! -f "$REINDEX_SCRIPT" ]]; then

    echo "ERROR: script generico non trovato:"
    echo "$REINDEX_SCRIPT"

    exit 1
fi


###############################################################################
# LOAD CONFIG
###############################################################################

source "$CONFIG_FILE"


###############################################################################
# DISPLAY
###############################################################################

echo
echo "=================================================================="
echo "ELASTICSEARCH REINDEX"
echo "=================================================================="

echo "ES URL              : ${ES_URL}"
echo "DRY RUN             : ${DRY_RUN}"
echo "SOURCE PREFIX       : ${SOURCE_PREFIX}"
echo "TARGET PREFIX       : ${TARGET_PREFIX}"
echo "INDEX PATTERN       : ${INDEX_PATTERN}"
echo "SOURCE PATTERN      : ${SOURCE_PATTERN}"
echo "TARGET PATTERN      : ${TARGET_PATTERN}"
echo "EXCLUDE             : ${EXCLUDE_PATTERN:-<none>}"
echo "MAX PARALLEL        : ${MAX_PARALLEL}"
echo "REQUESTS/SECOND     : ${REQUESTS_PER_SECOND}"
echo "POLL INTERVAL       : ${POLL_INTERVAL}"
echo "=================================================================="
echo


###############################################################################
# CONFIRMATION
###############################################################################

if [[ "${DRY_RUN}" == "true" ]]; then

    echo "Modalità: DRY RUN"
    echo "Non verranno effettuate modifiche al cluster."
    echo

else

    echo "ATTENZIONE: modalità REALE."
    echo "Verranno creati indici e avviati task _reindex."
    echo

fi


read -r -p "Continuare? [yes/no]: " CONFIRM


if [[ "$CONFIRM" != "yes" ]]; then

    echo "Operazione annullata."

    exit 0
fi


###############################################################################
# RUN
###############################################################################

exec "$REINDEX_SCRIPT"
