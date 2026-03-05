#!/bin/bash

# ============================================================
#  Practica-05: Servidor FTP con vsftpd
# ============================================================


# 0. Verificar Root
if [[ $EUID -ne 0 ]]; then
   echo "[-] Este script debe ejecutarse como root (use sudo)."
   exit 1
fi

# ============================================================
# 1. Instalacion de vsftpd
# ============================================================
install_vsftpd() {
    echo "[*] Verificando e Instalando vsftpd..."
    if ! rpm -q vsftpd > /dev/null 2>&1; then
        echo "[*] Sincronizando repositorios..."
        urpmi.update -a
        urpmi vsftpd --auto
        if [ $? -ne 0 ]; then
            echo "[-] ERROR: No se pudo instalar vsftpd."
            return 1
        fi
        echo "[+] vsftpd instalado exitosamente."
    else
        echo "[!] vsftpd ya esta instalado."
    fi

    # Registrar /sbin/nologin como shell valido (evita error 530)
    if ! grep -q "/sbin/nologin" /etc/shells; then
        echo "/sbin/nologin" >> /etc/shells
        echo "[+] /sbin/nologin agregado a /etc/shells."
    fi
}

# ============================================================
# 2. Configuracion Base (Grupos, Directorios, Permisos)
# ============================================================
setup_base_env() {
    echo "[*] Inicializando Grupos y Directorios..."

    # Crear Grupos
    groupadd -f reprobados
    groupadd -f recursadores
    groupadd -f ftp_users   # Grupo comun para todos los usuarios FTP

    # ---- Estructura de Carpetas ----
    # /srv/ftp/publica         -> Carpeta compartida (todos leen/escriben)
    # /srv/ftp/grupos/reprobados   -> Solo miembros del grupo
    # /srv/ftp/grupos/recursadores -> Solo miembros del grupo
    # /srv/ftp/personal/<user>     -> Carpeta privada de cada usuario
    # /srv/ftp/users/<user>/       -> Home FTP (bind mounts aqui)
    mkdir -p /srv/ftp/publica
    mkdir -p /srv/ftp/grupos/reprobados
    mkdir -p /srv/ftp/grupos/recursadores
    mkdir -p /srv/ftp/personal
    mkdir -p /srv/ftp/users

    # Carpeta para usuario anonimo (ve todo en solo lectura)
    mkdir -p /srv/ftp/anonymous
    mkdir -p /srv/ftp/anonymous/publica
    mkdir -p /srv/ftp/anonymous/reprobados
    mkdir -p /srv/ftp/anonymous/recursadores

    # Permisos: publica -> todos leen y escriben
    chown root:ftp_users /srv/ftp/publica
    chmod 777 /srv/ftp/publica

    # Permisos: grupos -> solo miembros del grupo pueden leer/escribir
    # SGID (2) para que archivos nuevos hereden el grupo
    chown root:reprobados /srv/ftp/grupos/reprobados
    chmod 2775 /srv/ftp/grupos/reprobados

    chown root:recursadores /srv/ftp/grupos/recursadores
    chmod 2775 /srv/ftp/grupos/recursadores

    # Bind mounts para anonimo (solo lectura)
    if ! mountpoint -q /srv/ftp/anonymous/publica 2>/dev/null; then
        mount --bind /srv/ftp/publica /srv/ftp/anonymous/publica
        mount -o remount,ro,bind /srv/ftp/anonymous/publica
    fi
    if ! mountpoint -q /srv/ftp/anonymous/reprobados 2>/dev/null; then
        mount --bind /srv/ftp/grupos/reprobados /srv/ftp/anonymous/reprobados
        mount -o remount,ro,bind /srv/ftp/anonymous/reprobados
    fi
    if ! mountpoint -q /srv/ftp/anonymous/recursadores 2>/dev/null; then
        mount --bind /srv/ftp/grupos/recursadores /srv/ftp/anonymous/recursadores
        mount -o remount,ro,bind /srv/ftp/anonymous/recursadores
    fi
    chown root:root /srv/ftp/anonymous
    chmod 555 /srv/ftp/anonymous

    # Abrir Firewall
    echo "[*] Abriendo puertos en el Firewall..."
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=ftp 2>/dev/null
        firewall-cmd --permanent --add-port=40000-40100/tcp 2>/dev/null
        firewall-cmd --reload 2>/dev/null
    else
        iptables -A INPUT -p tcp --dport 21 -j ACCEPT 2>/dev/null
        iptables -A INPUT -p tcp --dport 20 -j ACCEPT 2>/dev/null
        iptables -A INPUT -p tcp --dport 40000:40100 -j ACCEPT 2>/dev/null
    fi
    echo "[+] Entorno base configurado."
}

