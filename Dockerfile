FROM nginx:alpine

COPY index.html /usr/share/nginx/html/index.html

# nginx default is port 80 — OCP expects 8080
RUN sed -i 's/listen\s*80;/listen 8080;/g' /etc/nginx/conf.d/default.conf && \
    chmod -R g+rwX /usr/share/nginx/html /var/cache/nginx /var/log/nginx /etc/nginx/conf.d && \
    touch /var/run/nginx.pid && \
    chmod g+rwX /var/run/nginx.pid

# OpenShift runs as random non-root UID
USER 1001

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
