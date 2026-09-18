#!/usr/bin/env bash

# ============================================================
# KIBANA DEPLOYMENT CONFIGURATION
# Modificare SOLO questo file per adattare il deployment
# all'ambiente desiderato.
# ============================================================

# ------------------------------------------------------------
# Kubernetes
# ------------------------------------------------------------
export NAMESPACE="managed-services"

# Facoltativo: lasciare vuoto per usare il context corrente.
# Esempio:
# export KUBE_CONTEXT="rke2-prod"
export KUBE_CONTEXT=""

# ------------------------------------------------------------
# Kibana
# ------------------------------------------------------------
export KIBANA_NAME="kibana"
export KIBANA_IMAGE="docker.elastic.co/kibana/kibana:9.5.2"
export REPLICAS="1"

# ------------------------------------------------------------
# Elasticsearch
# ------------------------------------------------------------
export ELASTICSEARCH_SERVICE="elk-svc"
export ELASTICSEARCH_IP="IP ELASTIC01, IP ELASTIC02, IP ELASTIC03"
export ELASTICSEARCH_PORT="9200"
export ELASTICSEARCH_HOSTS="https://elk-svc:9200"

# ------------------------------------------------------------
# Kibana application settings
# ------------------------------------------------------------
export SERVER_NAME="KIBANA NOME DEL PROGETTO"
export SERVER_PUBLICBASEURL="https://kibana.example.almaviva.it"
export KIBANA_HOST="kibana.example.almaviva.it"

# ------------------------------------------------------------
# Credentials
# La password NON viene memorizzata qui.
# Lo script la richiede a runtime, a meno che sia già presente
# nell'ambiente come KIBANA_ELASTICSEARCH_PASSWORD.
# ------------------------------------------------------------
#export KIBANA_ELASTICSEARCH_PASSWORD=""
export CREDENTIALS_SECRET="kibana-credentials"
export ELASTICSEARCH_USERNAME="kibana_system"

# ------------------------------------------------------------
# Kibana encryption
# ------------------------------------------------------------

# NON inserire la chiave direttamente qui.
# Verrà richiesta a runtime.
#
# Deve essere lunga almeno 32 caratteri.
# export KIBANA_ELASTICSEARCH_PASSWORD=""

# ------------------------------------------------------------
# Elasticsearch CA
# ------------------------------------------------------------
export CA_SECRET="elasticsearch-ca"
export CA_FILE="./certs/ca.crt"

# Nome della chiave del Secret. NON cambiare salvo necessità.
export CA_KEY="tls.crt"

# ------------------------------------------------------------
# Kibana Service
# ------------------------------------------------------------
export KIBANA_SERVICE_PORT="5601"

# ------------------------------------------------------------
# Ingress
#
# Valori supportati:
#   nginx
#   aws-alb
# ------------------------------------------------------------
export INGRESS_CONTROLLER="aws-alb"
export INGRESS_CLASS="alb"
export INGRESS_NAME="kibana-ingress"

# Secret TLS usato da NGINX.
# Se vuoto, il blocco spec.tls NON viene creato.
#
# Esempio:
# export INGRESS_TLS_SECRET="kibana-tls"
export INGRESS_TLS_SECRET=""

# ------------------------------------------------------------
# NGINX annotations
#
# Una lista YAML multilinea.
# Lasciare vuoto se non servono annotation specifiche.
#
# Esempio:
# export NGINX_ANNOTATIONS='
#   nginx.ingress.kubernetes.io/proxy-body-size: "50m"
#   nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
# '
# ------------------------------------------------------------
export NGINX_ANNOTATIONS=""

# ------------------------------------------------------------
# AWS ALB
# Utilizzato SOLO quando:
# export INGRESS_CONTROLLER="aws-alb"
# ------------------------------------------------------------
export ALB_BACKEND_PROTOCOL="HTTPS"
export ALB_CERTIFICATE_ARN="IL TUO ARN"
export ALB_GROUP_NAME="managed-services"
export ALB_SCHEME="internal"
export ALB_LISTEN_PORTS='[{"HTTP":80,"HTTPS":443}]'
export ALB_SUBNETS="subnet-1,subnet-2"
export ALB_TARGET_TYPE="ip"
export ALB_SSL_REDIRECT="443"

# Health check ALB
export ALB_HEALTHCHECK_PROTOCOL="HTTP"
export ALB_HEALTHCHECK_PORT="traffic-port"
export ALB_HEALTHCHECK_PATH="/api/status"
export ALB_SUCCESS_CODES="200"

# ------------------------------------------------------------
# Deployment behaviour
# ------------------------------------------------------------
export ROLLOUT_TIMEOUT="300s"