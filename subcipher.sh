#!/bin/bash

# Nom du script: SubCipher
# Auteur: Simon Bédard
# Date: 2025-02-09
# Description: Script pour gérer des volumes chiffrés avec LUKS en utilisant des clés publiques/privées et une clé Maître.

#inDev

# Configuration des options Bash
set -e
set -u
set -o pipefail

# Variables globales
MAPPER_NAME=""
MOUNT_POINT=""
KEYS_DIR="$HOME/.secrets"
LOG_FILE="$HOME/red_october.log"
CONTAINER_NAME=""
CONTAINER_PATH=""
MASTER_KEY_PASSPHRASE_FILE="$HOME/.secrets/master/master_key_passphrase.txt"

# Fonction pour journaliser les messages
log_message() {
    local message=$1
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $message" | tee -a "$LOG_FILE"
}

# Fonction pour vérifier l'espace disponible
verifier_espace_disponible() {
    local chemin=$1
    local taille_necessaire=$2
    local espace_disponible=$(df --output=avail "$chemin" | tail -n 1)
    if (( espace_disponible < taille_necessaire )); then
        log_message "Erreur : Espace insuffisant pour l'opération."
        exit 1
    fi
}

# Fonction pour créer le fichier conteneur chiffré
creer_fichier_conteneur() {
    local chemin=$1
    local nom=$2
    local taille=$3
    fallocate -l "${taille}M" "$chemin/$nom"
    log_message "Fichier conteneur créé à $chemin/$nom avec une taille de $taille Mo."
}

# Fonction pour formater le volume LUKS
formater_volume_luks() {
    local chemin=$1
    local nom=$2
    local cle=$3

    if [ ! -f "$cle" ]; then
        log_message "Erreur : Le fichier de clé $cle n'existe pas."
        exit 1
    fi

    sudo cryptsetup --batch-mode luksFormat "$chemin/$nom" --key-file "$cle"
    log_message "Volume LUKS formaté à $chemin/$nom avec la clé $cle."
}

# Fonction pour formater le volume en ext4
formater_volume_ext4() {
    local mapper_name=$1
    sudo mkfs.ext4 "/dev/mapper/$mapper_name"
    log_message "Volume $mapper_name formaté en ext4."
}

# Fonction pour ajouter une clé au volume LUKS
ajouter_cle_luks() {
    local chemin=$1
    local nom=$2
    local cle=$3
    local new_key_file=$4

    if [ ! -f "$cle" ]; then
        log_message "Erreur : Le fichier de clé $cle n'existe pas."
        exit 1
    fi

    if [ ! -f "$new_key_file" ]; then
        log_message "Erreur : Le fichier de nouvelle clé $new_key_file n'existe pas."
        exit 1
    fi

    sudo cryptsetup luksAddKey "$chemin/$nom" --key-file "$cle" < "$new_key_file"
    if [ $? -ne 0 ]; then
        log_message "Erreur : Impossible d'ajouter la clé au volume LUKS à $chemin/$nom."
        exit 1
    fi
    log_message "Clé ajoutée au volume LUKS à $chemin/$nom."
}

# Fonction pour supprimer une clé du volume LUKS
supprimer_cle_luks() {
    local chemin=$1
    local nom=$2
    local cle=$3

    if [ ! -f "$cle" ]; then
        log_message "Erreur : Le fichier de clé $cle n'existe pas."
        exit 1
    fi

    sudo cryptsetup luksRemoveKey "$chemin/$nom" --key-file "$cle"
    log_message "Clé supprimée du volume LUKS à $chemin/$nom."
}

