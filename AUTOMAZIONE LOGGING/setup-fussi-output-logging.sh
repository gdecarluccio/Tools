#!/bin/bash

# Parametri
SYSTEM_PROJECT_ID="ID PROGETTO SYSTEM"       # <-- ID progetto "system"
AMBIENTE="AMBIANTE"                   # <-- Cambia con il tuo ambiente (es: dev, stage, prod)
OUTPUT_DIR="./outputs"            # <-- Dove salvare i file YAML

mkdir -p "$OUTPUT_DIR"

# Prende tutti i namespace
all_namespaces=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Prende i namespace del progetto di sistema
system_namespaces=$(kubectl get ns -l field.cattle.io/projectId=${SYSTEM_PROJECT_ID} -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

readarray -t all_ns_array <<< "$all_namespaces"
readarray -t system_ns_array <<< "$system_namespaces"

clean_name() {
  echo "$1" | tr -d '-'
}

is_system_ns() {
  local ns=$1
  [[ " ${system_ns_array[*]} " =~ " $ns " ]]
}

for ns in "${all_ns_array[@]}"; do
  ns_clean=$(clean_name "$ns")

  if is_system_ns "$ns"; then
    index_name="k8s-${AMBIENTE}-infra-${ns_clean}"
  else
    index_name="k8s-${AMBIENTE}-app-${ns_clean}"
  fi

  # Crea YAML Output
  cat <<EOF | kubectl apply -f -
apiVersion: logging.banzaicloud.io/v1beta1
kind: Output
metadata:
  name: ${index_name}
  namespace: ${ns}
spec:
  elasticsearch:
    host: elk-svc
    index_name: ${index_name}
    log_es_400_reason: true
    password:
      valueFrom:
        secretKeyRef:
          key: password
          name: log-user
    port: 9200
    scheme: https
    ssl_verify: false
    ssl_version: TLSv1_2
    suppress_type_name: true
    user: rancher
---
apiVersion: logging.banzaicloud.io/v1beta1
kind: Flow
metadata:
  name: ${index_name}
  namespace: ${ns}
spec:
  globalOutputRefs: []
  localOutputRefs:
    - ${index_name}
  filters:

    - dedot:
        de_dot_nested: true
        de_dot_separator: "_"

    - record_transformer:
        enable_ruby: true
        records:
          - logging_stream_id: '\${record["kubernetes"]["pod_name"]}/\${record["kubernetes"]["container_name"]}/\${record["stream"]}'

    - concat:
        key: log
        multiline_start_regexp: '/^(?:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}|\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}|\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2}|\d{1,3}(?:\.\d{1,3}){3}\s+-\s+-\s+\[)/'
        separator: "\n"
        stream_identity_key: logging_stream_id
        flush_interval: 0
        use_first_timestamp: true

    - detectExceptions:
        languages:
          - java
          - python
        max_lines: 1000
        multiline_flush_interval: "0.5"
        message: log

    - parser:
        key_name: log
        reserve_data: true
        reserve_time: true
        remove_key_name_field: false
        emit_invalid_record_to_error: false
        hash_value_field: parsed
        parse:
          type: multi_format
          patterns:
            - format: json
            - format: none

    - record_transformer:
        remove_keys: logging_stream_id
        records:
          - logging_pipeline_version: "v2"
          - logging_multiline_engine: "concat-universal-v1"


EOF

  echo "✅ Creati Output e Flow per namespace $ns"
  sleep 10
done