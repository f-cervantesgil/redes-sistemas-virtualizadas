# 0. Check Root
if [[ $EUID -ne 0 ]]; then
   echo "[-] Este script debe ejecutarse como root (use sudo)." 
   exit 1
fi

# 1. Instalación e Idempotencia
install_vsftpd() {
    echo "[*] Verificando e Instalando vsftpd..."
    if ! rpm -q vsftpd > /dev/null; then
        echo "[*] Sincronizando repositorios (esto puede tardar un momento)..."
        urpmi.update -a
        echo "[*] Intentando instalar vsftpd..."
        urpmi vsftpd --auto
        
        if [ $? -ne 0 ]; then
            echo "[-] ERROR: No se pudo encontrar o instalar el paquete 'vsftpd'."
            echo "    Intente ejecutar: urpmi --auto-update"
            exit 1
        fi
        echo "[+] vsftpd instalado exitosamente."
    else
        echo "[!] vsftpd ya esta instalado."
    fi

    # ASEGURAR QUE /sbin/nologin SEA UN SHELL VALIDO
    # Esto es vital para evitar el error 530 Login Incorrect
    if ! grep -q "/sbin/nologin" /etc/shells; then
        echo "/sbin/nologin" >> /etc/shells
        echo "[*] /sbin/nologin agregado a /etc/shells."
    fi
}

# 2. Configuracion Base del Sistema
setup_base_env() {
    echo "[*] Inicializando Grupos y Directorios..."
    
    # Crear Grupos
    groupadd -f reprobados
    groupadd -f recursadores
    groupadd -f ftp_access  # Grupo para todos los usuarios con login
    
    # Directorios de Almacenamiento
    mkdir -p /srv/ftp/general
    mkdir -p /srv/ftp/grupos/reprobados
    mkdir -p /srv/ftp/grupos/recursadores
    mkdir -p /srv/ftp/users
    
    # Permisos para carpeta General (Anonimo Lectura, Logeados Escritura)
    # Propietario: root, Grupo: ftp_access (usuarios logeados)
    chown root:ftp_access /srv/ftp/general
    # 775 permite rwx al grupo ftp_access y r-x al resto (anónimos)
    chmod 775 /srv/ftp/general
    
    # Permisos Grupos
    chgrp reprobados /srv/ftp/grupos/reprobados
    chgrp recursadores /srv/ftp/grupos/recursadores
    chmod 2770 /srv/ftp/grupos/reprobados
    chmod 2770 /srv/ftp/grupos/recursadores

    # Abrir Firewall (Intenta con firewalld e iptables)
    echo "[*] Abriendo puertos en el Firewall (20, 21, 40000-40100)..."
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=ftp
        firewall-cmd --permanent --add-port=40000-40100/tcp
        firewall-cmd --reload
    else
        iptables -A INPUT -p tcp --dport 21 -j ACCEPT
        iptables -A INPUT -p tcp --dport 20 -j ACCEPT
        iptables -A INPUT -p tcp --dport 40000:40100 -j ACCEPT
    fi
}

# 3. Configurar vsftpd.conf
config_vsftpd() {
    echo "[*] Configurando vsftpd.conf..."
    # Asegurarse de que el directorio del chroot seguro exista
    mkdir -p /var/run/vsftpd/empty

    # Definir el contenido de la configuración
    CONF_CONTENT=$(cat <<EOF
# Configuracion Practica 05
listen=YES
listen_ipv6=NO
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
secure_chroot_dir=/var/run/vsftpd/empty

# Configuracion de Autenticacion
pam_service_name=vsftpd
check_shell=NO

# Personalización Raíz
no_anon_password=YES
anon_root=/srv/ftp/general

# Modo Pasivo (Para Filezilla)
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100

# SSL Desactivado
ssl_enable=NO
EOF
)

    # Escribir en ambas rutas posibles para asegurar compatibilidad
    echo "$CONF_CONTENT" > /etc/vsftpd.conf
    if [ -d "/etc/vsftpd" ]; then
        echo "$CONF_CONTENT" > /etc/vsftpd/vsftpd.conf
    fi

    systemctl restart vsftpd
    systemctl enable vsftpd
    echo "[+] Configuración aplicada y servicio reiniciado."
    echo "[!] IMPORTANTE: Si sigue viendo el error 500 OOPS, asegúrese de que el servicio esté corriendo con: systemctl status vsftpd"
}

