0) Copiare i file su un server con linea di comando kubectl e accesso al cluster designato

1) Creare le secret key
echo "Encrypted Saved Objects:" > SecretKet.txt
openssl rand -base64 48 >> SecretKet.txt
echo "----------------------" >> SecretKet.txt
echo "Security:" >> SecretKet.txt
openssl rand -base64 48 >> SecretKet.txt
echo "----------------------" >> SecretKet.txt
echo "Reporting:" >> SecretKet.txt
openssl rand -base64 48 >> SecretKet.txt

2) Copiare la ca di elastic nella cartella ./certs/ca.crt

3) Configurare i valori relativi alla propria installazione nello script "deploy_kibana_config.sh" 

4) munirsi della password di kibana_system

5) eseguire lo script ./run_deploy_kibana.sh
	verrà richiesto se eseguire lo script in modalità DRY RUN o REALE
        si consiglia di fare la prima esecuzione in modalità DRY RUN
        La modalità reale richiede due conferme.

#################################################
La modalità DRY RUN crea genera i file yaml ed esegue la validazione di questi ultimi