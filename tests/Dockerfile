FROM alpine:3.21

RUN apk add --no-cache curl jq bash

COPY test_bootstrap.sh /tests/test_bootstrap.sh
RUN chmod +x /tests/test_bootstrap.sh

ENTRYPOINT ["/tests/test_bootstrap.sh"]