# Fonction pour ouvrir le volume LUKS
ouvrir_volume_luks() {
    local chemin=$1
    local nom=$2
    local cle="${3:-$HOME/.secrets/$nom/priv/${nom}_cle_privee.pem}"

    if [ ! -f "$cle" ]; then
        log_message "Erreur : Le fichier de clé $cle n'existe pas."
        read -p "Le fichier de clé par défaut n'a pas été trouvé. Veuillez fournir le chemin complet du fichier de clé : " cle
        if [ ! -f "$cle" ]; then
            log_message "Erreur : Le fichier de clé fourni n'existe pas."
            exit 1
        fi
    fi

    if [ -z "$MAPPER_NAME" ]; then
        MAPPER_NAME="${nom}_mapper"
    fi

    # Check if the mapper name already exists and close it if necessary
    if sudo cryptsetup status "$MAPPER_NAME" &>/dev/null; then
        log_message "Le périphérique $MAPPER_NAME existe déjà. Fermeture du périphérique."
        sudo cryptsetup luksClose "$MAPPER_NAME"
    fi

    sudo cryptsetup luksOpen "$chemin/$nom" "$MAPPER_NAME" --key-file "$cle"
    if [ $? -ne 0 ]; then
        log_message "Erreur : Impossible d'ouvrir le volume LUKS à $chemin/$nom avec la clé $cle."
        exit 1
    fi
    log_message "Volume LUKS ouvert à $chemin/$nom avec la clé $cle."
}

# Fonction pour monter le volume LUKS
monter_volume_luks() {
    local mapper_name=$1
    local mount_point=$2
    log_message "Attempting to mount volume $mapper_name at $mount_point"
    if [ ! -d "$mount_point" ]; then
        sudo mkdir -p "$mount_point"
        log_message "Répertoire de montage $mount_point créé."
    fi
    sudo mount "/dev/mapper/$mapper_name" "$mount_point"
    if [ $? -ne 0 ]; then
        log_message "Erreur : Impossible de monter le volume $mapper_name à $mount_point."
        exit 1
    fi
    sudo chown -R $(whoami):$(whoami) "$mount_point"
    log_message "Volume $mapper_name monté à $mount_point."
}

# Fonction pour démonter le volume LUKS
demonter_volume_luks() {
    local mount_point=$1
    sudo umount "$mount_point"
    log_message "Volume démonté de $mount_point."
}

# Fonction pour fermer le volume LUKS
fermer_volume_luks() {
    local mapper_name=$1
    sudo cryptsetup luksClose "$mapper_name"
    log_message "Volume $mapper_name fermé."
}

# Fonction pour fermer tous les mappers ouverts
fermer_tous_les_mappers() {
    local mappers=$(ls /dev/mapper | grep -v "control")
    for mapper in $mappers; do
        log_message "Fermeture du mapper $mapper"
        sudo cryptsetup luksClose "$mapper"
        if [ $? -eq 0 ]; then
            log_message "Mapper $mapper fermé avec succès."
        else
            log_message "Erreur lors de la fermeture du mapper $mapper."
        fi
    done
}

# Fonction pour démonter tous les volumes montés
demonter_tous_les_volumes() {
    local mappers=$(ls /dev/mapper | grep -v "control")
    for mapper in $mappers; do
        local mount_point=$(mount | grep "/dev/mapper/$mapper" | awk '{print $3}')
        if [ -n "$mount_point" ]; then
            log_message "Démontage du volume $mapper de $mount_point"
            sudo umount "$mount_point"
            if [ $? -eq 0 ]; then
                log_message "Volume $mapper démonté de $mount_point avec succès."
            else
                log_message "Erreur lors du démontage du volume $mapper de $mount_point."
            fi
        fi
    done
}

# Fonction pour créer une paire de clés publique/privée
creer_paire_cles() {
    local nom=$1
    local container_keys_dir="$KEYS_DIR/$nom"

    mkdir -p "$container_keys_dir/priv" "$container_keys_dir/pub"

    openssl genpkey -algorithm RSA -out "$container_keys_dir/priv/${nom}_cle_privee.pem" -pkeyopt rsa_keygen_bits:2048
    openssl rsa -pubout -in "$container_keys_dir/priv/${nom}_cle_privee.pem" -out "$container_keys_dir/pub/${nom}_cle_publique.pem"
    log_message "Paire de clés publique/privée créée à $container_keys_dir avec le nom $nom."
}

