FROM alpine:3.20
RUN apk add --no-cache postgresql16-client py3-psycopg2 iproute2 iptables nftables util-linux procps conntrack-tools
COPY hold-connections.py /opt/probe/hold-connections.py
