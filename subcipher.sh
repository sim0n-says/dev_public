#!/bin/bash

# Nom du script: SubCipher
# Auteur: Simon Bédard
# Date: 2025-02-09
# Description: Script pour gérer des conteneurs/volumes chiffrés avec LUKS en utilisant des clés publiques/privées et une clé Maître.

# Configuration des options Bash
set -e
set -u
set -o pipefail

# Variables globales
MAPPER_NAME=""
MOUNT_POINT=""
KEYS_DIR="$HOME/.secrets"
LOG_FILE="$HOME/log/subcipher.log"
CONTAINER_NAME=""
CONTAINER_PATH=""
CONTAINER_EXT=".vault"  # Nouvelle variable pour l'extension
MOUNT_ROOT="/mnt/vault"

# Fonction pour journaliser les messages
log_message() {
    local message=$1
    local log_dir=$(dirname "$LOG_FILE")
    
    # Créer le répertoire de logs s'il n'existe pas
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 700 "$log_dir"  # Permissions restrictives pour le dossier de logs
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $message" | tee -a "$LOG_FILE"
}

# Fonction pour vérifier l'espace disponible
check_space() {
    local path=$1
    local required_size=$2
    local available_space=$(df --output=avail "$path" | tail -n 1)
    if (( available_space < required_size )); then
        log_message "Erreur : Espace insuffisant pour l'opération."
        exit 1
    fi
}

# Fonction pour créer le fichier conteneur chiffré
create_container() {
    local path=$1
    local name=$2
    local size=$3
    fallocate -l "${size}M" "$path/$name"
    log_message "Fichier conteneur créé à $path/$name avec une taille de $size Mo."
}

# Fonction pour formater le volume LUKS
format_luks() {
    local path=$1
    local name=$2
    local key=$3

    if [ ! -f "$key" ]; then
        log_message "Erreur : Le fichier de clé $key n'existe pas."
        exit 1
    fi

    sudo cryptsetup --batch-mode luksFormat "$path/$name" --key-file "$key"
    log_message "Volume LUKS formaté à $path/$name avec la clé $key."
}

# Fonction pour formater le volume en ext4
format_ext4() {
    local mapper_name=$1
    sudo mkfs.ext4 "/dev/mapper/$mapper_name"
    log_message "Volume $mapper_name formaté en ext4."
}

# Fonction pour ajouter une clé au volume LUKS
add_luks_key() {
    local path=$1
    local name=$2
    local key=$3
    local new_key_file=$4

    if [ ! -f "$key" ]; then
        log_message "Erreur : Le fichier de clé $key n'existe pas."
        exit 1
    fi

    if [ ! -f "$new_key_file" ]; then
        log_message "Erreur : Le fichier de nouvelle clé $new_key_file n'existe pas."
        exit 1
    fi

    sudo cryptsetup luksAddKey --key-file="$key" "$path/$name" "$new_key_file"
    if [ $? -ne 0 ]; then
        log_message "Erreur : Impossible d'ajouter la clé au volume LUKS à $path/$name."
        exit 1
    fi
    log_message "Clé ajoutée au volume LUKS à $path/$name."
}

# Fonction pour supprimer une clé du volume LUKS
remove_luks_key() {
    local path=$1
    local name=$2
    local key=$3

    if [ ! -f "$key" ]; then
        log_message "Erreur : Le fichier de clé $key n'existe pas."
        exit 1
    fi

    sudo cryptsetup luksRemoveKey "$path/$name" --key-file "$key"
    log_message "Clé supprimée du volume LUKS à $path/$name."
}

# Fonction pour ouvrir le volume LUKS
open_luks() {
    local path=$1
    local name=$2
    local key="${3:-$HOME/.secrets/$name/priv/${name}_cle_privee.pem}"

    if [ ! -f "$key" ]; then
        log_message "Erreur : Le fichier de clé $key n'existe pas."
        read -p "Le fichier de clé par défaut n'a pas été trouvé. Veuillez fournir le chemin complet du fichier de clé : " key
        if [ ! -f "$key" ]; then
            log_message "Erreur : Le fichier de clé fourni n'existe pas."
            exit 1
        fi
    fi

    if [ -z "$MAPPER_NAME" ]; then
        MAPPER_NAME="${name}_mapper"
    fi

    # Check if the mapper name already exists and close it if necessary
    if sudo cryptsetup status "$MAPPER_NAME" &>/dev/null; then
        log_message "Le périphérique $MAPPER_NAME existe déjà. Fermeture du périphérique."
        sudo cryptsetup luksClose "$MAPPER_NAME"
    fi

    sudo cryptsetup luksOpen "$path/$name" "$MAPPER_NAME" --key-file "$key"
    if [ $? -ne 0 ]; then
        log_message "Erreur : Impossible d'ouvrir le volume LUKS à $path/$name avec la clé $key."
        exit 1
    fi
    log_message "Volume LUKS ouvert à $path/$name avec la clé $key."
}

