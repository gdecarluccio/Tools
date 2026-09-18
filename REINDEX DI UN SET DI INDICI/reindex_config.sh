#!/usr/bin/env bash

# =============================================================================
# ELASTICSEARCH GENERIC REINDEX - CONFIGURATION
# =============================================================================

# =============================================================================
# EXECUTION
# =============================================================================

# true  = pre-flight / dry-run only
# false = real execution
export DRY_RUN="false"


# =============================================================================
# ELASTICSEARCH CONNECTION
# =============================================================================

export ES_URL="https://10.50.10.132:9200"

export ES_USER="elastic"
export ES_PASS="ezgCM-kci=BMev1NSfIH"

# API Key alternative
export ES_API_KEY=""

# CA certificate
export CA_CERT="/etc/elasticsearch/cert/ca/ca.crt"

# true  = skip TLS certificate verification
# false = use CA_CERT
export INSECURE_TLS="false"


# =============================================================================
# SOURCE / TARGET NAMING
# =============================================================================

export SOURCE_PREFIX="migr-7"
export TARGET_PREFIX="migr-8"

# Common index pattern
export INDEX_PATTERN="k8s-prod-app-hl7"

# Automatically generated patterns
export SOURCE_PATTERN="${SOURCE_PREFIX}-${INDEX_PATTERN}-*"
export TARGET_PATTERN="${TARGET_PREFIX}-${INDEX_PATTERN}-*"


# =============================================================================
# EXCLUSIONS
# =============================================================================

# Any source index containing this string will be excluded.
# Empty = no exclusion.
export EXCLUDE_PATTERN="recupero"


# =============================================================================
# PERFORMANCE
# =============================================================================

# Number of simultaneous reindex tasks.
export MAX_PARALLEL="2"

# Seconds between task polling.
export POLL_INTERVAL="10"

# -1 = no artificial throttling
# 1000 = approximately 1000 docs/sec per task
export REQUESTS_PER_SECOND="-1"


# =============================================================================
# EXISTING TARGETS
# =============================================================================

# true  = existing target can be skipped after verification
# false = existing target is an error
export SKIP_EXISTING="true"

# true = verify source_count vs target_count when target exists
export VERIFY_EXISTING_TARGET="true"

# true  = if target exists but count differs:
#         delete target and rebuild it
#
# false = count mismatch is an error
export REINDEX_EXISTING_ON_COUNT_MISMATCH="true"


# =============================================================================
# SOURCE WRITE PROTECTION
# =============================================================================

# true = set index.blocks.write=true on source before reindex
export BLOCK_SOURCE_WRITES="true"


# =============================================================================
# PRESERVE HISTORICAL ILM AGE
# =============================================================================

# true = copy source index.creation_date into
#        target index.lifecycle.origination_date
#
# false = do not configure origination_date
export PRESERVE_ORIGINATION_DATE="true"


# =============================================================================
# DELETE SOURCE AFTER SUCCESS
# =============================================================================

# true  = delete source after successful and verified reindex
# false = always keep source
export DELETE_SOURCE_AFTER_SUCCESS="true"

# Additional safety switch.
#
# Source can be deleted ONLY if BOTH are true:
#
# DELETE_SOURCE_AFTER_SUCCESS=true
# ALLOW_SOURCE_DELETE=true
#
export ALLOW_SOURCE_DELETE="true"


# =============================================================================
# PREFLIGHT
# =============================================================================

export PREFLIGHT_CHECK_MAPPINGS="true"

export PREFLIGHT_CHECK_TEMPLATES="true"

# true  = fail if target matches a template containing ILM/rollover
# false = report it but do not fail
export FAIL_ON_TARGET_ILM="true"


# =============================================================================
# LOGGING
# =============================================================================

export LOG_DIR="./logs"

export RUN_TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

export LOG_FILE="${LOG_DIR}/reindex_${RUN_TIMESTAMP}.log"

export PREFLIGHT_FILE="${LOG_DIR}/preflight_${RUN_TIMESTAMP}.csv"

export RESULT_FILE="${LOG_DIR}/reindex_result_${RUN_TIMESTAMP}.csv"
