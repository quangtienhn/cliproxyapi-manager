ARG BUILD_FROM
FROM ${BUILD_FROM}

# s6-overlay init is provided by the HA base image; do not override ENTRYPOINT.
RUN apk add --no-cache openssh-client nodejs

WORKDIR /app
COPY rootfs/run.sh /run.sh
COPY rootfs/proxy.mjs /app/proxy.mjs
COPY rootfs/hostkey.mjs /app/hostkey.mjs
COPY rootfs /  # s6-overlay service definitions under etc/s6-overlay
RUN chmod 0755 /run.sh /etc/s6-overlay/s6-rc.d/cliproxyapi_tunnel/run

ENV NODE_ENV=production
# No CMD: the HA base image runs s6 /init as PID 1, which starts the service above.