# ============================================================
# 3. Configurar vsftpd.conf
# ============================================================
config_vsftpd() {
    # Detectar la IP de la LAN para el modo pasivo
    LAN_IP=$(hostname -I | awk '{print $1}')
    echo "[*] Configurando vsftpd.conf (IP PASV: $LAN_IP)..."
    mkdir -p /var/run/vsftpd/empty

    # Crear el contenido base
    cat <<'VSFTPD_EOF' > /etc/vsftpd.conf
# ================================================
# vsftpd.conf - Practica 05
# ================================================
listen=YES
listen_ipv6=NO

# --- Acceso Anonimo (Solo Lectura) ---
anonymous_enable=YES
anon_root=/srv/ftp/anonymous
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# --- Usuarios Locales ---
local_enable=YES
write_enable=YES
local_umask=002
file_open_mode=0775

# --- Chroot (Aislar usuarios en su carpeta) ---
chroot_local_user=YES
allow_writeable_chroot=YES
local_root=/srv/ftp/users/$USER
user_sub_token=$USER

# --- Autenticacion ---
pam_service_name=vsftpd
check_shell=NO

# --- Modo Pasivo (Para FileZilla) ---
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100

# --- Logging ---
xferlog_enable=YES
dirmessage_enable=YES
use_localtime=YES
connect_from_port_20=YES

# --- Seguridad ---
secure_chroot_dir=/var/run/vsftpd/empty
ssl_enable=NO
VSFTPD_EOF

    # Agregar la IP detectada para corregir el error de FileZilla (PASV)
    echo "pasv_address=$LAN_IP" >> /etc/vsftpd.conf

    # Copiar a la otra ruta posible si existe
    if [ -d "/etc/vsftpd" ]; then
        cp /etc/vsftpd.conf /etc/vsftpd/vsftpd.conf
    fi

    systemctl restart vsftpd
    systemctl enable vsftpd
    echo "[+] vsftpd configurado y reiniciado con pasv_address=$LAN_IP."
    echo "[*] Estado del servicio:"
    systemctl is-active vsftpd
}

# ============================================================
# 4. Alta Masiva de Usuarios
# ============================================================
add_ftp_users() {
    read -p "Cuantos usuarios desea crear? " num

    for (( i=1; i<=$num; i++ )); do
        read -p "Nombre del usuario $i: " username
        read -s -p "Contrasena para $username: " password
        echo ""

        echo "Grupo (1: reprobados, 2: recursadores): "
        read group_opt

        target_group="reprobados"
        [[ "$group_opt" == "2" ]] && target_group="recursadores"

        # Crear usuario si no existe
        if ! id "$username" &>/dev/null; then
            useradd -m -G "$target_group,ftp_users" -s /sbin/nologin "$username"
            echo "$username:$password" | chpasswd
            echo "[+] Usuario $username creado."
        else
            echo "[!] El usuario $username ya existe. Actualizando grupos..."
            usermod -a -G "$target_group,ftp_users" "$username"
            echo "$username:$password" | chpasswd
        fi

        # ---- Estructura FTP del Usuario ----
        # /srv/ftp/users/<user>/publica      -> bind mount a /srv/ftp/publica
        # /srv/ftp/users/<user>/<grupo>       -> bind mount a /srv/ftp/grupos/<grupo>
        # /srv/ftp/users/<user>/personal      -> bind mount a /srv/ftp/personal/<user>
        USER_FTP="/srv/ftp/users/$username"
        mkdir -p "$USER_FTP"
        chown root:root "$USER_FTP"
        chmod 755 "$USER_FTP"

        # Carpeta publica
        mkdir -p "$USER_FTP/publica"
        if ! mountpoint -q "$USER_FTP/publica" 2>/dev/null; then
            mount --bind /srv/ftp/publica "$USER_FTP/publica"
        fi

        # Carpeta de grupo
        mkdir -p "$USER_FTP/$target_group"
        if ! mountpoint -q "$USER_FTP/$target_group" 2>/dev/null; then
            mount --bind "/srv/ftp/grupos/$target_group" "$USER_FTP/$target_group"
        fi

        # Carpeta personal
        mkdir -p "/srv/ftp/personal/$username"
        chown "$username:$target_group" "/srv/ftp/personal/$username"
        chmod 700 "/srv/ftp/personal/$username"
        mkdir -p "$USER_FTP/personal"
        if ! mountpoint -q "$USER_FTP/personal" 2>/dev/null; then
            mount --bind "/srv/ftp/personal/$username" "$USER_FTP/personal"
        fi

        echo "[+] Usuario $username -> grupo: $target_group (3 carpetas: publica, $target_group, personal)"
    done
}

