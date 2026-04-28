# Usamos una imagen muy ligera basada en Alpine Linux
FROM alpine:latest

# Instalar Nginx sin usar caché local para reducir tamaño
RUN apk add --no-cache nginx

# Eliminar configuración por defecto
RUN rm /etc/nginx/http.d/default.conf

# Crear carpetas necesarias (si no existen) y asignar permisos
RUN mkdir -p /run/nginx /var/log/nginx /var/lib/nginx

# Copiar la configuración personalizada (sin server tokens)
COPY nginx.conf /etc/nginx/nginx.conf

# Copiar nuestra página estática personalizada
COPY html/ /usr/share/nginx/html/

# Asegurar que el usuario no administrativo 'nginx' sea el dueño
RUN chown -R nginx:nginx /usr/share/nginx/html /var/lib/nginx /var/log/nginx /run/nginx /etc/nginx

# Cambiar al usuario no administrativo
USER nginx

# Exponer el puerto 8080 (el puerto 80 requiere permisos root)
EXPOSE 8080

# Comando para iniciar Nginx en primer plano
CMD ["nginx", "-g", "daemon off;"]