# Fonction pour créer une clé maître
creer_cle_maitre() {
    local master_keys_dir="$KEYS_DIR/master"

    if [ -f "$master_keys_dir/cle_maitre.pem" ]; then
        read -p "La clé maître existe déjà. Voulez-vous la remplacer ? (yes/no) : " REPONSE
        while [[ -z "$REPONSE" || ( "$REPONSE" != "yes" && "$REPONSE" != "no" ) ]]; do
            read -p "La clé maître existe déjà. Voulez-vous la remplacer ? (yes/no) : " REPONSE
        done
        if [[ "$REPONSE" == "no" ]]; then
            log_message "Clé maître existante conservée."
            return
        fi
    fi

    openssl genpkey -algorithm RSA -out "$master_keys_dir/cle_maitre.pem" -pkeyopt rsa_keygen_bits:2048
    log_message "Clé maître créée à $master_keys_dir/cle_maitre.pem."
}

# Fonction pour chiffrer un volume avec la clé publique
chiffrer_volume() {
    local chemin=$1
    local nom=$2
    local container_keys_dir="$KEYS_DIR/$nom"

    openssl rsautl -encrypt -inkey "$container_keys_dir/pub/${nom}_cle_publique.pem" -pubin -in "$chemin/$nom" -out "$chemin/$nom.enc"
    log_message "Volume chiffré avec la clé publique $container_keys_dir/pub/${nom}_cle_publique.pem."
}

# Fonction pour déchiffrer un volume avec la clé privée
dechiffrer_volume() {
    local chemin=$1
    local nom_chiffre=$2
    local container_keys_dir="$KEYS_DIR/${nom_chiffre%.enc}"

    openssl rsautl -decrypt -inkey "$container_keys_dir/priv/${nom_chiffre%.enc}_cle_privee.pem" -in "$chemin/$nom_chiffre" -out "$chemin/${nom_chiffre%.enc}"
    log_message "Volume déchiffré avec la clé privée $container_keys_dir/priv/${nom_chiffre%.enc}_cle_privee.pem."
}

# Fonction pour déchiffrer un volume avec la clé maître
dechiffrer_volume_maitre() {
    local chemin=$1
    local nom_chiffre=$2
    local master_key="$KEYS_DIR/master/cle_maitre.pem"

    if [ ! -f "$master_key" ]; then
        log_message "Erreur : Le fichier de clé maître $master_key n'existe pas."
        exit 1
    fi

    openssl rsautl -decrypt -inkey "$master_key" -in "$chemin/$nom_chiffre" -out "$chemin/${nom_chiffre%.enc}"
    log_message "Volume déchiffré avec la clé maître $master_key."
}

# Fonction pour ouvrir le volume LUKS avec la clé maître et le monter
ouvrir_volume_maitre() {
    read -p "Nom du fichier conteneur : " CONTAINER_NAME
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    CLE_CHOISIE="$KEYS_DIR/master/cle_maitre.pem"
    ouvrir_volume_luks "$HOME" "$CONTAINER_NAME" "$CLE_CHOISIE"
    monter_volume_luks "$MAPPER_NAME" "/mnt/$CONTAINER_NAME"
}

