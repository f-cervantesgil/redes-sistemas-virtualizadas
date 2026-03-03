#!/bin/bash

# Practica-05: Automatización de Servidor FTP en Linux (Mageia)
# Objetivo: Instalación de vsftpd y Configuración de permisos con Bind Mounts.

# 1. Instalación e Idempotencia
install_vsftpd() {
    echo "[*] Verificando e Instalando vsftpd..."
    if ! rpm -q vsftpd > /dev/null; then
        urpmi vsftpd --auto
        echo "[+] vsftpd instalado."
    fi
}

# 2. Configuración Base del Sistema
setup_base_env() {
    echo "[*] Inicializando Grupos y Directorios..."
    
    # Crear Grupos
    groupadd -f reprobados
    groupadd -f recursadores
    
    # Directorios de Almacenamiento
    mkdir -p /srv/ftp/general
    mkdir -p /srv/ftp/grupos/reprobados
    mkdir -p /srv/ftp/grupos/recursadores
    
    # Permisos para carpeta General (Anonimo Lectura, Logeados Escritura)
    chmod 777 /srv/ftp/general
    chown -R ftp:ftp /srv/ftp/general
    
    # Permisos Grupos
    chgrp reprobados /srv/ftp/grupos/reprobados
    chgrp recursadores /srv/ftp/grupos/recursadores
    chmod 2770 /srv/ftp/grupos/reprobados
    chmod 2770 /srv/ftp/grupos/recursadores
}

# 3. Configurar vsftpd.conf
config_vsftpd() {
    echo "[*] Configurando vsftpd.conf..."
    cat <<EOF > /etc/vsftpd.conf
# Configuracion Practica 05
listen=NO
listen_ipv6=YES
anonymous_enable=YES
no_anon_password=YES
anon_root=/srv/ftp/general
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/pki/tls/certs/vsftpd.pem
rsa_private_key_file=/etc/pki/tls/private/vsftpd.pem
ssl_enable=NO
EOF
    systemctl restart vsftpd
    systemctl enable vsftpd
}

# 4. Gestión de Usuarios y Bind Mounts
add_ftp_users() {
    read -p "Cuantos usuarios desea crear? " num
    for (( i=1; i<=$num; i++ ))
    do
        read -p "Nombre del usuario $i: " username
        read -s -p "Contraseña para $username: " password
        echo ""
        echo "Seleccione Grupo (1: reprobados, 2: recursadores): "
        read group_opt
        
        target_group="reprobados"
        [[ "$group_opt" == "2" ]] && target_group="recursadores"

        # Crear Usuario si no existe
        if ! id "$username" &>/dev/null; then
            useradd -m -G "$target_group" -s /sbin/nologin "$username"
            echo "$username:$password" | chpasswd
        fi

        # Estructura FTP del usuario (Home Seguro)
        USER_FTP="/home/$username/ftp"
        mkdir -p "$USER_FTP/general"
        mkdir -p "$USER_FTP/$target_group"
        mkdir -p "$USER_FTP/$username"

        # Bind Mounts (Para que aparezcan las 3 carpetas al logear)
        mount --bind /srv/ftp/general "$USER_FTP/general"
        mount --bind "/srv/ftp/grupos/$target_group" "$USER_FTP/$target_group"
        
        # Carpeta personal (espejo para que se vea dentro de su raiz)
        mkdir -p "/srv/ftp/users/$username"
        chown "$username:$target_group" "/srv/ftp/users/$username"
        mount --bind "/srv/ftp/users/$username" "$USER_FTP/$username"

        # Hacer persistentes los montajes (opcional para practica, aqui solo sesion manual)
        echo "[+] Usuario $username configurado en $target_group."
    done
}

# 5. Cambiar Grupo y actualizar montajes
change_group() {
    read -p "Nombre del usuario a cambiar: " username
    if id "$username" &>/dev/null; then
        read -p "Nuevo Grupo (1: reprobados, 2: recursadores): " new_group_opt
        
        new_group="reprobados"
        old_group="recursadores"
        if [[ "$new_group_opt" == "2" ]]; then
            new_group="recursadores"
            old_group="reprobados"
        fi

        # Cambiar grupo en el sistema
        usermod -G "$new_group" "$username"
        
        # Limpiar y actualizar puntos de montaje
        USER_FTP="/home/$username/ftp"
        umount "$USER_FTP/$old_group" 2>/dev/null
        rmdir "$USER_FTP/$old_group" 2>/dev/null
        
        mkdir -p "$USER_FTP/$new_group"
        mount --bind "/srv/ftp/grupos/$new_group" "$USER_FTP/$new_group"
        
        echo "[+] Usuario $username movido a $new_group con exito."
    else
        echo "[-] Usuario no encontrado."
    fi
}

# MENU
clear
echo "--- PRACTICA 05: FTP AUTOMATION (LINUX MAGEIA) ---"
echo "1. Instalacion y Config inicial"
echo "2. Alta Masiva de Usuarios"
echo "3. Cambiar Grupo de Usuario"
echo "4. Salir"
read -p "Opcion: " opt

case $opt in
    1) install_vsftpd; setup_base_env; config_vsftpd ;;
    2) add_ftp_users ;;
    3) change_group ;;
    *) exit 0 ;;
esac
