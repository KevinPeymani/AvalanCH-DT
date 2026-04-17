FROM alpine:3.20

RUN apk add --no-cache bash curl docker-cli docker-cli-compose python3 tzdata

WORKDIR /workspace
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
