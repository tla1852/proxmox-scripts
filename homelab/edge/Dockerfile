FROM caddy:2.11-builder AS builder
ENV GOTOOLCHAIN=auto
RUN xcaddy build --with github.com/hslatman/caddy-crowdsec-bouncer
FROM caddy:2.11
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
