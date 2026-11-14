ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apk add --no-cache openssh-client nodejs

WORKDIR /app
COPY rootfs/run.sh /run.sh
COPY rootfs/proxy.mjs /app/proxy.mjs
COPY rootfs/hostkey.mjs /app/hostkey.mjs
RUN chmod 0755 /run.sh

ENV NODE_ENV=production
CMD ["/run.sh"]