# ============================================================
# 5. Cambiar Grupo de Usuario
# ============================================================
change_group() {
    read -p "Nombre del usuario a cambiar: " username
    if ! id "$username" &>/dev/null; then
        echo "[-] Usuario no encontrado."
        return
    fi

    read -p "Nuevo Grupo (1: reprobados, 2: recursadores): " new_group_opt
    new_group="reprobados"
    old_group="recursadores"
    if [[ "$new_group_opt" == "2" ]]; then
        new_group="recursadores"
        old_group="reprobados"
    fi

    # Cambiar grupo en el sistema (mantener ftp_users)
    gpasswd -d "$username" "$old_group" 2>/dev/null
    usermod -a -G "$new_group,ftp_users" "$username"

    USER_FTP="/srv/ftp/users/$username"

    # Desmontar carpeta del grupo viejo
    if mountpoint -q "$USER_FTP/$old_group" 2>/dev/null; then
        umount -l "$USER_FTP/$old_group"
    fi
    rmdir "$USER_FTP/$old_group" 2>/dev/null

    # Montar carpeta del grupo nuevo
    mkdir -p "$USER_FTP/$new_group"
    if ! mountpoint -q "$USER_FTP/$new_group" 2>/dev/null; then
        mount --bind "/srv/ftp/grupos/$new_group" "$USER_FTP/$new_group"
    fi

    echo "[+] $username movido de $old_group a $new_group."
    echo "[*] Ahora ve: publica, $new_group, personal"
}

# ============================================================
# 6. Eliminar Usuario
# ============================================================
delete_user() {
    read -p "Nombre del usuario a eliminar: " username
    if ! id "$username" &>/dev/null; then
        echo "[-] Usuario no encontrado."
        read -p "Presione Enter para continuar..."
        return
    fi

    echo "[*] Eliminando usuario $username..."
    USER_FTP="/srv/ftp/users/$username"

    # Desmontar todo lo que este dentro de su carpeta FTP
    umount -l "$USER_FTP/publica" 2>/dev/null
    umount -l "$USER_FTP/reprobados" 2>/dev/null
    umount -l "$USER_FTP/recursadores" 2>/dev/null
    umount -l "$USER_FTP/personal" 2>/dev/null

    # Eliminar usuario del sistema y su home
    userdel -r "$username" 2>/dev/null

    # Limpiar carpetas FTP
    rm -rf "$USER_FTP"
    rm -rf "/srv/ftp/personal/$username"

    echo "[+] Usuario $username eliminado correctamente."
    read -p "Presione Enter para continuar..."
}

# ============================================================
# 7. Listar Usuarios Registrados
# ============================================================
list_registered_users() {
    echo ""
    echo "[*] USUARIOS REGISTRADOS EN EL SISTEMA FTP"
    echo "------------------------------------------"

    found=0
    for group in reprobados recursadores; do
        members=$(getent group "$group" | cut -d: -f4 | tr ',' ' ')
        for user in $members; do
            if [ ! -z "$user" ]; then
                if [ $found -eq 0 ]; then
                    printf "%-20s %-20s\n" "USUARIO" "GRUPO"
                    printf "%-20s %-20s\n" "-------" "-----"
                    found=1
                fi
                printf "%-20s %-20s\n" "$user" "$group"
            fi
        done
    done

    if [ $found -eq 0 ]; then
        echo "[!] No hay usuarios registrados."
    fi
    echo "------------------------------------------"
    read -p "Presione Enter para continuar..."
}

# ============================================================
# 8. Login Simulado
# ============================================================
login_user() {
    echo ""
    echo "--- INICIO DE SESION ---"
    read -p "Nombre de usuario: " username

    if id "$username" &>/dev/null; then
        is_ftp_user=$(groups "$username" 2>/dev/null | grep -E "reprobados|recursadores")
        if [ -z "$is_ftp_user" ]; then
            echo "[-] El usuario existe pero no pertenece al sistema FTP."
            read -p "Presione Enter para continuar..."
            return
        fi

        read -s -p "Contrasena: " password
        echo ""
        echo "[+] Login exitoso! Bienvenido, $username."
        echo "[*] Carpetas vinculadas:"
        ls -F "/srv/ftp/users/$username" 2>/dev/null || echo "[!] No se encontro directorio FTP."
    else
        echo "[-] Usuario no encontrado."
    fi
    read -p "Presione Enter para continuar..."
}

# ============================================================
# MENU PRINCIPAL
# ============================================================
while true; do
    clear
    echo "===================================================="
    echo "   ADMINISTRACION DE SERVIDOR FTP (LINUX MAGEIA)     "
    echo "===================================================="
    echo "1. Instalacion y Configuracion de vsftpd"
    echo "2. Alta Masiva de Usuarios"
    echo "3. Ver Usuarios Registrados"
    echo "4. Cambiar Grupo de Usuario"
    echo "5. Eliminar Usuario"
    echo "6. Login de Usuario (Simulado)"
    echo "7. Salir"
    echo "===================================================="
    read -p "Opcion: " opt

    case $opt in
        1) install_vsftpd; setup_base_env; config_vsftpd ;;
        2) add_ftp_users ;;
        3) list_registered_users ;;
        4) change_group ;;
        5) delete_user ;;
        6) login_user ;;
        7) echo "Saliendo..."; exit 0 ;;
        *) echo "Opcion no valida."; sleep 1; continue ;;
    esac

    echo ""
    read -p "Presione Enter para volver al menu..."
done
