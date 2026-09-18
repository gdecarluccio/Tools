#!/bin/bash

# Base64 della password
PASSWORD_B64=$(echo -n "PASSWORD UTENTE LOG" | base64)

# IP degli endpoint ELK (modifica se necessario)
ENDPOINT_IPS=("IP-NODO1" "IP-NODO2" "IP-NODO3")

# Lista dei namespace target
namespaces=$(kubectl get ns --no-headers -o custom-columns=":metadata.name")

for ns in $namespaces; do
  echo "Namespace: $ns"

  # 1. Secret
  echo "  - Creazione Secret log-user"
  cat <<EOF | kubectl apply -n "$ns" -f -
apiVersion: v1
kind: Secret
metadata:
  name: log-user
type: Opaque
data:
  password: $PASSWORD_B64
EOF

  # 2. Headless Service
  echo "  - Creazione Service elk-svc"
  cat <<EOF | kubectl apply -n "$ns" -f -
apiVersion: v1
kind: Service
metadata:
  name: elk-svc
spec:
  clusterIP: None
  clusterIPs:
    - None
  internalTrafficPolicy: Cluster
  ipFamilies:
    - IPv4
    - IPv6
  ipFamilyPolicy: RequireDualStack
  ports:
    - name: elk-port
      port: 9200
      protocol: TCP
      targetPort: 9200
  sessionAffinity: None
  type: ClusterIP
EOF

  # 3. Endpoints
  echo "  - Creazione Endpoints elk-svc"
  cat <<EOF | kubectl apply -n "$ns" -f -
apiVersion: v1
kind: Endpoints
metadata:
  name: elk-svc
subsets:
  - addresses:
$(for ip in "${ENDPOINT_IPS[@]}"; do echo "      - ip: $ip"; done)
    ports:
      - port: 9200
        protocol: TCP
EOF

done

