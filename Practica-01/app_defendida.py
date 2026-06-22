from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs
from datetime import datetime, timedelta

USUARIO_VALIDO = "admin"
PASSWORD_VALIDO = "dragon2026"

LOG_FILE = "intentos_login_defensa.log"

MAX_INTENTOS = 3
TIEMPO_BLOQUEO_SEGUNDOS = 60

intentos_fallidos = {}
bloqueos = {}

HTML_LOGIN = """
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Panel Administrativo Seguro</title>
    <style>
        body {
            background: #0f172a;
            color: white;
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
        }
        .card {
            background: #1e293b;
            padding: 30px;
            border-radius: 15px;
            width: 370px;
            box-shadow: 0 0 25px rgba(0,0,0,0.5);
        }
        h1 {
            text-align: center;
            color: #22c55e;
        }
        input, button {
            width: 100%;
            padding: 12px;
            margin-top: 10px;
            border-radius: 8px;
            border: none;
        }
        button {
            background: #22c55e;
            color: #0f172a;
            font-weight: bold;
            cursor: pointer;
        }
        .msg {
            margin-top: 15px;
            text-align: center;
            font-weight: bold;
        }
        .info {
            font-size: 13px;
            color: #94a3b8;
            margin-top: 15px;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="card">
        <h1>Panel Seguro</h1>
        <form method="POST" action="/login">
            <input name="usuario" placeholder="Usuario">
            <input name="password" type="password" placeholder="Contraseña">
            <button type="submit">Ingresar</button>
        </form>
        <div class="msg">{mensaje}</div>
        <div class="info">Defensa activa: bloqueo por intentos fallidos</div>
    </div>
</body>
</html>
"""

def registrar(ip, usuario, resultado):
    fecha = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{fecha}] IP={ip} usuario={usuario} resultado={resultado}\n")

def ip_bloqueada(ip):
    if ip in bloqueos:
        ahora = datetime.now()
        if ahora < bloqueos[ip]:
            return True
        else:
            del bloqueos[ip]
            intentos_fallidos[ip] = 0
    return False

def registrar_fallo(ip):
    intentos_fallidos[ip] = intentos_fallidos.get(ip, 0) + 1

    if intentos_fallidos[ip] >= MAX_INTENTOS:
        bloqueos[ip] = datetime.now() + timedelta(seconds=TIEMPO_BLOQUEO_SEGUNDOS)
        return True

    return False

class LoginHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.enviar_pagina("")

    def do_POST(self):
        if self.path != "/login":
            self.send_error(404)
            return

        ip = self.client_address[0]

        if ip_bloqueada(ip):
            registrar(ip, "-", "BLOQUEADO")
            self.enviar_pagina("IP bloqueada temporalmente por demasiados intentos fallidos.")
            return

        longitud = int(self.headers.get("Content-Length", 0))
        datos = self.rfile.read(longitud).decode()
        formulario = parse_qs(datos)

        usuario = formulario.get("usuario", [""])[0]
        password = formulario.get("password", [""])[0]

        if usuario == USUARIO_VALIDO and password == PASSWORD_VALIDO:
            intentos_fallidos[ip] = 0
            registrar(ip, usuario, "ACCESO_CONCEDIDO")
            self.enviar_pagina("Acceso concedido. Bienvenido administrador.")
        else:
            bloqueo_activado = registrar_fallo(ip)

            if bloqueo_activado:
                registrar(ip, usuario, "BLOQUEO_ACTIVADO")
                self.enviar_pagina("Demasiados intentos fallidos. IP bloqueada temporalmente.")
            else:
                registrar(ip, usuario, "ACCESO_DENEGADO")
                self.enviar_pagina("Acceso denegado. Usuario o contraseña incorrectos.")

    def enviar_pagina(self, mensaje):
        contenido = HTML_LOGIN.replace("{mensaje}", mensaje).encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(contenido)))

        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'")

        self.end_headers()
        self.wfile.write(contenido)

print("Servidor defendido iniciado en http://0.0.0.0:8080")
print("Defensa activa:")
print("- Max intentos fallidos:", MAX_INTENTOS)
print("- Tiempo de bloqueo:", TIEMPO_BLOQUEO_SEGUNDOS, "segundos")
print("- Logs:", LOG_FILE)

servidor = HTTPServer(("0.0.0.0", 8080), LoginHandler)
servidor.serve_forever()