#!/bin/bash
set -e

# Run ONLY on cluster2-master

if ! command -v wsk &>/dev/null; then
    WSK_VERSION="1.2.0"
    curl -fsSL "https://github.com/apache/openwhisk-cli/releases/download/${WSK_VERSION}/OpenWhisk_CLI-${WSK_VERSION}-linux-amd64.tgz" \
        -o /tmp/wsk.tgz
    tar -xf /tmp/wsk.tgz -C /tmp
    install -m 755 /tmp/wsk /usr/local/bin/wsk
    rm /tmp/wsk.tgz
fi

wsk property set \
    --apihost 192.168.27.16:31001 \
    --auth 23bc46b1-71f6-4ed5-8c54-816aa4f8c502:123zO3xZCLrMN6v2BKK1dXYFpXlPkccOFqm12CZBkROBjVUW

cat > /tmp/hello.js <<EOF
function main(params) {
    var name = params.name || "World";
    return { msg: "Hello " + name + " from Kata/Firecracker cluster2" };
}
EOF

wsk -i action delete hello 2>/dev/null || true
wsk -i action create hello /tmp/hello.js

echo ""
echo "Invoking test action..."
wsk -i action invoke hello --result --param name "Cluster2"

echo ""
wsk -i action list
