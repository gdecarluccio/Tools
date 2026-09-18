curl -X PUT -k -u "elastic:ezgCM-kci=BMev1NSfIH" "https://10.50.10.132:9200/k8s-coll-app-hl7-"{000002..000045}"/_settings" \
  -H 'Content-Type: application/json' \
  -d '{
    "index.lifecycle.name": "k8s-coll-hl7-logs-history"
  }'
