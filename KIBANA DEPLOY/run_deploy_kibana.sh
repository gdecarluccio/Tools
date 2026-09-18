#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/deploy_kibana_config.sh"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
WORK_DIR="$(mktemp -d -t kibana-deploy.XXXXXX)"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
title() { echo -e "\n${BLUE}============================================================${NC}\n${BLUE}$*${NC}\n${BLUE}============================================================${NC}"; }

usage() {
    cat <<EOF
Uso:
  ${0##*/} [--dry-run | --deploy]

Senza parametri viene mostrato il menu interattivo.

Opzioni:
  --dry-run     Valida i manifest contro l'API server senza modificare il cluster.
  --deploy      Esegue il deployment reale, previa conferma.
  -h, --help    Mostra questo help.
EOF
}

# ------------------------------------------------------------
# Caricamento configurazione
# ------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
    error "File di configurazione non trovato: ${CONFIG_FILE}"
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

DRY_RUN=""
EXPLICIT_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            EXPLICIT_MODE=true
            shift
            ;;
        --deploy)
            DRY_RUN=false
            EXPLICIT_MODE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Parametro non riconosciuto: $1"
            usage
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------
# Validazione configurazione
# ------------------------------------------------------------
required_vars=(
    NAMESPACE
    KIBANA_NAME
    KIBANA_IMAGE
    REPLICAS
    ELASTICSEARCH_SERVICE
    ELASTICSEARCH_IP
    ELASTICSEARCH_PORT
    ELASTICSEARCH_HOSTS
    SERVER_NAME
    SERVER_PUBLICBASEURL
    KIBANA_HOST
    CREDENTIALS_SECRET
    ELASTICSEARCH_USERNAME
    CA_SECRET
    CA_FILE
    CA_KEY
    KIBANA_SERVICE_PORT
    INGRESS_CONTROLLER
    INGRESS_CLASS
    INGRESS_NAME
    ROLLOUT_TIMEOUT
)

for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
        error "Variabile obbligatoria non valorizzata: ${var_name}"
        exit 1
    fi
done

case "${INGRESS_CONTROLLER}" in
    nginx|aws-alb)
        ;;
    *)
        error "INGRESS_CONTROLLER non supportato: ${INGRESS_CONTROLLER}"
        error "Valori ammessi: nginx | aws-alb"
        exit 1
        ;;
esac

if ! [[ "${REPLICAS}" =~ ^[0-9]+$ ]] || (( REPLICAS < 1 )); then
    error "REPLICAS deve essere un intero >= 1"
    exit 1
fi

if ! [[ "${ELASTICSEARCH_PORT}" =~ ^[0-9]+$ ]]; then
    error "ELASTICSEARCH_PORT non valido: ${ELASTICSEARCH_PORT}"
    exit 1
fi

if ! [[ "${KIBANA_SERVICE_PORT}" =~ ^[0-9]+$ ]]; then
    error "KIBANA_SERVICE_PORT non valido: ${KIBANA_SERVICE_PORT}"
    exit 1
fi

if [[ ! -f "${CA_FILE}" ]]; then
    error "CA Elasticsearch non trovata: ${CA_FILE}"
    exit 1
fi

# ------------------------------------------------------------
# Dipendenze
# ------------------------------------------------------------
for cmd in kubectl envsubst; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        error "Comando richiesto non trovato: ${cmd}"
        exit 1
    fi
done

# ------------------------------------------------------------
# Selezione modalità
# ------------------------------------------------------------
if [[ "${EXPLICIT_MODE}" == false ]]; then
    title "KIBANA DEPLOYMENT"

    echo "Seleziona la modalità:"
    echo
    echo "  1) Dry Run"
    echo "  2) Deploy reale"
    echo "  3) Annulla"
    echo

    while true; do
        read -rp "Scelta [1-3]: " choice
        case "${choice}" in
            1)
                DRY_RUN=true
                break
                ;;
            2)
                DRY_RUN=false
                break
                ;;
            3)
                log "Operazione annullata."
                exit 0
                ;;
            *)
                warn "Scelta non valida."
                ;;
        esac
    done
fi

# ------------------------------------------------------------
# Password
#
# 1. Se esiste KIBANA_ELASTICSEARCH_PASSWORD nell'ambiente,
#    viene usata.
# 2. Altrimenti viene richiesta a runtime.
#
# Il valore non viene stampato.
# ------------------------------------------------------------
if [[ -n "${KIBANA_ELASTICSEARCH_PASSWORD:-}" ]]; then
    ELASTICSEARCH_PASSWORD="${KIBANA_ELASTICSEARCH_PASSWORD}"
