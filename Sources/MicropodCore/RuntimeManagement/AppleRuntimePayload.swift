import Foundation

// SHA-256 inventory of the verified official 1.5.0 package Payload.
// Package SHA-256: a24808cb202318fa1c3bbee0c6c6887fe1225fe899d7b687a0ddd939bd6573f8
extension AppleRuntimeRelease {
    public static let payloadSHA256: [String: String] = [
        "bin/container": "8cc619377e8978a0ce9f22a3e864dcd4445f2bc38fb64c5197bb69a1bab42463",
        "bin/container-apiserver": "0d05388259e73b63f84680968fa5fa39feeef4219cce45c5655d29d3172a63b9",
        "bin/uninstall-container.sh": "51a840ab040bec9855ac66ad7c27b3b48771f69e779cb6d614895a3185a3dbb9",
        "bin/update-container.sh": "d7c11bde8814f9ee1b6ecb27067d627cb780cc89c1ed300fc9b755c214be9dd3",
        "libexec/container/plugins/container-core-images/bin/container-core-images":
            "dc88d9aeb67f8258c3697f8485b6ee77018d63b86b6dc3ba9905fb88f01cb6eb",
        "libexec/container/plugins/container-core-images/config.toml":
            "89ebf5415177298d36f4c67c8c03db26fac1377b428f30a5ccf96407d8f63f9d",
        "libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet":
            "bfb0c8b002946071df4428c5fa8e1d3bcb86d9798ae2e25dab1a1388e84c7270",
        "libexec/container/plugins/container-network-vmnet/config.toml":
            "7ec0d522dcf9c9bc78b1e0843916bd0a98cfec45ef5b35f04fb8407ecda3db3e",
        "libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux":
            "e8bee184cc1f6b53982f9cc4ecb02085ebe238b8834112f71f8972c0d488511a",
        "libexec/container/plugins/container-runtime-linux/config.toml":
            "d609af652f3e0224cb7f0cef315f873081506d010d2d1a8ff33508980e3427a7",
        "libexec/container/plugins/k8s/bin/k8s": "67242bebdc0e1b175cc69005e77a69450a054caca7cba9ef281269f4f1960d98",
        "libexec/container/plugins/k8s/config.toml": "4b190947dd6fdadb9463b0210d19c25b1d086ddff00a0685027d29e99facab95",
        "libexec/container/plugins/k8s/resources/kindnet.yaml":
            "9bb5cbeb75c07664b438a6dd3bb8f038e024cdebca3d945c5d02da5f2f2f781a",
        "libexec/container/plugins/machine-apiserver/bin/machine-apiserver":
            "1d3f53f6979d92d0bb9f343cc16782bad9a4b23bb380619f4b0d87d9d6df449c",
        "libexec/container/plugins/machine-apiserver/config.toml":
            "819edb0d3c20517e8a56e11a9623b3804c6821d3920da3fa66d989f766103b6a",
        "libexec/container/plugins/machine-apiserver/resources/create-user.sh":
            "bdbb3ceef02861b2b270ac403aa32320db6f23a0042dfde24c6a1275eca82f7b",
        "libexec/container/plugins/machine-apiserver/resources/init":
            "77a7f83faca9f8656ef129d8f91ddc4e770c80478d07b805a2530b9a902bf15a",
    ]
}