# 4. Gestión de Usuarios y Bind Mounts
add_ftp_users() {
    read -p "Cuantos usuarios desea crear? " num
    for (( i=1; i<=$num; i++ ))
    do
        read -p "Nombre del usuario $i: " username
        read -s -p "Contraseña para $username: " password
        echo ""

        # Seleccione Grupo
        echo "Seleccione Grupo (1: reprobados, 2: recursadores): "
        read group_opt
        
        target_group="reprobados"
        [[ "$group_opt" == "2" ]] && target_group="recursadores"

        # Crear Usuario si no existe
        if ! id "$username" &>/dev/null; then
            # Agregamos al grupo del curso Y al grupo ftp_access
            useradd -m -G "$target_group,ftp_access" -s /sbin/nologin "$username"
            echo "$username:$password" | chpasswd
            echo "[+] Usuario $username creado con éxito."
        else
            echo "[!] El usuario $username ya existe. Asegurando grupos..."
            usermod -a -G "$target_group,ftp_access" "$username"
        fi

        # Estructura FTP del usuario (Home Seguro)
        USER_FTP="/home/$username/ftp"
        # La raíz del chroot no debe tener permisos de escritura por seguridad de vsftpd
        # Pero como usamos allow_writeable_chroot=YES, podemos darle permisos al usuario
        mkdir -p "$USER_FTP"
        chown "$username:$target_group" "$USER_FTP"
        chmod 755 "$USER_FTP"

        mkdir -p "$USER_FTP/general"
        mkdir -p "$USER_FTP/$target_group"
        mkdir -p "$USER_FTP/$username"

        # Bind Mounts (Para que aparezcan las 3 carpetas al logear)
        mount --bind /srv/ftp/general "$USER_FTP/general"
        mount --bind "/srv/ftp/grupos/$target_group" "$USER_FTP/$target_group"
        
        # Carpeta personal (físicamente en /srv/ftp/users/$username)
        mkdir -p "/srv/ftp/users/$username"
        # El usuario es dueño de su carpeta personal para tener escritura
        chown "$username:$target_group" "/srv/ftp/users/$username"
        chmod 700 "/srv/ftp/users/$username" 
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

# 6. Eliminar Usuario
delete_user() {
    read -p "Nombre del usuario a eliminar: " username
    if id "$username" &>/dev/null; then
        echo "[*] Eliminando usuario $username..."
        
        # Desmontar carpetas activas para evitar errores de Busy Device
        USER_FTP="/home/$username/ftp"
        umount -l "$USER_FTP/general" 2>/dev/null
        umount -l "$USER_FTP/reprobados" 2>/dev/null
        umount -l "$USER_FTP/recursadores" 2>/dev/null
        umount -l "$USER_FTP/$username" 2>/dev/null

        # Eliminar usuario y home
        userdel -r "$username" 2>/dev/null
        
        # Limpiar carpeta física de archivos personal si existe
        rm -rf "/srv/ftp/users/$username"
        
        echo "[+] Usuario $username eliminado correctamente."
    else
        echo "[-] Usuario no encontrado."
    fi
    read -p "Presione Enter para continuar..."
}

# 7. Listar Usuarios Registrados
list_registered_users() {
    echo ""
    echo "[*] USUARIOS REGISTRADOS EN EL SISTEMA FTP"
    echo "------------------------------------------"
    printf "%-20s %-20s\n" "USUARIO" "GRUPO"
    printf "%-20s %-20s\n" "-------" "-----"
    
    # Buscamos miembros de los grupos específicos
    for group in reprobados recursadores; do
        members=$(getent group "$group" | cut -d: -f4 | tr ',' ' ')
        for user in $members; do
            if [ ! -z "$user" ]; then
                printf "%-20s %-20s\n" "$user" "$group"
            fi
        done
    done
    echo "------------------------------------------"
    read -p "Presione Enter para continuar..."
}

# 8. Login Simulado
login_user() {
    echo ""
    echo "--- INICIO DE SESIÓN ---"
    read -p "Nombre de usuario: " username
    
    if id "$username" &>/dev/null; then
        is_ftp_user=$(groups "$username" | grep -E "reprobados|recursadores")
        if [ -z "$is_ftp_user" ]; then
            echo "[-] El usuario existe pero no pertenece al sistema FTP."
            return
        fi

        read -s -p "Contraseña: " password
        echo ""
        # En una simulación, solo verificamos existencia y grupo
        echo "[+] ¡Login exitoso! Bienvenido, $username."
        echo "[*] Carpetas vinculadas:"
        ls -F "/home/$username/ftp" 2>/dev/null
    else
        echo "[-] Usuario no encontrado."
    fi
    read -p "Presione Enter para continuar..."
}

# MENU PRINCIPAL
while true; do
    clear
    echo "===================================================="
    echo "  ADMINISTRACION DE SERVIDOR FTP (LINUX MAGEIA)       "
    echo "===================================================="
    echo "1. Instalación e Instalacion de vsftpd"
    echo "2. Alta Masiva de Usuarios"
    echo "3. Ver Usuarios Registrados"
    echo "4. Cambiar Grupo de Usuario"
    echo "5. Borrar Usuario"
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
        *) echo "Opcion no valida."; sleep 1 ;;
    esac
done
