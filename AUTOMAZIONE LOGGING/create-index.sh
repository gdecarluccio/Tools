#!/bin/bash

if [ $# -eq 10 ]
  then


#VARIABILI INPUT
HTTP=$1
ELASTIC_HOST=$2
USER=$3
PASSWORD=$4
PREFISSO=$5
#LISTA_INDICI="/root/elk-scripts/data-index.txt"
LISTA_INDICI=$6
PRIORITY=$7
SHARD=$8
REPLICA=$9
LIFECYCLE_END=${10}

#VARIABILI
HOME=/root/elk-scripts
CURL_RESULT="$HOME/.curl-result"
LIFECYCLE="$PREFISSO-$LIFECYCLE_END"

echo "###################################################"
echo "HTTP = $HTTP"
echo "ELASTIC_HOST = $ELASTIC_HOST"
echo "USER = $USER"
echo "PASSWORD = $PASSWORD"
echo "PREFISSO = $PREFISSO"
echo "LISTA_INDICI = $LISTA_INDICI"
echo "PRIORITY = $PRIORITY"
echo "SHARD = $SHARD"
echo "REPLICA = $REPLICA"
echo "LIFECYCLE_END = $LIFECYCLE_END"
echo "##################################################"


#PREPARAZIONE FILE

cat $LISTA_INDICI | sort > $LISTA_INDICI.sorted

#ITERAZIONE LISTA IN FILE


while read INDICE; do
  NEW_INDEX=$PREFISSO-$INDICE

echo "---------Elaborazione indice $NEW_INDEX---------"
echo ""
echo "Creazione template $NEW_INDEX -->"
echo ""
#CREAZIONE TEMPLATE
  curl -XPUT -k -u $USER:$PASSWORD "$HTTP://$ELASTIC_HOST:9200/_index_template/$NEW_INDEX" -H 'Content-Type: application/json' -d'
{
  "index_patterns": [
    "'$NEW_INDEX'*"
  ],
  "priority": '$PRIORITY',
  "template": {
    "settings": {

      "index": {
        "lifecycle": {
          "name": "'$LIFECYCLE'",
          "rollover_alias": "'$NEW_INDEX'"
        },
        "number_of_shards": "'$SHARD'",
        "number_of_replicas": "'$REPLICA'"
      }
    },
    "mappings": {
      "dynamic_templates": []
    },
    "aliases": {}
  }
}' | tee $CURL_RESULT

if grep -q "that have the same priority" "$CURL_RESULT"; then
  echo Richiesta priorità maggiore
  echo $INDICE >> "$HOME/$PREFISSO-template-priority-$((100+$PRIORITY))"

else
echo ""
echo "Creazione indice $NEW_INDEX-000001 -->"
echo ""
#CREAZIONE INDICE
  curl -XPUT -k -u $USER:$PASSWORD "$HTTP://$ELASTIC_HOST:9200/$NEW_INDEX-000001"


echo ""
echo "Creazione Alias per indice $NEW_INDEX-000001 -->"
echo ""
#CREAZIONE ALIAS
  curl -XPOST -k -u $USER:$PASSWORD "$HTTP://$ELASTIC_HOST:9200/_aliases" -H 'Content-Type: application/json' -d'
{
  "actions": [
    {
      "add": {
        "index": "'$NEW_INDEX'-000001",
        "alias": "'$NEW_INDEX'",
        "is_write_index": true
      }
    }
  ]
}'
echo ""

fi

done <$LISTA_INDICI.sorted

else
echo "Fornire i seguenti parametri"
echo "http/https"
echo "ELASTIC_HOST"
echo "USER"
echo "PASSWORD"
echo "PREFISSO"
echo "path assoluto alla lista degli indici"
echo "priorità template"
echo "number_of_shards"
echo "number_of_replicas"
echo "parte variabile del nome del lifecycle"

fi