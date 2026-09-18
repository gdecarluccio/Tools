#!/bin/bash

# Parametro: projectId del progetto "system"
SYSTEM_PROJECT_ID="ID-PROGETTO-SYSTEM"  # <-- Cambia questo valore

# Nomi file output
SYSTEM_NS_FILE="infra_namespaces.txt"
CUSTOM_NS_FILE="app_namespaces.txt"

# Pulisce file esistenti
> "$SYSTEM_NS_FILE"
> "$CUSTOM_NS_FILE"

# Recupera tutti i namespace
all_namespaces=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Recupera i namespace del progetto "system"
system_namespaces=$(kubectl get ns -l field.cattle.io/projectId=${SYSTEM_PROJECT_ID} -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Converte in array
readarray -t system_ns_array <<< "$system_namespaces"
readarray -t all_ns_array <<< "$all_namespaces"

# Funzione per rimuovere i "-" dai nomi
clean_name() {
  echo "$1" | tr -d '-'
}

# Scrive i namespace di sistema puliti nel file
for ns in "${system_ns_array[@]}"; do
  clean_ns=$(clean_name "$ns")
  echo "$clean_ns" >> "$SYSTEM_NS_FILE"
done

# Filtra e scrive i namespace non di sistema puliti nel file
for ns in "${all_ns_array[@]}"; do
  if [[ ! " ${system_ns_array[*]} " =~ " $ns " ]]; then
    clean_ns=$(clean_name "$ns")
    echo "$clean_ns" >> "$CUSTOM_NS_FILE"
  fi
done

echo "✅ File creati:"
echo "  - Namespace di sistema: $SYSTEM_NS_FILE"
echo "  - Namespace personalizzati: $CUSTOM_NS_FILE"