# Fonction pour appliquer une nouvelle clé maître sur un conteneur
appliquer_nouvelle_cle_maitre() {
    read -p "Nom du fichier conteneur : " CONTAINER_NAME
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    local master_keys_dir="$KEYS_DIR/master"
    local new_master_key="$master_keys_dir/cle_maitre_nouvelle.pem"
    local old_master_key="$master_keys_dir/cle_maitre.pem"

    # Créer une nouvelle clé maître
    openssl genpkey -algorithm RSA -out "$new_master_key" -pkeyopt rsa_keygen_bits:2048
    log_message "Nouvelle clé maître créée à $new_master_key."

    # Ajouter la nouvelle clé maître au volume
    ouvrir_volume_luks "$HOME" "$CONTAINER_NAME" "$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    ajouter_cle_luks "$HOME" "$CONTAINER_NAME" "$new_master_key" "$MASTER_KEY_PASSPHRASE_FILE"

    # Supprimer l'ancienne clé maître du volume
    log_message "Tentative de suppression de l'ancienne clé maître du volume."
    supprimer_cle_luks "$HOME" "$CONTAINER_NAME" "$old_master_key"
    if [ $? -eq 0 ]; then
        log_message "Ancienne clé maître supprimée avec succès du volume."
    else
        log_message "Erreur lors de la suppression de l'ancienne clé maître du volume."
    fi
    fermer_volume_luks "$MAPPER_NAME"

    # Remplacer l'ancienne clé maître par la nouvelle
    mv "$new_master_key" "$old_master_key"
    log_message "Clé maître remplacée par la nouvelle clé à $old_master_key."
}

# Fonction pour créer le volume
creer_volume() {
    read -p "Nom du fichier conteneur : " CONTAINER_NAME
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    read -p "Taille du fichier conteneur en Go : " CONTAINER_SIZE_GB
    local CONTAINER_SIZE=$((CONTAINER_SIZE_GB * 1024))

    verifier_espace_disponible "$HOME" "$CONTAINER_SIZE"

    creer_fichier_conteneur "$HOME" "$CONTAINER_NAME" "$CONTAINER_SIZE"
    log_message "Fichier conteneur créé."

    creer_paire_cles "$CONTAINER_NAME"
    log_message "Paire de clés créée."

    formater_volume_luks "$HOME" "$CONTAINER_NAME" "$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    log_message "Volume LUKS formaté."

    ouvrir_volume_luks "$HOME" "$CONTAINER_NAME" "$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    log_message "Volume LUKS ouvert."

    formater_volume_ext4 "$MAPPER_NAME"
    log_message "Volume formaté en ext4."

    # Ajouter la clé maître au volume
    creer_cle_maitre
    log_message "Clé maître créée."

    ajouter_cle_luks "$HOME" "$CONTAINER_NAME" "$KEYS_DIR/master/cle_maitre.pem" "$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    log_message "Clé maître ajoutée au volume."

    # Log the MAPPER_NAME and mount point
    log_message "MAPPER_NAME: $MAPPER_NAME"
    log_message "Mount point: /mnt/$CONTAINER_NAME"
    
    # Mount the volume
    log_message "Tentative de montage du volume."
    ouvrir_volume "$MAPPER_NAME" "/mnt/$CONTAINER_NAME"
    log_message "Volume monté."
}

# Fonction pour ouvrir le volume LUKS et le monter
ouvrir_volume() {
    read -p "Nom du fichier conteneur : " CONTAINER_NAME
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    CLE_CHOISIE="$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    ouvrir_volume_luks "$HOME" "$CONTAINER_NAME" "$CLE_CHOISIE"
    monter_volume_luks "$MAPPER_NAME" "/mnt/$CONTAINER_NAME"
}

# Fonction pour démonter et fermer le volume
demonter_volume() {
    read -p "Nom du volume (MAPPER_NAME) : " MAPPER_NAME
    MOUNT_POINT="/mnt/$MAPPER_NAME"
    demonter_volume_luks "$MOUNT_POINT"
    fermer_volume_luks "$MAPPER_NAME"
}

# Fonction pour lister les volumes montés
lister_volumes_montes() {
    echo "Volumes montés :"
    mount | grep "/dev/mapper"
}

# Fonction pour lister les conteneurs avec leurs noms et emplacements
lister_conteneurs() {
    echo "Conteneurs disponibles :"
    find "$HOME" -name "*.img" -o -name "*.enc"
}

