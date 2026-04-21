#!/bin/bash
# p8_server_mageia.sh
# Automatización del Servidor Windows Server -> Mageia Linux (Sin GUI)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

fn_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fn_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
fn_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    fn_err "Ejecuta este script como root (su -)."
    exit 1
fi

DOMAIN="redes.local"
REALM="REDES.LOCAL"
WORKGROUP="REDES"
PASS="Contrasena123!"

echo "=========================================================="
echo "   PRACTICA 08 - SERVIDOR DE DOMINIO Y GOBERNANZA MAGEIA"
echo "=========================================================="
echo "1) Instalar Dependencias (Samba AD DC, Quotas)"
echo "2) Promover Servidor a Controlador de Dominio"
echo "3) Importar Usuarios y Configurar Cuotas (10MB/5MB)"
echo "4) Configurar Shares y Apantallamiento (Veto Files)"
echo "5) Ejecutar TODO"
echo "=========================================================="
read -rp "Selecciona una ocpion: " opt

case $opt in
    1|5)
        fn_info "Instalando paquetes basicos de provision (dnf)..."
        dnf install -y samba samba-dc samba-client krb5-server quota
        fn_ok "Paquetes instalados."
        ;&
    2|5)
        fn_info "Promoviendo el servidor a Active Directory (Samba DC)..."
        systemctl stop smb nmb winbind
        rm -f /etc/samba/smb.conf
        samba-tool domain provision --use-rfc2307 --realm="${REALM}" --domain="${WORKGROUP}" --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass="${PASS}"
        
        # Mover validacion Kerberos
        cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
        
        systemctl enable --now samba
        fn_ok "Dominio $DOMAIN aprovisionado correctamente."
        ;&
    3|5)
        fn_info "Creando Estructura de Usuarios y Cuotas de Disco..."
        samba-tool group add "G_Cuates" 2>/dev/null
        samba-tool group add "G_NoCuates" 2>/dev/null
        
        CSV_FILE="../../data/usuarios.csv"
        # Aseguramos que la raiz soporte cuotas en /
        if ! grep -q "usrquota" /etc/fstab; then
            fn_err "ATENCION: Debes agregar 'usrquota,grpquota' en tu /etc/fstab sobre la particion / y reiniciar."
        fi
        
        tail -n +2 "$CSV_FILE" | while IFS=',' read -r Nombres Apellidos Username Password Tipo; do
            # Limpiar retornos de carro del excel
            Tipo=$(echo "$Tipo" | tr -d '\r')
            samba-tool user create "$Username" "$Password" 2>/dev/null
            
            if [ "$Tipo" == "Cuates" ]; then
                samba-tool group addmembers "G_Cuates" "$Username"
                # Cuota FSRM en Linux: 10 MB = 10240 KB Soft, 10240 KB Hard
                setquota -u "$Username" 10240 10240 0 0 / 2>/dev/null
            else
                samba-tool group addmembers "G_NoCuates" "$Username"
                # Cuota FSRM en Linux: 5 MB = 5120 KB Soft, 5120 KB Hard
                setquota -u "$Username" 5120 5120 0 0 / 2>/dev/null
            fi
            fn_ok "Usuario $Username ($Tipo) creado con su Cuota asignada."
        done
        quotacheck -cum / 2>/dev/null
        quotaon / 2>/dev/null
        ;&
    4|5)
        fn_info "Configurando Carpetas Compartidas y Apantallamiento..."
        mkdir -p /srv/Cuates_Docs /srv/NoCuates_Docs
        chmod 777 /srv/Cuates_Docs /srv/NoCuates_Docs
        
        # Agregamos los shares al smb.conf del dominio
        cat >> /etc/samba/smb.conf <<EOF

[Cuates_Docs]
    path = /srv/Cuates_Docs
    read only = no
    # APANTALLAMIENTO ACTIVO: Bloquear archivos multimedia y ejecutables (FSRM Veto Files)
    veto files = /*.mp3/*.mp4/*.exe/*.msi/
    delete veto files = yes

[NoCuates_Docs]
    path = /srv/NoCuates_Docs
    read only = no
    # APANTALLAMIENTO ACTIVO (FSRM Veto Files)
    veto files = /*.mp3/*.mp4/*.exe/*.msi/
    delete veto files = yes
EOF
        systemctl restart samba
        fn_ok "Servidor de Archivos, Cuotas y Apantallamiento Activo listas."
        ;;
esac
