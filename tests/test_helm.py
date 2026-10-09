"""Offline chart contract checks using representative AKS values.

These check rendered Kubernetes objects, not Terraform's value composition or
live admission. No cluster connection, license files, or registry access needed.
"""

import copy
from pathlib import Path
import subprocess
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
BASE = {
    "fortiaigate": {
        "gpu": {"enabled": False},
        "image": {"repository": "registry.example/fortiaigate", "tag": "app-test-001"},
        "updateStrategy": "Recreate",
    },
    "triton": {"image": {"serverTag": "server-test-002", "modelsTag": "models-test-003"}},
    "tls": {"existingSecret": "fortiaigate-tls-secret"},
    "ingress": {
        "className": "azure-application-gateway",
        "host": "fortiaigate.example.com",
        "annotations": {
            "appgw.ingress.kubernetes.io/backend-protocol": "https",
            "appgw.ingress.kubernetes.io/ssl-redirect": "true",
        },
    },
    "storage": {"storageClass": "azurefile-fortiaigate", "size": "123Gi"},
    "postgresql": {
        "tls": {"certificatesSecret": "fortiaigate-tls-secret"},
        "primary": {"persistence": {
            "existingClaim": "", "storageClass": "managed-csi",
            "accessModes": ["ReadWriteOnce"],
        }},
    },
    "redis": {
        "tls": {"existingSecret": "fortiaigate-tls-secret"},
        "master": {"persistence": {
            "existingClaim": "", "storageClass": "managed-csi",
            "accessModes": ["ReadWriteOnce"],
        }},
    },
}
ISSUER = {
    "email": "operator@example.com", "host": "fortiaigate.example.com",
    "dnsZone": {
        "name": "example.com", "resourceGroup": "dns-test",
        "subscriptionID": "00000000-0000-0000-0000-000000000000",
    },
    "managedIdentityClientID": "11111111-1111-1111-1111-111111111111",
}


def helm(command, chart, values):
    args = ["helm", command]
    if command == "template":
        args.append("fortiaigate")
    args += [str(ROOT / chart), "--namespace", "fortiaigate", "-f", "-"]
    return subprocess.run(args, input=yaml.safe_dump(values), text=True,
                          capture_output=True, check=True).stdout


def render(chart, values):
    return {(doc["kind"], doc["metadata"]["name"]): doc
            for doc in yaml.safe_load_all(helm("template", chart, values)) if doc}


