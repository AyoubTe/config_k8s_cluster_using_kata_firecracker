#!/bin/bash
set -e

# Run on ALL nodes

KATA_VERSION="2.5.2"
FC_VERSION="1.4.1"
ARCH="x86_64"

apt-get install -y cpu-checker

if ! kvm-ok; then
    echo "ERROR: KVM not available. Enable nested virtualization on the hypervisor host."
    exit 1
fi

if ! command -v kata-runtime &>/dev/null; then
    # "Downloading Kata Containers ${KATA_VERSION}..."
    KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-x86_64.tar.xz"
    curl -fsSL --retry 3 "$KATA_URL" -o /tmp/kata-static.tar.xz
    tar -xf /tmp/kata-static.tar.xz -C /
    rm /tmp/kata-static.tar.xz
fi

ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime 2>/dev/null || true
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2 2>/dev/null || true

kata-runtime --version

# "Downloading Firecracker ${FC_VERSION}..."
curl -fsSL --retry 3 \
    "https://github.com/firecracker-microvm/firecracker/releases/download/v${FC_VERSION}/firecracker-v${FC_VERSION}-${ARCH}.tgz" \
    -o /tmp/firecracker.tgz
tar -xf /tmp/firecracker.tgz -C /tmp
install -m 755 /tmp/release-v${FC_VERSION}-${ARCH}/firecracker-v${FC_VERSION}-${ARCH} /usr/local/bin/firecracker
install -m 755 /tmp/release-v${FC_VERSION}-${ARCH}/jailer-v${FC_VERSION}-${ARCH} /usr/local/bin/jailer
rm -rf /tmp/firecracker.tgz /tmp/release-v${FC_VERSION}-${ARCH}

firecracker --version

mkdir -p /etc/kata-containers

# Download proper initrd with kata-agent
echo "Downloading kata-containers initrd with agent..."
cd /opt/kata/share/kata-containers/
wget -q -O kata-containers-initrd-2.5.2.img \
    https://github.com/kata-containers/kata-containers/releases/download/2.5.2/kata-containers-initrd-2.5.2.img || {
    echo "ERROR: Failed to download initrd. Check internet connection."
    exit 1
}

# Backup broken Alpine initrd and link to working one
mv kata-containers-initrd.img kata-containers-initrd.img.backup 2>/dev/null || true
ln -sf kata-containers-initrd-2.5.2.img kata-containers-initrd.img

# Create kata-fc shim symlink (CRITICAL: RuntimeClass kata-fc needs this exact name)
ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-fc-v2

KATA_KERNEL=$(ls /opt/kata/share/kata-containers/vmlinux* 2>/dev/null | grep -v initrd | head -1)
KATA_INITRD="/opt/kata/share/kata-containers/kata-containers-initrd.img"
KATA_VIRTIOFSD=$(find /opt/kata -name "virtiofsd" 2>/dev/null | head -1)

echo "Kernel:    ${KATA_KERNEL}"
echo "Initrd:    ${KATA_INITRD}"
echo "Virtiofsd: ${KATA_VIRTIOFSD}"

# CRITICAL: Use /etc/kata-containers/configuration.toml (NOT configuration-fc.toml)
# Kata reads from configuration.toml by default
cat > /etc/kata-containers/configuration.toml <<EOF
[hypervisor.firecracker]
path = "/usr/local/bin/firecracker"
jailer_path = "/usr/local/bin/jailer"
kernel = "${KATA_KERNEL}"
initrd = "${KATA_INITRD}"
machine_type = ""
default_vcpus = 1
default_maxvcpus = 0
default_memory = 2048
default_maxmemory = 0
disable_block_device_use = false
shared_fs = "virtio-fs"
virtio_fs_daemon = "${KATA_VIRTIOFSD}"
virtio_fs_cache_size = 0
virtio_fs_extra_args = []
virtio_fs_cache = "auto"
block_device_driver = "virtio-mmio"
enable_iothreads = false
enable_jailer = true
jailer_cgroup = ""
sandbox_cgroup_only = false
rootless = false

[runtime]
enable_debug = false
enable_cpu_memory_hotplug = false
internetworking_model = "tcfilter"
disable_new_netns = false
sandbox_bind_mounts = []
experimental = []
EOF

CONTAINERD_CFG="/etc/containerd/config.toml"

if ! grep -q "kata-fc" "$CONTAINERD_CFG"; then
    cat >> "$CONTAINERD_CFG" <<'ENDOFBLOCK'

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-fc]
          runtime_type = "io.containerd.kata-fc.v2"
          privileged_without_host_devices = true
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-fc.options]
            ConfigPath = "/etc/kata-containers/configuration.toml"
ENDOFBLOCK
fi

systemctl restart containerd
systemctl is-active containerd

echo ""
echo "Kata + Firecracker setup done on $(hostname)"
kata-runtime kata-env 2>/dev/null | grep -E "Version|Path" | head -10 || true

echo ""
echo "VERIFICATION: Checking if initrd (not image) is configured..."
CONFIGURED_PATH=$(kata-runtime kata-env 2>/dev/null | grep -i "Path.*=" | head -1 | awk '{print $NF}' | tr -d '"')
if echo "$CONFIGURED_PATH" | grep -q "initrd"; then
    echo "SUCCESS: Using initrd ($CONFIGURED_PATH)"
else
    echo "WARNING: Not using initrd! Currently using: $CONFIGURED_PATH"
    echo "  This will cause Firecracker zombie processes."
fi