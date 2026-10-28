FROM nginx:1.27-alpine

COPY deploy/site.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css favicon.svg README.md THIRD_PARTY_NOTICES.md FileHalo-macOS-AppleSilicon.zip /usr/share/nginx/html/
COPY media/ /usr/share/nginx/html/media/

EXPOSE 80