class HelmContracts(unittest.TestCase):
    def test_both_charts_lint_with_required_values(self):
        for chart, values in [("fortiaigate", BASE), ("certmanager-issuer", ISSUER)]:
            with self.subTest(chart=chart):
                helm("lint", chart, values)

    def test_cpu_ingress_probes_and_storage(self):
        docs = render("fortiaigate", BASE)
        self.assertEqual(yaml.safe_load((ROOT / "fortiaigate" / "Chart.yaml").read_text())["version"], "8.0.1")
        self.assertNotIn(("Deployment", "triton-server"), docs)
        ingress = docs["Ingress", "fortiaigate-ingress"]
        self.assertEqual(ingress["spec"]["ingressClassName"], "azure-application-gateway")
        self.assertEqual(ingress["spec"]["rules"][0]["host"], "fortiaigate.example.com")
        routes = {path["path"]: path["backend"]["service"]["name"] for path in
                  ingress["spec"]["rules"][0]["http"]["paths"]}
        self.assertEqual(routes, {"/ui": "webui", "/api/": "api", "/": "core"})
        self.assertEqual(ingress["metadata"]["annotations"], BASE["ingress"]["annotations"])
        self.assertEqual(ingress["spec"]["tls"][0]["secretName"], "fortiaigate-tls-secret")
        self.assertNotIn(("Secret", "fortiaigate-tls-secret"), docs)
        for name, path in [("core", "/fortiaigate/health/readiness"),
                           ("api", "/openapi.json"), ("webui", "/ui")]:
            container = docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]
            probe = container["readinessProbe"]["httpGet"]
            self.assertEqual(probe["path"], path)
            self.assertEqual(probe["scheme"], "HTTPS")
        core_env = {entry["name"]: entry.get("value") for entry in
                    docs["Deployment", "core"]["spec"]["template"]["spec"]["containers"][0]["env"]}
        self.assertEqual(core_env["UPSTREAM_TLS_VERIFY"], "true")
        self.assertEqual(core_env["SCANNER_MAX_SCAN_CHARS"], "5000")
        self.assertEqual(len(yaml.safe_load(core_env["SCANNER_MAX_SCAN_CHARS_BY_NAME"])), 8)
        for name in ("sensitive-scanner", "anonymize-scanner"):
            env = {entry["name"]: entry.get("value") for entry in
                   docs["Deployment", name]["spec"]["template"]["spec"]["containers"][0]["env"]}
            self.assertEqual(env["CHUNK_SIZE"], "256")
            self.assertEqual(env["CHUNK_OVERLAP_SIZE"], "64")
        shared = docs["PersistentVolumeClaim", "fortiaigate-storage"]["spec"]
        self.assertEqual(shared["storageClassName"], "azurefile-fortiaigate")
        self.assertEqual(shared["accessModes"], ["ReadWriteMany"])
        self.assertEqual(shared["resources"]["requests"]["storage"], "123Gi")
        for name in ("core", "api", "webui", "logd", "license-manager"):
            doc = docs.get(("Deployment", name)) or docs.get(("DaemonSet", name))
            self.assertIsNotNone(doc, name)
            image = doc["spec"]["template"]["spec"]["containers"][0]["image"]
            self.assertTrue(image.startswith("registry.example/fortiaigate/"), image)
            self.assertTrue(image.endswith(":app-test-001"), image)
            if doc["kind"] == "Deployment":
                self.assertEqual(doc["spec"]["strategy"]["type"], "Recreate")
        databases = [doc for (kind, _), doc in docs.items() if kind == "StatefulSet"]
        self.assertEqual(len(databases), 2)
        for database in databases:
            claim = database["spec"]["volumeClaimTemplates"][0]["spec"]
            self.assertEqual(claim["storageClassName"], "managed-csi")
            self.assertEqual(claim["accessModes"], ["ReadWriteOnce"])

    def test_gpu_placement_and_licensed_hostnames(self):
        values = copy.deepcopy(BASE)
        values["fortiaigate"]["gpu"]["enabled"] = True
        values["fortiaigate"]["gpuWorkloadPlacement"] = {
            "nodeSelector": {"fortiaigate-role": "gpu"},
            "tolerations": [{"key": "fortiaigate-gpu", "operator": "Equal",
                             "value": "true", "effect": "NoSchedule"}],
        }
        values["global"] = {"licenses": {"aks-app-test": "", "aks-gpu-test": ""}}
        values["license"] = {"existingConfigMap": "tf-license-config", "checksum": "lic-sha-test"}
        docs = render("fortiaigate", values)
        lm = docs["DaemonSet", "license-manager"]["spec"]["template"]
        self.assertEqual(lm["metadata"]["annotations"]["checksum/license"], "lic-sha-test")
        lm_volumes = {v["name"]: v for v in lm["spec"]["volumes"]}
        self.assertEqual(lm_volumes["license"]["configMap"]["name"], "tf-license-config")
        pod = docs["Deployment", "triton-server"]["spec"]["template"]["spec"]
        self.assertEqual(pod["initContainers"][0]["image"],
                         "registry.example/fortiaigate/triton-models:models-test-003")
        self.assertEqual(pod["containers"][0]["image"],
                         "registry.example/fortiaigate/custom-triton:server-test-002")
        model_data = docs["ConfigMap", "triton-model-repository"]["data"]
        self.assertEqual(set(model_data), {
            "prompt_injection_model-config.pbtxt", "toxicity_model-config.pbtxt",
            "sensitive_model-config.pbtxt", "language_model-config.pbtxt",
        })
        for mount in pod["containers"][0]["volumeMounts"]:
            if mount["name"] == "model-configs":
                self.assertIn(mount["subPath"], model_data)
        self.assertEqual(pod["nodeSelector"]["fortiaigate-role"], "gpu")
        self.assertIn(values["fortiaigate"]["gpuWorkloadPlacement"]["tolerations"][0], pod["tolerations"])
        terms = pod["affinity"]["nodeAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"]
        self.assertEqual(set(terms[0]["matchExpressions"][0]["values"]),
                         {"aks-app-test", "aks-gpu-test"})

    def test_certificate_modes(self):
        for environment in ("staging", "production"):
            values = copy.deepcopy(ISSUER)
            values["issuerName"] = "letsencrypt-" + environment
            server = ("https://acme-v02.api.letsencrypt.org/directory" if environment == "production"
                      else "https://acme-staging-v02.api.letsencrypt.org/directory")
            values["acmeServer"] = server
            with self.subTest(environment=environment):
                docs = render("certmanager-issuer", values)
                issuer = docs["ClusterIssuer", values["issuerName"]]
                self.assertEqual(issuer["spec"]["acme"]["server"], server)
                certificate = next(doc for (kind, _), doc in docs.items() if kind == "Certificate")
                self.assertEqual(certificate["spec"]["dnsNames"], [ISSUER["host"]])
                self.assertEqual(certificate["spec"]["secretName"], BASE["tls"]["existingSecret"])
                self.assertEqual(certificate["spec"]["issuerRef"]["name"], values["issuerName"])

    def test_certificate_missing_required_values_fails(self):
        with self.assertRaises(subprocess.CalledProcessError):
            render("certmanager-issuer", {})

    def test_separate_web_and_internal_tls(self):
        values = copy.deepcopy(BASE)
        values["tls"].update({
            "existingSecretChecksum": "web-cert-1",
            "internalExistingSecret": "fortiaigate-internal-tls-secret",
            "internalExistingSecretChecksum": "internal-cert-1",
            "internalMountPath": "/etc/internal-tls",
            "reloaderEnabled": True,
        })
        values["postgresql"]["tls"]["certificatesSecret"] = "fortiaigate-internal-tls-secret"
        values["redis"]["tls"].update({
            "existingSecret": "fortiaigate-internal-tls-secret", "certCAFilename": "ca.crt",
        })
        docs = render("fortiaigate", values)
        for name in ("core", "api", "logd", "license-manager"):
            with self.subTest(name=name):
                doc = docs.get(("Deployment", name)) or docs["DaemonSet", name]
                pod = doc["spec"]["template"]["spec"]
                container = pod["containers"][0]
                env = {e["name"]: e.get("value") for e in container["env"]}
                self.assertEqual(env["REDIS_SSL_ENABLED"], "true")
                self.assertEqual(env["REDIS_SSL_CERTFILE"], "/etc/internal-tls/tls.crt")
                self.assertEqual(env["REDIS_SSL_KEYFILE"], "/etc/internal-tls/tls.key")
                self.assertEqual(env["REDIS_SSL_CA_CERTS"], "/etc/internal-tls/ca.crt")
                if name != "license-manager":
                    self.assertEqual(env["POSTGRES_SSL_ENABLED"], "true")
                    self.assertEqual(env["POSTGRES_SSL_CA_CERTS"], "/etc/internal-tls/ca.crt")
                volumes = {v["name"]: v for v in pod["volumes"]}
                self.assertEqual(volumes["internal-tls-certs"]["secret"]["secretName"],
                                 "fortiaigate-internal-tls-secret")
                serving = "fortiaigate-tls-secret" if name in ("core", "api") else "fortiaigate-internal-tls-secret"
                self.assertEqual(volumes["tls-certs"]["secret"]["secretName"], serving)
                mounts = {m["name"]: m for m in container["volumeMounts"]}
                self.assertEqual(mounts["internal-tls-certs"]["mountPath"], "/etc/internal-tls")
        for name in ("core", "api", "webui"):
            doc = docs["Deployment", name]
            self.assertEqual(doc["metadata"]["annotations"]["secret.reloader.stakater.com/reload"],
                             "fortiaigate-tls-secret")
        for name in ("language-scanner", "code-scanner"):
            pod = docs["Deployment", name]["spec"]["template"]
            self.assertEqual(pod["metadata"]["annotations"]["checksum/tls"], "internal-cert-1")
            self.assertEqual(next(v for v in pod["spec"]["volumes"] if v["name"] == "tls-certs")
                             ["secret"]["secretName"], "fortiaigate-internal-tls-secret")
        for name in ("fortiaigate-postgresql", "fortiaigate-redis-master"):
            pod = docs["StatefulSet", name]["spec"]["template"]["spec"]
            secret_names = [v["secret"]["secretName"] for v in pod["volumes"] if "secret" in v]
            self.assertIn("fortiaigate-internal-tls-secret", secret_names)
            self.assertNotIn("fortiaigate-tls-secret", secret_names)

    def test_internal_tls_rollouts_are_independent_of_web_certificate(self):
        values = copy.deepcopy(BASE)
        values["tls"].update({"existingSecretChecksum": "web-1",
                              "internalExistingSecret": "internal-secret",
                              "internalExistingSecretChecksum": "internal-1"})
        before = render("fortiaigate", values)
        values["tls"]["existingSecretChecksum"] = "web-2"
        after = render("fortiaigate", values)
        for name in ("core", "api", "webui"):
            self.assertNotEqual(before["Deployment", name]["spec"]["template"],
                                after["Deployment", name]["spec"]["template"])
        for kind, name in (("Deployment", "logd"), ("DaemonSet", "license-manager"),
                           ("Deployment", "language-scanner")):
            self.assertEqual(before[kind, name]["spec"]["template"],
                             after[kind, name]["spec"]["template"])

    def test_shared_tls_fallback_and_disabled_database_tls(self):
        docs = render("fortiaigate", BASE)
        pod = docs["Deployment", "core"]["spec"]["template"]["spec"]
        env = {e["name"]: e.get("value") for e in pod["containers"][0]["env"]}
        self.assertEqual(env["REDIS_SSL_CA_CERTS"], "/etc/tls/tls.crt")
        self.assertNotIn("internal-tls-certs", {v["name"] for v in pod["volumes"]})
        values = copy.deepcopy(BASE)
        values["tls"]["internalExistingSecret"] = "internal-secret"
        values["postgresql"]["tls"]["enabled"] = False
        values["redis"]["tls"]["enabled"] = False
        docs = render("fortiaigate", values)
        for name in ("core", "api", "logd", "license-manager"):
            doc = docs.get(("Deployment", name)) or docs["DaemonSet", name]
            pod = doc["spec"]["template"]["spec"]
            self.assertNotIn("internal-tls-certs", {v["name"] for v in pod["volumes"]})


if __name__ == "__main__":
    unittest.main()