# Fonction pour lister les clés LUKS d'un volume
lister_cles_luks() {
    read -p "Nom du fichier conteneur : " CONTAINER_NAME
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"

    if [ ! -f "$CONTAINER_PATH" ]; then
        log_message "Erreur : Le fichier conteneur $CONTAINER_PATH n'existe pas."
        exit 1
    fi

    sudo cryptsetup luksDump "$CONTAINER_PATH"
}

# Afficher le menu et demander à l'utilisateur de choisir une tâche
# Afficher le menu et demander à l'utilisateur de choisir une tâche
echo "Choisissez une tâche à exécuter :"
echo "1) Créer un volume"
echo "-------------------------------------------------------"
echo "2) Créer une paire de clés"
echo "3) Créer une clé maître"
echo "-------------------------------------------------------"
echo "4) Chiffrer un volume"
echo "5) Déchiffrer un volume"
echo "-------------------------------------------------------"
echo "6) Déchifrer et monter un volume"
echo "7) Démonter un volume"
echo "-------------------------------------------------------"
echo "8) Déchiffrer et monter un volume avec la clé maître"
echo "9) Ouvrir et monter un volume avec la clé maître"
echo "10) Appliquer une nouvelle clé maître sur un conteneur"
echo "-------------------------------------------------------"
echo "11) Lister les clés LUKS d'un volume"
echo "12) Lister les volumes montés"
echo "13) Lister les conteneurs disponibles"
echo "-------------------------------------------------------"
echo "14) Démonter tous les volumes"
echo "15) Fermer tous les mappers"
echo "16) Quitter"
read -p "Entrez le numéro de la tâche (1-16) : " TASK_NUMBER
if ! [[ "$TASK_NUMBER" =~ ^[1-9]$|^1[0-6]$ ]]; then
    echo "Numéro de tâche invalide."
    exit 1
fi

case "$TASK_NUMBER" in
    1)
        creer_volume
        ;;
    2)
        read -p "Nom du fichier conteneur : " CONTAINER_NAME
        creer_paire_cles "$CONTAINER_NAME"
        ;;
    3)
        creer_cle_maitre
        ;;
    4)
        read -p "Entrez le chemin du volume à chiffrer : " VOLUME_A_CHIFFRER
        read -p "Entrez le nom du volume à chiffrer : " NOM_VOLUME
        chiffrer_volume "$VOLUME_A_CHIFFRER" "$NOM_VOLUME"
        ;;
    5)
        read -p "Entrez le chemin du volume à déchiffrer : " VOLUME_A_DECHIFFRER
        read -p "Entrez le nom du volume chiffré (sans extension .enc) : " NOM_VOLUME_CHIFFRE
        dechiffrer_volume "$VOLUME_A_DECHIFFRER" "${NOM_VOLUME_CHIFFRE}.enc"
        ;;
    6)
        ouvrir_volume
        ;;
    7)
        demonter_volume
        ;;
    8)
        read -p "Entrez le chemin du volume à déchiffrer : " VOLUME_A_DECHIFFRER
        read -p "Entrez le nom du volume chiffré (sans extension .enc) : " NOM_VOLUME_CHIFFRE
        dechiffrer_volume_maitre "$VOLUME_A_DECHIFFRER" "${NOM_VOLUME_CHIFFRE}.enc"
        ;;
    9)
        ouvrir_volume_maitre
        ;;
    10)
        appliquer_nouvelle_cle_maitre
        ;;
    11)
        lister_cles_luks
        ;;
    12)
        lister_volumes_montes
        ;;
    13)
        lister_conteneurs
        ;;
    14)
        demonter_tous_les_volumes
        ;;
    15)
        fermer_tous_les_mappers
        ;;
    16)
        echo "Quitter."
        exit 0
        ;;
    *)
        echo "Numéro de tâche invalide."
        exit 1
        ;;
esac
