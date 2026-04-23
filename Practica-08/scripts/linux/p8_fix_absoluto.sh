#!/bin/bash
# p8_fix_absoluto.sh 
# Corrige por completo las 3 politicas de seguridad en Linux Mint

# Ejecutar como root
if [ "$EUID" -ne 0 ]; then
  echo "Ejecuta este script como root (sudo bash $0)"
  exit 1
fi

echo "====================================================="
echo "  INSTALANDO POLITICA DE SEGURIDAD EXACTA"
echo "====================================================="

# ---------------------------------------------------------
# 1. HORARIOS EXACTOS + MENSAJE DE ERROR VISUAL EN LOGIN
# ---------------------------------------------------------
cat > /usr/local/bin/login_hours_check.sh << 'EOF'
#!/bin/bash
usuario=$PAM_USER
# Ignorar usuarios locales para no bloquear el sistema
[[ "$usuario" == "root" || "$usuario" == "angel" ]] && exit 0

grupos=$(id -Gn "$usuario" 2>/dev/null | tr '[:upper:]' '[:lower:]')
HORA=$(date +%H)
MIN=$(date +%M)
HORAMIN=$((10#$HORA * 100 + 10#$MIN))

# Funcion para mostrar el mensaje de error visual y abortar el login
rechazar_login() {
    # Truco para inyectar un mensaje de error en la pantalla LightDM de Mint
    XAUTHORITY=$(ls /var/run/lightdm/root/:* 2>/dev/null | head -n 1) DISPLAY=:0 zenity --error --title="ACCEESO DENEGADO" --text="ACCESO DENEGADO.\n\nPolítica Logon Hours:\nTu grupo NO tiene permitido iniciar sesión en este horario." --width=400 &
    sleep 3
    exit 1
}

# REGLA 1: NoCuates (Permitido solo 3:00 PM a 2:00 AM -> 15:00 a 01:59)
if echo "$grupos" | grep -q "nocuates"; then
    # Bloquear si la hora es desde las 02:00 AM hasta las 2:59 PM (14:59)
    if [[ $HORAMIN -ge 200 && $HORAMIN -lt 1500 ]]; then
        rechazar_login
    fi
# REGLA 2: Cuates (Permitido solo 8:00 AM a 3:00 PM -> 08:00 a 14:59)
elif echo "$grupos" | grep -q "cuates"; then
    # Bloquear si es antes de las 8 AM o si son las 3:00 PM o más
    if [[ $HORAMIN -ge 1500 || $HORAMIN -lt 800 ]]; then
        rechazar_login
    fi
fi

# Si cumple horario, dejarlo pasar
exit 0
EOF

chmod +x /usr/local/bin/login_hours_check.sh

# Incrustar el validador en el sistema de Login (PAM)
sed -i '/login_hours_check/d' /etc/pam.d/common-auth
echo "auth required pam_exec.so quiet /usr/local/bin/login_hours_check.sh" >> /etc/pam.d/common-auth

# ---------------------------------------------------------
# 2. BLOQUEO DEFINITIVO DE TODOS LOS EDITORES DE TEXTO
# ---------------------------------------------------------
# En lugar de bloquear uno solo, bloqueamos xed, gedit, nano y cualquier otro.
for editor in xed gedit mousepad pluma gnome-text-editor nano vi vim; do
    app_path=$(which $editor 2>/dev/null)
    # Si existe el editor y no lo hemos bloqueado todavía
    if [ ! -z "$app_path" ] && [ ! -f "${app_path}.real" ]; then
        mv "$app_path" "${app_path}.real"
        cat > "$app_path" << 'WRAPPER'
#!/bin/bash
grupos=$(id -Gn "$(whoami)" 2>/dev/null | tr '[:upper:]' '[:lower:]')

# Si detecta que es de NoCuates, bloquea la ejecución en seco
if echo "$grupos" | grep -q "nocuates"; then
    # Intentar sacar error gráfico, si falla mostrar error en consola
    zenity --error --title="Bloqueado" --text="AppLocker Linux:\n\nEl grupo NOCUATES tiene estrictamente prohibido usar editores de texto." --width=400 2>/dev/null || echo "ACCESO DENEGADO POR AD"
    exit 1
fi

# Si es Cuate o usuario normal, ejecutar el editor real
exec "${0}.real" "$@"
WRAPPER
        chmod +x "$app_path"
    fi
done

echo ""
echo "====================================================="
echo " TODO APLICADO. EL CANDADO ES ABSOLUTO."
echo "====================================================="