# Fonction pour monter le volume LUKS
mount_luks() {
    local mapper_name=$1
    local container_name=$(basename "$mapper_name" _mapper)
    
    # Strip .vault extension properly before creating mount point
    local base_name="${container_name%$CONTAINER_EXT}"
    local mount_point="$MOUNT_ROOT/$base_name"
    
    # Créer le répertoire racine s'il n'existe pas
    if [ ! -d "$MOUNT_ROOT" ]; then
        sudo mkdir -p "$MOUNT_ROOT"
        sudo chown $(whoami):$(whoami) "$MOUNT_ROOT"
        log_message "Répertoire racine $MOUNT_ROOT créé."
    fi

    # Créer le point de montage sans l'extension .vault
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
unmount_luks() {
    local mount_point=$1
    sudo umount "$mount_point"
    log_message "Volume démonté de $mount_point."
}

# Fonction pour fermer le volume LUKS
close_luks() {
    local mapper_name=$1
    sudo cryptsetup luksClose "$mapper_name"
    log_message "Volume $mapper_name fermé."
}

# Fonction pour fermer tous les mappers des volumes .vault
close_all_mappers() {
    echo "Fermeture de tous les mappers .vault..."
    echo "------------------------------------------------"
    
    # Démonter d'abord tous les volumes
    unmount_all_volumes
    
    # Liste tous les conteneurs .vault existants
    find "$HOME" -name "*${CONTAINER_EXT}" | while read vault_file; do
        vault_name=$(basename "$vault_file")
        mapper_name="${vault_name}_mapper"  # Inclut .vault dans le nom du mapper
        
        # Vérifie si le mapper existe
        if sudo cryptsetup status "$mapper_name" &>/dev/null; then
            log_message "Fermeture du mapper: $mapper_name"
            close_luks "$mapper_name"
        fi
    done
    echo "------------------------------------------------"
}

# Fonction pour démonter tous les volumes .vault montés
unmount_all_volumes() {
    echo "Démontage de tous les volumes .vault..."
    echo "------------------------------------------------"
    
    # Find all mounted LUKS mappers
    sudo dmsetup ls --target crypt | while read mapper rest; do
        if [[ "$mapper" == *"_mapper" ]]; then
            mount_point=$(mount | grep "/dev/mapper/$mapper" | awk '{print $3}')
            
            if [ -n "$mount_point" ]; then
                echo "Démontage de $mapper à $mount_point"
                
                # Check for processes using the mount point
                if lsof "$mount_point" >/dev/null 2>&1; then
                    echo "Processus utilisant $mount_point:"
                    lsof "$mount_point"
                    read -p "Forcer le démontage? (y/n): " force
                    if [[ "$force" == "y" ]]; then
                        sudo umount -f "$mount_point"
                    else
                        echo "Démontage annulé pour $mount_point"
                        continue
                    fi
                else
                    sudo umount "$mount_point"
                fi
                
                if [ $? -eq 0 ]; then
                    log_message "Volume démonté avec succès: $mount_point"
                    sudo rmdir "$mount_point" 2>/dev/null
                else
                    log_message "Erreur lors du démontage de $mount_point"
                fi
            fi
        fi
    done
    echo "------------------------------------------------"
}

# Fonction pour créer une paire de clés publique/privée
create_key_pair() {
    local name=$1
    local container_keys_dir="$KEYS_DIR/$name"

    mkdir -p "$container_keys_dir/priv" "$container_keys_dir/pub"

    openssl genpkey -algorithm RSA -out "$container_keys_dir/priv/${name}_cle_privee.pem" -pkeyopt rsa_keygen_bits:2048
    openssl rsa -pubout -in "$container_keys_dir/priv/${name}_cle_privee.pem" -out "$container_keys_dir/pub/${name}_cle_publique.pem"
    log_message "Paire de clés publique/privée créée à $container_keys_dir avec le nom $name."
}

# Fonction pour créer une clé maître
create_master_key() {
    local master_keys_dir="$KEYS_DIR/master"
    mkdir -p "$master_keys_dir/priv" "$master_keys_dir/pub"

    if [ -f "$master_keys_dir/priv/cle_maitre.pem" ]; then
        read -p "La clé maître existe déjà. Voulez-vous la remplacer ? (yes/no) : " RESPONSE
        while [[ -z "$RESPONSE" || ( "$RESPONSE" != "yes" && "$RESPONSE" != "no" ) ]]; do
            read -p "La clé maître existe déjà. Voulez-vous la remplacer ? (yes/no) : " RESPONSE
        done
        if [[ "$RESPONSE" == "no" ]]; then
            log_message "Clé maître existante conservée."
            return
        fi
    fi
    
    # Créer la paire de clés maître sans passphrase
    openssl genpkey -algorithm RSA -out "$master_keys_dir/priv/cle_maitre.pem" -pkeyopt rsa_keygen_bits:4096
    openssl rsa -pubout -in "$master_keys_dir/priv/cle_maitre.pem" -out "$master_keys_dir/pub/cle_maitre_pub.pem"
    
    chmod 600 "$master_keys_dir/priv/cle_maitre.pem"
    chmod 644 "$master_keys_dir/pub/cle_maitre_pub.pem"
    
    log_message "Paire de clés maître créée in $master_keys_dir"
}

# Fonction pour chiffrer un volume avec la clé publique
encrypt_volume() {
    local path=$1
    local name=$2
    local container_keys_dir="$KEYS_DIR/$name"

    openssl rsautl -encrypt -inkey "$container_keys_dir/pub/${name}_cle_publique.pem" -pubin -in "$path/$name" -out "$path/$name.enc"
    log_message "Volume chiffré avec la clé publique $container_keys_dir/pub/${name}_cle_publique.pem."
}

# Fonction pour déchiffrer un volume avec la clé privée
decrypt_volume() {
    local path=$1
    local encrypted_name=$2
    local container_keys_dir="$KEYS_DIR/${encrypted_name%.enc}"

    openssl rsautl -decrypt -inkey "$container_keys_dir/priv/${encrypted_name%.enc}_cle_privee.pem" -in "$path/$encrypted_name" -out "$path/${encrypted_name%.enc}"
    log_message "Volume déchiffré avec la clé privée $container_keys_dir/priv/${encrypted_name%.enc}_cle_privee.pem."
}

# Fonction pour déchiffrer un volume avec la clé maître
decrypt_master() {
    local path=$1
    local encrypted_name=$2
    local master_key="$KEYS_DIR/master/cle_maitre.pem"

    if [ ! -f "$master_key" ]; then
        log_message "Erreur : Le fichier de clé maître $master_key n'existe pas."
        exit 1
    fi

    openssl rsautl -decrypt -inkey "$master_key" -in "$path/$encrypted_name" -out "$path/${encrypted_name%.enc}"
    log_message "Volume déchiffré avec la clé maître $master_key."
}

# Fonction pour ouvrir le volume LUKS avec la clé maître et le monter
open_master() {
    read -p "Nom du fichier conteneur (sans extension) : " CONTAINER_NAME
    CONTAINER_NAME="${CONTAINER_NAME}${CONTAINER_EXT}"
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    MASTER_KEY="$KEYS_DIR/master/priv/cle_maitre.pem"
    
    # Vérifier si la clé maître existe
    if [ ! -f "$MASTER_KEY" ];then
        log_message "Erreur : La clé maître n'existe pas à $MASTER_KEY"
        exit 1
    fi
    
    if [ -z "$MAPPER_NAME" ]; then
        MAPPER_NAME="${CONTAINER_NAME}_mapper"
    fi

    # Fermer le mapper s'il existe déjà
    if sudo cryptsetup status "$MAPPER_NAME" &>/dev/null; then
        log_message "Le périphérique $MAPPER_NAME existe déjà. Fermeture du périphérique."
        sudo cryptsetup luksClose "$MAPPER_NAME"
    fi

    # Utiliser directement la clé maître
    sudo cryptsetup luksOpen "$HOME/$CONTAINER_NAME" "$MAPPER_NAME" --key-file "$MASTER_KEY"
    local STATUS=$?
    
    if [ $STATUS -ne 0 ]; then
        log_message "Erreur : Impossible d'ouvrir le volume avec la clé maître"
        exit 1
    fi
    
    log_message "Volume ouvert avec la clé maître"
    mount_luks "$MAPPER_NAME" "/mnt/$CONTAINER_NAME"
}

# Fonction pour appliquer une nouvelle clé maître sur un conteneur
apply_new_master() {
    read -p "Nom du fichier conteneur (sans extension) : " CONTAINER_NAME
    CONTAINER_NAME="${CONTAINER_NAME}${CONTAINER_EXT}"
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    local master_keys_dir="$KEYS_DIR/master"
    local private_key="$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    local master_key="$master_keys_dir/priv/cle_maitre.pem"

    # Vérifier l'existence des fichiers nécessaires
    if [ ! -f "$master_key" ]; then
        log_message "Erreur : La clé maître n'existe pas à $master_key"
        exit 1
    fi

    if [ ! -f "$private_key" ]; then
        log_message "Erreur : La clé privée n'existe pas à $private_key"
        exit 1
    fi

    # Ouvrir le volume avec la clé privée du conteneur
    log_message "Ouverture du volume avec la clé privée"
    open_luks "$HOME" "$CONTAINER_NAME" "$private_key"

    # Ajouter la clé maître
    log_message "Ajout de la clé maître"
    add_luks_key "$HOME" "$CONTAINER_NAME" "$master_key" "$private_key"

    close_luks "$MAPPER_NAME"
    log_message "Application de la clé maître terminée"
}

# Fonction pour créer le volume
create_volume() {
    read -p "Nom du fichier conteneur (sans extension) : " CONTAINER_NAME
    CONTAINER_NAME="${CONTAINER_NAME}${CONTAINER_EXT}"
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    read -p "Taille du fichier conteneur en Go : " CONTAINER_SIZE_GB
    local CONTAINER_SIZE=$((CONTAINER_SIZE_GB * 1024))

    check_space "$HOME" "$CONTAINER_SIZE"

    create_container "$HOME" "$CONTAINER_NAME" "$CONTAINER_SIZE"
    log_message "Fichier conteneur créé."

    create_key_pair "$CONTAINER_NAME"
    log_message "Paire de clés créée."

    format_luks "$HOME" "$CONTAINER_NAME" "$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    log_message "Volume LUKS formaté."

    open_luks "$HOME" "$CONTAINER_NAME" "$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    log_message "Volume LUKS ouvert."

    format_ext4 "$MAPPER_NAME"
    log_message "Volume formaté en ext4."

    # Ajouter la clé maître au volume avec la clé privée du conteneur
    create_master_key
    log_message "Clé maître créée."

    add_luks_key "$HOME" "$CONTAINER_NAME" "$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem" "$KEYS_DIR/master/priv/cle_maitre.pem"
    log_message "Clé maître ajoutée au volume."

    # Log the MAPPER_NAME and mount point
    log_message "MAPPER_NAME: $MAPPER_NAME"
    log_message "Mount point: /mnt/$CONTAINER_NAME"
    
    # Mount the volume
    log_message "Tentative de montage du volume."
    mount_luks "$MAPPER_NAME" "/mnt/$CONTAINER_NAME"
    log_message "Volume monté."
}

# Fonction pour ouvrir le volume LUKS et le monter
open_volume() {
    read -p "Nom du fichier conteneur (sans extension) : " CONTAINER_NAME
    CONTAINER_NAME="${CONTAINER_NAME}${CONTAINER_EXT}"
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"
    SELECTED_KEY="$KEYS_DIR/$CONTAINER_NAME/priv/${CONTAINER_NAME}_cle_privee.pem"
    open_luks "$HOME" "$CONTAINER_NAME" "$SELECTED_KEY"
    mount_luks "$MAPPER_NAME" "/mnt/$CONTAINER_NAME"
}

# Fonction pour démonter et fermer le volume
unmount_volume() {
    read -p "Nom du volume (sans extension) : " VOLUME_NAME
    MAPPER_NAME="${VOLUME_NAME}_mapper"
    MOUNT_POINT="$MOUNT_ROOT/$VOLUME_NAME"
    unmount_luks "$MOUNT_POINT"
    close_luks "$MAPPER_NAME"
}

# Fonction pour lister les volumes montés (seulement les .vault)
list_mounted() {
    echo "Volumes .vault montés :"
    echo "------------------------------------------------"
    echo "MAPPER | POINT DE MONTAGE | STATUT"
    echo "------------------------------------------------"
    
    # Find all mounted mappers directly
    sudo dmsetup ls --target crypt | while read mapper rest; do
        if [[ "$mapper" == *"_mapper" ]]; then
            # Get mount point if mounted
            mount_point=$(mount | grep "/dev/mapper/$mapper" | awk '{print $3}')
            
            if [ -n "$mount_point" ]; then
                echo "$mapper | $mount_point | Actif, Monté"
                
                # Afficher les détails de montage pour ce mapper
                echo "Détails du mapper:"
                sudo cryptsetup status "$mapper"
                echo "Point de montage:"
                mount | grep "/dev/mapper/$mapper"
                echo "------------------------------------------------"
            fi
        fi
    done
}

# Fonction pour lister les conteneurs avec leurs noms et emplacements
list_containers() {
    echo "Conteneurs disponibles :"
    find "$HOME" -name "*${CONTAINER_EXT}"
}

# Fonction pour lister les clés LUKS d'un volume
list_luks_keys() {
    read -p "Nom du fichier conteneur (sans extension) : " CONTAINER_NAME
    CONTAINER_NAME="${CONTAINER_NAME}${CONTAINER_EXT}"
    CONTAINER_PATH="$HOME/$CONTAINER_NAME"

    if [ ! -f "$CONTAINER_PATH" ]; then
        log_message "Erreur : Le fichier conteneur $CONTAINER_PATH n'existe pas."
        exit 1
    fi

    sudo cryptsetup luksDump "$CONTAINER_PATH"
}

# Fonction pour lister les volumes montés avec leur fichier .vault source
list_mounted_vaults() {
    echo "Volumes .vault montés :"
    echo "------------------------------------------------"
    echo "FICHIER VAULT | MAPPER | POINT DE MONTAGE"
    echo "------------------------------------------------"
    
    # Trouver tous les fichiers .vault
    find "$HOME" -name "*${CONTAINER_EXT}" | while read vault_file; do
        # Obtenir le nom de base du fichier vault (sans le chemin)
        vault_name=$(basename "$vault_file")
        # Nom du mapper correspondant
        mapper_name="${vault_name%${CONTAINER_EXT}}_mapper"
        
        # Vérifier si le mapper existe
        if sudo cryptsetup status "$mapper_name" &>/dev/null; then
            # Trouver le point de montage
            mount_point=$(mount | grep "/dev/mapper/$mapper_name" | awk '{print $3}')
            if [ -n "$mount_point" ]; then
                echo "$vault_file | $mapper_name | $mount_point"
            else
                echo "$vault_file | $mapper_name | Non monté"
            fi
        fi
    done
}

# Fonction pour afficher le menu
show_menu() {
    echo "Choisissez une tâche à exécuter :"
    echo "1) Créer un volume"
    echo "-------------------------------------------------------"
    echo "2) Créer une paire de clés"
    echo "3) Créer une clé maître"
    echo "-------------------------------------------------------"
    echo "4) Chiffrer un volume"
    echo "5) Déchiffrer un volume"
    echo "-------------------------------------------------------"
    echo "6) Ouvrir et monter un volume avec clé privée"
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
}

# Boucle principale
while true; do
    show_menu
    read -p "Entrez le numéro de la tâche (1-16) : " TASK_NUMBER
    
    if ! [[ "$TASK_NUMBER" =~ ^[1-9]$|^1[0-6]$ ]]; then
        echo "Numéro de tâche invalide."
        continue
    fi

    case "$TASK_NUMBER" in
        1)
            create_volume
            ;;
        2)
            read -p "Nom du fichier conteneur : " CONTAINER_NAME
            create_key_pair "$CONTAINER_NAME"
            ;;
        3)
            create_master_key
            ;;
        4)
            read -p "Entrez le chemin du volume à chiffrer : " VOLUME_A_CHIFFRER
            read -p "Entrez le nom du volume à chiffrer : " NOM_VOLUME
            encrypt_volume "$VOLUME_A_CHIFFRER" "$NOM_VOLUME"
            ;;
        5)
            read -p "Entrez le chemin du volume à déchiffrer : " VOLUME_A_DECHIFFRER
            read -p "Entrez le nom du volume chiffré (sans extension .enc) : " NOM_VOLUME_CHIFFRE
            decrypt_volume "$VOLUME_A_DECHIFFRER" "${NOM_VOLUME_CHIFFRE}.enc"
            ;;
        6)
            open_volume
            ;;
        7)
            unmount_volume
            ;;
        8)
            read -p "Entrez le chemin du volume à déchiffrer : " VOLUME_A_DECHIFFRER
            read -p "Entrez le nom du volume chiffré (sans extension .enc) : " NOM_VOLUME_CHIFFRE
            decrypt_master "$VOLUME_A_DECHIFFRER" "${NOM_VOLUME_CHIFFRE}.enc"
            ;;
        9)
            open_master
            ;;
        10)
            apply_new_master
            ;;
        11)
            list_luks_keys
            ;;
        12)
            list_mounted
            ;;
        13)
            list_containers
            ;;
        14)
            unmount_all_volumes
            ;;
        15)
            close_all_mappers
            ;;
        16)
            echo "Au revoir!"
            exit 0
            ;;
        *)
            echo "Numéro de tâche invalide."
            ;;
    esac
    
    echo
    read -p "Appuyez sur Entrée pour continuer..."
    clear
done
