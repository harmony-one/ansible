/usr/sbin/hmy blockchain latest-headers | jq .result | jq '.["beacon-chain-header"]'  | jq -r .number | xargs printf "%d\n"
