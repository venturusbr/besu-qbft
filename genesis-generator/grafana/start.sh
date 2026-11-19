#!/bin/sh
# Grafana entrypoint: opens Grafana on the Besu Full dashboard that init-qbft.sh downloads from
# grafana.com into dashboards-grafana-com/, or on the Besu QBFT network dashboard
# (dashboards/besu-qbft.json) when no copy was ever downloaded. Then starts Grafana as the
# image does (/run.sh).
besu_full=/var/lib/grafana/dashboards-grafana-com/besu-full.json
if [ -s "$besu_full" ]; then
    export GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=$besu_full
else
    export GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/besu-qbft.json
fi
exec /run.sh "$@"
