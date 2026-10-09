"""Render actual Terraform GPU values through Helm without Azure, deployment state, or providers."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="fortiaigate-gpu-render-") as directory:
    target = Path(directory)
    for name in ("variables.tf", "gpu.tf"):
        shutil.copy2(ROOT / name, target / name)
    subprocess.run(["terraform", "init", "-backend=false", "-no-color"],
                   cwd=target, check=True, capture_output=True)
    overlay = target / "advanced.yaml"
    overlay.write_text("vllm:\n  maxNumSeqs: 48\n")
    cases = {
        "a10": {"gpu_enabled": True, "gpu_node_vm_size": "Standard_NV36ads_A10_v5"},
        "a100": {"gpu_enabled": True, "gpu_node_vm_size": "Standard_NC24ads_A100_v4"},
        "cpu": {"gpu_enabled": False, "gpu_node_vm_size": "Standard_NV36ads_A10_v5"},
        "custom": {
            "gpu_enabled": True,
            "gpu_node_vm_size": "Standard_NV36ads_A10_v5",
            "extra_values_files": [str(overlay)],
            "gpu_tuning": {"vllm_max_num_seqs": 16, "triton_memory_limit": "26Gi"},
        },
    }
    for name, variables in cases.items():
        var_file = target / "case.tfvars.json"
        var_file.write_text(json.dumps({"image_repository": "example.com/fortiaigate", **variables}))
        result = subprocess.check_output(
            ["terraform", "console", "-var-file=" + str(var_file)],
            cwd=target, input="jsonencode(local.gpu_helm_values)\n", text=True)
        values = json.loads(json.loads(result))
        args = ["helm", "template", "fortiaigate", str(ROOT / "fortiaigate"),
                "--set", "fortiaigate.image.repository=example.com/fortiaigate",
                "--set", "fortiaigate.gpu.enabled=" + str(variables["gpu_enabled"]).lower(),
                "--set", "fortiaigate.updateStrategy=Recreate",
                "--set", "vllm.gpuAttach=shared",
                "--set", "tls.existingSecret=test-web-tls"]
        for index, value in enumerate(values):
            path = target / f"values-{index}.yaml"
            path.write_text(value)
            args += ["-f", str(path)]
        docs = [d for d in yaml.safe_load_all(subprocess.check_output(args, text=True)) if d]
        pods = [d for d in docs if d["kind"] == "Deployment" and
                d["metadata"]["name"] == "triton-vllm-server"]
        if name == "cpu":
            assert not pods and not values
        else:
            deployment = pods[0]
            containers = {c["name"]: c for c in deployment["spec"]["template"]["spec"]["containers"]}
            triton, vllm = containers["triton"], containers["vllm"]
            requested = sum(int(c["resources"]["requests"]["memory"].removesuffix("Gi"))
                            for c in containers.values())
            assert requested == (36 if name == "a100" else 20), (name, requested)
            assert deployment["spec"]["strategy"]["type"] == "Recreate"
            assert sum(c["resources"]["limits"].get("nvidia.com/gpu", 0)
                       for c in containers.values()) == 1
            assert "--max-model-len=16384" in vllm["args"]
            if name in ("a10", "custom"):
                assert triton["resources"]["limits"]["memory"] == ("26Gi" if name == "custom" else "25Gi")
                assert vllm["resources"]["limits"]["memory"] == "24Gi"
                assert "--api-server-count=1" in vllm["args"]
                assert f"--max-num-seqs={16 if name == 'custom' else 64}" in vllm["args"]
        print(f"{name}: Terraform values rendered through Helm successfully")