else
    read -rsp "Password utente ${ELASTICSEARCH_USERNAME}: " ELASTICSEARCH_PASSWORD
    echo
fi

if [[ -z "${ELASTICSEARCH_PASSWORD}" ]]; then
    error "La password non può essere vuota."
    exit 1
fi

export ELASTICSEARCH_PASSWORD

# ------------------------------------------------------------
# Kibana Encryption Keys
# ------------------------------------------------------------

echo
log "Configurazione Kibana encryption keys"

read -rsp "XPACK Encrypted Saved Objects Encryption Key: " \
    ENCRYPTED_SAVED_OBJECTS_KEY
echo

read -rsp "XPACK Security Encryption Key: " \
    SECURITY_ENCRYPTION_KEY
echo

read -rsp "XPACK Reporting Encryption Key: " \
    REPORTING_ENCRYPTION_KEY
echo

if (( ${#ENCRYPTED_SAVED_OBJECTS_KEY} < 32 )); then
    error "XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY deve essere lunga almeno 32 caratteri."
    exit 1
fi

if (( ${#SECURITY_ENCRYPTION_KEY} < 32 )); then
    error "XPACK_SECURITY_ENCRYPTIONKEY deve essere lunga almeno 32 caratteri."
    exit 1
fi

if (( ${#REPORTING_ENCRYPTION_KEY} < 32 )); then
    error "XPACK_REPORTING_ENCRYPTIONKEY deve essere lunga almeno 32 caratteri."
    exit 1
fi

# ------------------------------------------------------------
# Kubeconfig / context
# ------------------------------------------------------------
KUBECTL_ARGS=()
if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    KUBECTL_ARGS+=(--context "${KUBE_CONTEXT}")
fi

KUBE_CONTEXT_CURRENT="$(kubectl "${KUBECTL_ARGS[@]}" config current-context 2>/dev/null || true)"

if [[ -z "${KUBE_CONTEXT_CURRENT}" ]]; then
    error "Impossibile determinare il context Kubernetes."
    exit 1
fi

# ------------------------------------------------------------
# Riepilogo configurazione
# ------------------------------------------------------------
title "CONFIGURAZIONE"

printf "%-28s : %s\n" "Kubernetes context" "${KUBE_CONTEXT_CURRENT}"
printf "%-28s : %s\n" "Namespace" "${NAMESPACE}"
printf "%-28s : %s\n" "Kibana name" "${KIBANA_NAME}"
printf "%-28s : %s\n" "Kibana image" "${KIBANA_IMAGE}"
printf "%-28s : %s\n" "Replicas" "${REPLICAS}"
echo
printf "%-28s : %s\n" "Elasticsearch service" "${ELASTICSEARCH_SERVICE}"
printf "%-28s : %s\n" "Elasticsearch IP" "${ELASTICSEARCH_IP}"
printf "%-28s : %s\n" "Elasticsearch port" "${ELASTICSEARCH_PORT}"
printf "%-28s : %s\n" "Elasticsearch hosts" "${ELASTICSEARCH_HOSTS}"
echo
printf "%-28s : %s\n" "Kibana server name" "${SERVER_NAME}"
printf "%-28s : %s\n" "Kibana public URL" "${SERVER_PUBLICBASEURL}"
printf "%-28s : %s\n" "Ingress hostname" "${KIBANA_HOST}"
echo
printf "%-28s : %s\n" "Ingress controller" "${INGRESS_CONTROLLER}"
printf "%-28s : %s\n" "Ingress class" "${INGRESS_CLASS}"
printf "%-28s : %s\n" "Ingress name" "${INGRESS_NAME}"

if [[ "${INGRESS_CONTROLLER}" == "nginx" ]]; then
    printf "%-28s : %s\n" "Ingress TLS secret" "${INGRESS_TLS_SECRET:-<none>}"
else
    printf "%-28s : %s\n" "ALB backend protocol" "${ALB_BACKEND_PROTOCOL}"
    printf "%-28s : %s\n" "ALB certificate ARN" "${ALB_CERTIFICATE_ARN:-<none>}"
    printf "%-28s : %s\n" "ALB group" "${ALB_GROUP_NAME}"
    printf "%-28s : %s\n" "ALB scheme" "${ALB_SCHEME}"
    printf "%-28s : %s\n" "ALB listen ports" "${ALB_LISTEN_PORTS}"
    printf "%-28s : %s\n" "ALB subnets" "${ALB_SUBNETS:-<none>}"
    printf "%-28s : %s\n" "ALB target type" "${ALB_TARGET_TYPE}"
fi

echo
printf "%-28s : %s\n" "CA file" "${CA_FILE}"
printf "%-28s : %s\n" "CA secret" "${CA_SECRET}"
printf "%-28s : %s\n" "Credentials secret" "${CREDENTIALS_SECRET}"
printf "%-28s : %s\n" "Mode" "$([[ "${DRY_RUN}" == true ]] && echo "DRY RUN" || echo "DEPLOY REALE")"

# ------------------------------------------------------------
# Conferma
# ------------------------------------------------------------
echo

if [[ "${DRY_RUN}" == true ]]; then
    read -rp "Confermi l'esecuzione del DRY RUN? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || {
        log "Operazione annullata."
        exit 0
    }
else
    warn "STAI PER ESEGUIRE UN DEPLOYMENT REALE SUL CLUSTER."
    read -rp "Confermi il deployment? [y/N]: " confirm
    [[ "${confirm}" =~ ^[Yy]$ ]] || {
        log "Operazione annullata."
        exit 0
    }

    warn "Seconda conferma richiesta."
    read -rp "Confermi NUOVAMENTE il deployment REALE? [y/N]: " confirm2
    [[ "${confirm2}" =~ ^[Yy]$ ]] || {
        log "Operazione annullata."
        exit 0
    }
fi

# ------------------------------------------------------------
# Funzioni manifest
# ------------------------------------------------------------
render_template() {
    local src="$1"
    local dst="$2"

    if [[ ! -f "${src}" ]]; then
        error "Template non trovato: ${src}"
        exit 1
    fi

    envsubst < "${src}" > "${dst}"
}

apply_or_dry_run() {
    local manifest="$1"
    local description="$2"

    title "${description}"

    if [[ "${DRY_RUN}" == true ]]; then
        log "Validazione server-side: ${manifest}"
        kubectl "${KUBECTL_ARGS[@]}" apply \
            --dry-run=server \
            -f "${manifest}"
    else
        log "Applicazione: ${manifest}"
        kubectl "${KUBECTL_ARGS[@]}" apply -f "${manifest}"
    fi
}

# ------------------------------------------------------------
# Generazione manifest
# ------------------------------------------------------------
export NAMESPACE
export KIBANA_NAME
export KIBANA_IMAGE
export REPLICAS
export ELASTICSEARCH_SERVICE
export ELASTICSEARCH_IP
export ELASTICSEARCH_PORT
export ELASTICSEARCH_HOSTS
export SERVER_NAME
export SERVER_PUBLICBASEURL
export CREDENTIALS_SECRET
export ELASTICSEARCH_USERNAME
export CA_SECRET
export CA_FILE
export CA_KEY
export KIBANA_SERVICE_PORT
export INGRESS_CLASS
export INGRESS_NAME
export KIBANA_HOST
export INGRESS_TLS_SECRET
export ALB_BACKEND_PROTOCOL
export ALB_CERTIFICATE_ARN
export ALB_GROUP_NAME
export ALB_SCHEME
export ALB_LISTEN_PORTS
export ALB_SUBNETS
export ALB_TARGET_TYPE
export ALB_HEALTHCHECK_PROTOCOL
export ALB_HEALTHCHECK_PORT
export ALB_HEALTHCHECK_PATH
export ALB_SUCCESS_CODES
export NGINX_ANNOTATIONS

DEPLOYMENT_MANIFEST="${WORK_DIR}/01-kibana-deployment.yaml"
KIBANA_SERVICE_MANIFEST="${WORK_DIR}/02-kibana-service.yaml"
ES_SERVICE_MANIFEST="${WORK_DIR}/03-elasticsearch-service.yaml"
ES_ENDPOINTS_MANIFEST="${WORK_DIR}/04-elasticsearch-endpoints.yaml"
INGRESS_MANIFEST="${WORK_DIR}/05-kibana-ingress.yaml"
CREDENTIALS_MANIFEST="${WORK_DIR}/06-kibana-credentials.yaml"
CA_MANIFEST="${WORK_DIR}/07-elasticsearch-ca.yaml"

render_template "${TEMPLATES_DIR}/kibana-deployment.yaml" "${DEPLOYMENT_MANIFEST}"
render_template "${TEMPLATES_DIR}/kibana-service.yaml" "${KIBANA_SERVICE_MANIFEST}"
render_template "${TEMPLATES_DIR}/elasticsearch-service.yaml" "${ES_SERVICE_MANIFEST}"
render_template "${TEMPLATES_DIR}/elasticsearch-endpoints.yaml" "${ES_ENDPOINTS_MANIFEST}"

# ------------------------------------------------------------
# Secret credenziali.
# Generato con kubectl così la password non finisce nel file
# di configurazione. In dry-run viene solo validato.
# ------------------------------------------------------------
kubectl "${KUBECTL_ARGS[@]}" create secret generic "${CREDENTIALS_SECRET}" \
    --namespace "${NAMESPACE}" \
    --from-literal="ELASTICSEARCH_USERNAME=${ELASTICSEARCH_USERNAME}" \
    --from-literal="ELASTICSEARCH_PASSWORD=${ELASTICSEARCH_PASSWORD}" \
    --from-literal="XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY=${ENCRYPTED_SAVED_OBJECTS_KEY}" \
    --from-literal="XPACK_SECURITY_ENCRYPTIONKEY=${SECURITY_ENCRYPTION_KEY}" \
    --from-literal="XPACK_REPORTING_ENCRYPTIONKEY=${REPORTING_ENCRYPTION_KEY}" \
    --dry-run=client \
    -o yaml > "${CREDENTIALS_MANIFEST}"

# ------------------------------------------------------------
# Secret CA.
# Il Secret contiene la chiave tls.crt.
# ------------------------------------------------------------
kubectl "${KUBECTL_ARGS[@]}" create secret generic "${CA_SECRET}" \
    --namespace "${NAMESPACE}" \
    --from-file="${CA_KEY}=${CA_FILE}" \
    --dry-run=client \
    -o yaml > "${CA_MANIFEST}"

# ------------------------------------------------------------
# Generazione Ingress
# ------------------------------------------------------------
generate_nginx_ingress() {
    cat > "${INGRESS_MANIFEST}" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
EOF

    if [[ -n "${NGINX_ANNOTATIONS:-}" ]]; then
        cat >> "${INGRESS_MANIFEST}" <<EOF
  annotations:
${NGINX_ANNOTATIONS}
EOF
    fi

    cat >> "${INGRESS_MANIFEST}" <<EOF
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${KIBANA_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${KIBANA_NAME}
                port:
                  number: ${KIBANA_SERVICE_PORT}
EOF

    if [[ -n "${INGRESS_TLS_SECRET:-}" ]]; then
        cat >> "${INGRESS_MANIFEST}" <<EOF
  tls:
    - hosts:
        - ${KIBANA_HOST}
      secretName: ${INGRESS_TLS_SECRET}
EOF
    fi
}

generate_aws_alb_ingress() {
    if [[ -z "${ALB_CERTIFICATE_ARN:-}" ]]; then
        warn "ALB_CERTIFICATE_ARN non valorizzato."
    fi

    if [[ -z "${ALB_SUBNETS:-}" ]]; then
        warn "ALB_SUBNETS non valorizzato."
    fi

    cat > "${INGRESS_MANIFEST}" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
  annotations:
    alb.ingress.kubernetes.io/certificate-arn: "${ALB_CERTIFICATE_ARN}"
    alb.ingress.kubernetes.io/group.name: "${ALB_GROUP_NAME}"
    alb.ingress.kubernetes.io/scheme: "${ALB_SCHEME}"
    alb.ingress.kubernetes.io/listen-ports: '${ALB_LISTEN_PORTS}'
    alb.ingress.kubernetes.io/subnets: "${ALB_SUBNETS}"
    alb.ingress.kubernetes.io/target-type: "${ALB_TARGET_TYPE}"
    alb.ingress.kubernetes.io/ssl-redirect: "${ALB_SSL_REDIRECT}"
spec:
  ingressClassName: ${INGRESS_CLASS}
  rules:
    - host: ${KIBANA_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${KIBANA_NAME}
                port:
                  number: ${KIBANA_SERVICE_PORT}
EOF
}

case "${INGRESS_CONTROLLER}" in
    nginx)
        generate_nginx_ingress
        ;;
    aws-alb)
        generate_aws_alb_ingress
        ;;
esac

# ------------------------------------------------------------
# Mostra manifest generati
# ------------------------------------------------------------
title "MANIFEST GENERATI"

for manifest in \
    "${CREDENTIALS_MANIFEST}" \
    "${CA_MANIFEST}" \
    "${ES_SERVICE_MANIFEST}" \
    "${ES_ENDPOINTS_MANIFEST}" \
    "${DEPLOYMENT_MANIFEST}" \
    "${KIBANA_SERVICE_MANIFEST}" \
    "${INGRESS_MANIFEST}"
do
    echo
    echo "### ${manifest}"
    echo "------------------------------------------------------------"
    cat "${manifest}"
done

# ------------------------------------------------------------
# Namespace
# ------------------------------------------------------------
title "NAMESPACE"

if [[ "${DRY_RUN}" == true ]]; then
    kubectl "${KUBECTL_ARGS[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1 || {
        warn "Il namespace ${NAMESPACE} non esiste nel cluster."
        warn "Il dry-run server-side dei manifest potrebbe fallire."
    }
else
    if ! kubectl "${KUBECTL_ARGS[@]}" get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        log "Namespace ${NAMESPACE} non presente. Creazione..."
        kubectl "${KUBECTL_ARGS[@]}" create namespace "${NAMESPACE}"
    else
        log "Namespace ${NAMESPACE} già presente."
    fi
fi

# ------------------------------------------------------------
# Apply / dry-run.
#
# Ordine:
# 1. Credentials secret
# 2. CA secret
# 3. Elasticsearch headless service
# 4. Elasticsearch endpoints
# 5. Kibana service
# 6. Kibana deployment
# 7. Ingress
# ------------------------------------------------------------
apply_or_dry_run "${CREDENTIALS_MANIFEST}" "SECRET CREDENZIALI"
apply_or_dry_run "${CA_MANIFEST}" "SECRET ELASTICSEARCH CA"
apply_or_dry_run "${ES_SERVICE_MANIFEST}" "ELASTICSEARCH SERVICE"
apply_or_dry_run "${ES_ENDPOINTS_MANIFEST}" "ELASTICSEARCH ENDPOINTS"
apply_or_dry_run "${KIBANA_SERVICE_MANIFEST}" "KIBANA SERVICE"
apply_or_dry_run "${DEPLOYMENT_MANIFEST}" "KIBANA DEPLOYMENT"
apply_or_dry_run "${INGRESS_MANIFEST}" "KIBANA INGRESS"

# ------------------------------------------------------------
# Verifica finale solo in deploy reale
# ------------------------------------------------------------
if [[ "${DRY_RUN}" == false ]]; then
    title "ROLLOUT KIBANA"

    kubectl "${KUBECTL_ARGS[@]}" rollout status \
        "deployment/${KIBANA_NAME}" \
        --namespace "${NAMESPACE}" \
        --timeout="${ROLLOUT_TIMEOUT}"

    title "STATO FINALE"

    kubectl "${KUBECTL_ARGS[@]}" get deployment \
        "${KIBANA_NAME}" \
        --namespace "${NAMESPACE}"

    echo
    kubectl "${KUBECTL_ARGS[@]}" get pods \
        --namespace "${NAMESPACE}" \
        -l "application=${KIBANA_NAME}" \
        -o wide

    echo
    kubectl "${KUBECTL_ARGS[@]}" get service \
        "${KIBANA_NAME}" \
        --namespace "${NAMESPACE}"

    echo
    kubectl "${KUBECTL_ARGS[@]}" get service \
        "${ELASTICSEARCH_SERVICE}" \
        --namespace "${NAMESPACE}"

    echo
    kubectl "${KUBECTL_ARGS[@]}" get endpoints \
        "${ELASTICSEARCH_SERVICE}" \
        --namespace "${NAMESPACE}"

    echo
    kubectl "${KUBECTL_ARGS[@]}" get ingress \
        "${INGRESS_NAME}" \
        --namespace "${NAMESPACE}"

    title "DEPLOYMENT COMPLETATO"
    log "Kibana: ${SERVER_PUBLICBASEURL}"
else
    title "DRY RUN COMPLETATO"
    log "Nessuna modifica è stata applicata al cluster."
fi

