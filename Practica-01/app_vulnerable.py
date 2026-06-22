from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs
from datetime import datetime

USUARIO_VALIDO = "admin"
PASSWORD_VALIDO = "dragon2026"
LOG_FILE = "intentos_login.log"

HTML_LOGIN = """
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Panel Administrativo</title>
    <style>
        body {
            background: #111827;
            color: white;
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
        }
        .card {
            background: #1f2937;
            padding: 30px;
            border-radius: 15px;
            width: 350px;
            box-shadow: 0 0 25px rgba(0,0,0,0.5);
        }
        h1 {
            text-align: center;
            color: #38bdf8;
        }
        input, button {
            width: 100%;
            padding: 12px;
            margin-top: 10px;
            border-radius: 8px;
            border: none;
        }
        button {
            background: #38bdf8;
            color: #111827;
            font-weight: bold;
            cursor: pointer;
        }
        .msg {
            margin-top: 15px;
            text-align: center;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <div class="card">
        <h1>Panel Admin</h1>
        <form method="POST" action="/login">
            <input name="usuario" placeholder="Usuario">
            <input name="password" type="password" placeholder="Contraseña">
            <button type="submit">Ingresar</button>
        </form>
        <div class="msg">{mensaje}</div>
    </div>
</body>
</html>
"""

def registrar(ip, usuario, password, resultado):
    fecha = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{fecha}] IP={ip} usuario={usuario} password_intentado={password} resultado={resultado}\n")

class LoginHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.enviar_pagina("")

    def do_POST(self):
        if self.path != "/login":
            self.send_error(404)
            return

        longitud = int(self.headers.get("Content-Length", 0))
        datos = self.rfile.read(longitud).decode()
        formulario = parse_qs(datos)

        usuario = formulario.get("usuario", [""])[0]
        password = formulario.get("password", [""])[0]
        ip = self.client_address[0]

        if usuario == USUARIO_VALIDO and password == PASSWORD_VALIDO:
            registrar(ip, usuario, password, "ACCESO_CONCEDIDO")
            self.enviar_pagina("Acceso concedido. Bienvenido administrador.")
        else:
            registrar(ip, usuario, password, "ACCESO_DENEGADO")
            self.enviar_pagina("Acceso denegado. Usuario o contraseña incorrectos.")

    def enviar_pagina(self, mensaje):
        contenido = HTML_LOGIN.format(mensaje=mensaje).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(contenido)))
        self.end_headers()
        self.wfile.write(contenido)

print("Servidor vulnerable iniciado en http://0.0.0.0:8080")
print("Usuario correcto: admin")
print("Contraseña correcta: dragon2026")
servidor = HTTPServer(("0.0.0.0", 8080), LoginHandler)
servidor.serve_forever()