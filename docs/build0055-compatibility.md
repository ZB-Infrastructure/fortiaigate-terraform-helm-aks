# FortiAIGate 8.0.2 build0055 port and upgrade notes

The AKS chart selectively incorporates the supplied build0055 changes over build0047. It retains AGIC ingress and readiness probes, Azure Files shared storage, Azure Disk databases, app/GPU placement, deployment licensing, Terraform-owned credentials, supplied/generated/cert-manager web TLS, and independent internal TLS. Live build0055 installation and migration remain unqualified.

## Release evidence

The supplied chart archive and all ten Docker archive manifests/configurations were inspected on 2026-10-27. [The inventory](build0055-images.json) records the chart archive SHA-256, exact image tags, and image configuration digests. All ten image configurations report `linux/amd64`. Configuration digests are not registry manifest digests. Layers were not executed, scanned, loaded, or pushed.

The application tag is `V8.0.2-build0055`; the inference server is `25.11-onnx-trt-agt-rpt-s1`, model carrier is `0.0.5-s1`, and vLLM is `0.28.0-rpt-s1`. Retain the chart's independent tag overrides and qualify the four tags as a release set. The DP agent image is absent and Terraform continues to disable it.

The port adds vendor GPU profiles, coordinated DLP batching settings, vLLM engine controls, guardrail queue defaults, and the gateway Base URL keepalive setting. Terraform's automatic Azure A10 profile preserves the prior one-instance/64-sequence inference sizing and 12/8 GiB host memory requests rather than adopting the larger vendor GPU defaults. See [GPU tuning](deployment-guide.md#gpu-tuning).

## Upgrading from build0047

1. Back up PostgreSQL, Redis, Azure Files data, Terraform state, Helm values, and Secrets. Keep the original encryption, CSRF, Redis and PostgreSQL credentials. Rehearse against a backup before production.
2. Publish the ten verified images using [the registry guide](registry-and-images.md). Set all four tag variables in existing local tfvars; old explicit values override new defaults. Review overlays for obsolete flags and duplicate `vllm.extraArgs` engine options.
3. Use the same backend and tfvars for a full plan. No network, cluster, GPU-pool, storage or credential resource replacement is intended. This branch also restores external-network guards and tests; supply complete, valid subnet IDs. Do not toggle network ownership during the application upgrade.
4. Expect new `tls_private_key.internal`, `tls_cert_request.internal`, and `tls_locally_signed_cert.internal` resources, updating the existing internal Secret and rolling internal clients/databases. The internal client CN now matches the effective PostgreSQL username, including final overlay precedence. Existing CA, generated web certificate/private key addresses, Secret names, and credential resources remain stable. Internal rollout can interrupt service; changing only web certificates continues to leave databases unaffected.
5. Apply only after plan review and migration rehearsal. Verify database TLS, license-manager/API/gateway readiness, license coverage, model loading, and DLP/POLICY inference. Confirm a second plan has no unexpected replacement or drift. Record results in [testing](testing.md).

Database schema changes and application downgrade compatibility cannot be established from Helm templates. Keep a complete backup and the original image/configuration set; a Helm rollback alone does not restore schemas, credentials, or encrypted data. Earlier 8.0.1 deployments still require [secret adoption and migration prerequisites](upgrade-8.0.1-to-8.0.2.md). The [build0047 audit](build0047-compatibility.md) remains historical evidence, not the current default.
