# Customer quickstart — deploy a Primed Hardened Runner

> **Draft.** The Marketplace offer is in Microsoft's review and is not live yet. The deploy
> commands below have not been run against the published offer. This notice is removed when
> they have.

Deploy the image, then register it as a **GitHub Actions self-hosted runner** or an **Azure DevOps
self-hosted agent**. The deploy steps and the registration command are shared; the config says
which platform.

Applies to **Ubuntu 24.04 1.0.4 (build 0.0.46) and later**; where 1.0.3 and earlier differ, the
text says so. The baked registration entrypoint
`primed-register` (A6) first appeared in build 0.0.29, proven on both platforms
through the entrypoint (release train 36335474372, GitHub certify run 36344758244); 0.0.27 and
earlier predate it ([Step R0](#step-r0--check-the-image-carries-the-entrypoint) checks). The
Windows Server 2025 image is not yet released, and its entrypoint is not built — see
[Windows](#windows-server-2025) at the end.

**Conventions in this document.** Commands are real and taken from the build, test and scan
harnesses in our private build repository. Paths in backticks that start with `certification/`,
`packer/`, `compliance/` or `docs/` point into that repository; they are cited so you can see
where a statement comes from, and you cannot open them. Where a step is *not* proven, it is
marked `> **UNVERIFIED:**` with what would confirm it. Do not treat an UNVERIFIED step as tested.

---

## Before you start

You need:

| | |
|---|---|
| Azure CLI | signed in (`az login`) to the subscription that will host the runner |
| Permissions | Contributor on the target resource group; read access to the image |
| The image | see [Step 1](#step-1--get-access-to-the-image) |
| An Azure Key Vault and a managed identity | the VM reads its registration credential from your vault with its own identity ([Step R1](#step-r1--give-the-vm-an-identity-that-can-read-one-secret)) |
| A registration credential | GitHub: a repo/org runner **registration token**. Azure DevOps: a **PAT** with *Agent Pools (read, manage)*. It goes into the vault, never onto the VM by any other channel |

### Two things about this image that will surprise you

1. **This guide never uses SSH.** Every command runs through `az vm run-command`, which reaches
   the VM over the Azure control plane and needs no open port or public address. The image's
   firewall allows inbound SSH (Ubuntu 1.0.3 and earlier ship no SSH rule), but your network
   security group decides whether anything can reach it, and the runner agent is outbound-only.
   To close or open SSH on the VM, see [Break-glass access](#break-glass-access).

2. **Registration is one baked command, and you never hand the VM a token.** Both agent packages
   are pre-staged in the image, pinned and checksum-verified; `/opt/primed/bin/primed-register`
   reads a facts-only config you supply, fetches the credential from your Key Vault with the VM's
   managed identity, and registers the agent as a dedicated non-root user. Nothing downloads at
   registration time, and no Run Command, cloud-init or extension payload ever carries a token.

---

## Step 1 — Get access to the image

The image is sold on the Azure Marketplace as **Hardened Self-Hosted GitHub Actions Runner & Azure
DevOps Agent**, publisher Primed Systems. Its identifiers:

| | |
|---|---|
| Publisher | `primed-systems` |
| Offer | `hardened-runners` |
| Plan | `ubuntu-2404` |
| Version | `1.0.4`, or `latest` |

As one string: `primed-systems:hardened-runners:ubuntu-2404:1.0.4`.

Accept the Marketplace terms once per subscription:

```bash
az vm image terms accept --publisher primed-systems --offer hardened-runners --plan ubuntu-2404
```

Image versions are **immutable**: a given version's bits never change. Use an exact version such
as `1.0.4` when you want the VM to match one release's published evidence; `latest` picks up each
new release.

## Step 2 — Create the VM

Trusted Launch with Secure Boot and vTPM is the boot configuration this image is built, scanned
and functionally tested under. Keep these flags, so that your VM matches the configuration the
published evidence describes.

```bash
RG=rg-my-runners
VM=runner-01
IMAGE="primed-systems:hardened-runners:ubuntu-2404:1.0.4"

az group create -g "$RG" -l southcentralus -o none

az vm create \
  -g "$RG" -n "$VM" \
  --image "$IMAGE" \
  --plan-publisher primed-systems --plan-product hardened-runners --plan-name ubuntu-2404 \
  --size Standard_D4ads_v7 \
  --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
  --public-ip-address "" --nsg-rule NONE \
  --admin-username azureuser --generate-ssh-keys \
  -o none
```

> **UNVERIFIED:** this exact command against the Marketplace offer, and which regions the offer
> can be deployed in. The same arguments, with the image taken from our own gallery instead of
> the Marketplace, are what our release tests use. Confirmed by: running it against the offer.

- `--public-ip-address ""` and `--nsg-rule NONE` give the runner **no public IP and no inbound NSG
  rule**. The agent dials out; nothing needs to dial in. Keep it this way unless you have a reason
  not to.
- `--size Standard_D4ads_v7` is the size this image is built and functionally tested on. Others
  will work; this is the proven one.
- `--generate-ssh-keys` creates a key pair. The image's firewall allows inbound SSH (Ubuntu 1.0.3
  and earlier: it does not), so your network decides who can reach port 22. With no public IP
  and no inbound NSG rule, that is still every machine Azure's default rules allow, which
  includes the rest of the virtual network.

Confirm the VM is reachable before continuing. `az vm run-command invoke` itself blocks until the
Azure guest agent is ready, so a trivial command doubles as the readiness check:

```bash
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts 'echo BOOT_OK' \
  --query "value[0].message" -o tsv
```

> **UNVERIFIED:** whether you should additionally wait on `cloud-init status --wait` before
> registering. First-boot cloud-init creates the admin user and rewrites hostname, netplan, and the
> fstab ephemeral-disk entry (`docs/B3-DEVIATIONS.md`, first-boot drift set); registering while that
> is still in flight is untested. No harness in this repository waits on cloud-init — the
> certification legs go straight from `az vm create` to `run-command`. Confirmed by: adding
> `cloud-init status --wait` to the command above and confirming it returns `status: done` rather
> than blocking indefinitely.

## Step 3 — Confirm what you deployed (optional, recommended)

The build metadata for this exact image version is inside the image at `/opt/compliance/`:

```bash
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts 'ls -1 /opt/compliance/ && cat /opt/compliance/build-metadata.json' \
  --query "value[0].message" -o tsv
```

`build-metadata.json` binds the running image to the certified build and its source commit. Ubuntu
1.0.4 is a gallery copy of build 0.0.46 with the same bits; builds keep `0.0.N` numbering while
product releases use SemVer. Its `image_version` therefore reads `0.0.46`, not `1.0.4`. Map that
build to the product version through the `primed-hardened-ubuntu/1.0.4` gallery version tags
`productVersion=1.0.4` and `build=0.0.46`, the Ubuntu row in `docs/evidence/RELEASED.json`
(version `1.0.4`, build `0.0.46`), and `docs/evidence/ubuntu/releases/1.0.4.json`. The GitHub
release `ubuntu-2404-v1.0.4` is titled `ubuntu-2404 1.0.4 (build 0.0.46)`. Earlier releases remain
available as `ubuntu-2404-v1.0.3` (build 0.0.43), `ubuntu-2404-v1.0.2` (build 0.0.37),
`ubuntu-2404-v1.0.1` (build 0.0.36) and `ubuntu-2404-v1.0.0` (build 0.0.30). Build 0.0.46 starts
from a newer Ubuntu base (`24.04.202611170`, kernel 7.0.0-1020), pre-stages GitHub runner 2.338.2
and Azure DevOps agent 5.282.0, and is the first release that gives jobs sudo and Docker by
default and ships an inbound SSH rule in its firewall; build 0.0.43 installed Chrome, chromedriver
and Chromium pinned and checksum-verified (see [Browsers](#browsers)); build 0.0.37 restored the
Chrome and Edge sandboxes; build 0.0.36 pinned Miniconda and Julia.

From 1.0.3 the image is built once and scanned after the build, so the scan results are not inside
the image: `/opt/compliance/` holds `build-metadata.json` and a build-time `ownership-normalize`
record, nothing else. The OpenSCAP ARF scan result, an SPDX SBOM of the OS packages (the dpkg
inventory; it does not list the CI tools or the agents), the deviations register, and an evidence
manifest with SHA-256 for each file are in the signed release bundle (next section) and in
`docs/evidence/ubuntu/0.0.46/`. Releases up to 1.0.2 also carried those files inside the image.

The pre-staged agent packages and their pin record:

```bash
az vm run-command invoke -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts 'cat /opt/primed/agents/agents.json' \
  --query "value[0].message" -o tsv
```

Each record carries `id`, `version`, `sha256`, `archive`, `archive_path`, and `target_dir`, written
at build time from the toolset manifest and re-asserted against it
(`packer/common/install-agent-packages.sh`).

## Verify the Ubuntu 1.0.4 release evidence

Download the release assets, then verify the evidence tarball and its attestation:

```bash
gh release download ubuntu-2404-v1.0.4 --repo primed-systems/<PUBLIC_REPO>
cosign verify-blob --certificate-identity https://github.com/primed-systems/primed-hardened-runners/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com --bundle evidence-ubuntu-2404-1.0.4.sigstore.json evidence-ubuntu-2404-1.0.4.tar.gz
cosign verify-blob-attestation --type custom --certificate-identity https://github.com/primed-systems/primed-hardened-runners/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com --bundle evidence-ubuntu-2404-1.0.4.attestation.sigstore.json evidence-ubuntu-2404-1.0.4.tar.gz
```

---

# Register the runner — `primed-register`

Registration is one baked command, `/opt/primed/bin/primed-register`, for both platforms. You give it
a **facts-only** config file; it fetches the registration credential itself from **your** Azure Key
Vault with the VM's managed identity (or, for Azure DevOps, mints an Entra token from IMDS), verifies
the pre-staged agent package against its pin, creates the dedicated non-root user `primed-agent`,
configures the agent as that user, installs and starts its own systemd unit, proves the credential
left no residue on disk, and drops references to it. The credential is never on a command line,
never in the config, and never in anything you pass to Run Command, cloud-init or a VM extension.

This is exactly the path the certification legs run on every Ubuntu image version that carries the
entrypoint (`certification/sut/bootstrap-agent.sh`, `bootstrap-gh-runner.sh`: they write this config
and invoke this command with `token_source: vault`).

Proven live on release build 0.0.46 through `token_source: vault` with Run Command delivery, with
sudo on, which is the default from 1.0.4. The GitHub path passed certify run 45230548772
(`sudo=true`). The Azure DevOps path passed in build run 45207964460's external-test job,
including its AC7 decoy (`PRIMED_AC7=PASS`, `PRIMED_AC7_DEMANDS=COVERED`;
`docs/evidence/ubuntu/0.0.46/certify.sentinels.txt`). In both, the test job had to show `sudo`
working for `primed-agent` before the test could pass. Sudo off was last proven live on build
0.0.43, where off was still the default (certify run 43969292966, `sudo=false`). UNVERIFIED:
turning sudo off with `"sudo": false` on 1.0.4 is covered by offline tests only and has not run
on a deployed VM, and the cloud-init delivery below has not been run live with sudo on.

Cloud-init delivery was proven live on Ubuntu 1.0.3 on 2026-11-18 for GitHub with
`token_source: vault`, through the Terraform and Bicep examples in `examples/` (the config written
by cloud-init `write_files`, base64-encoded, the identity attached by the template): each VM
registered itself at first boot, ended with `PRIMED_REGISTER=OK`, and stayed online after Step R6.
No job was run on those two runners, and the literal `az vm create ... --custom-data` command in
Step R4(a) was not itself run.

> **UNVERIFIED (live):** cloud-init delivery for Azure DevOps, the VM-extension delivery route, a
> job on a persistent (non-ephemeral) GitHub runner, registration surviving a reboot, and the
> `imds` and `env` token sources. Each is exercised offline against the real entrypoint
> (`certification/tests/test-primed-register.bats`) but not yet on a deployed VM.

## Step R0 — Check the image carries the entrypoint

```bash
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
  --scripts $'#!/bin/bash\ntest -x /opt/primed/bin/primed-register && echo PRESENT || echo ABSENT' \
  --query "value[0].message" -o tsv
```

`ABSENT` means an image version from before A6 (0.0.27 and earlier do not carry it). Those versions
have no supported customer registration path in this guide: the previous manual recipe passed the
token as a Run Command parameter, which this product no longer documents. Deploy a newer version.

## Step R1 — Give the VM an identity that can read one secret

Use a user-assigned identity (recommended: it survives VM re-creation) and grant it read on a
**dedicated vault that holds nothing but this runner's registration credential**. Create the vault
with Azure RBAC authorization.

**Why a dedicated vault.** While the identity is attached, any process on the VM, including a CI
job, can request the identity's tokens from the instance metadata service and read whatever that
identity can read. The entrypoint does not and cannot prevent this. Keep the identity's reach to
this one credential, never grant it anything else (least of all teardown or deployment rights),
and detach it once the runner is online ([Step R6](#step-r6--dispose-of-the-credential)).

```bash
KV=kv-my-runners                     # your vault; 3-24 chars, a-z 0-9 -
MI=mi-my-runners
az identity create -g "$RG" -n "$MI" -o none
MI_ID="$(az identity show -g "$RG" -n "$MI" --query id -o tsv)"
MI_CLIENT_ID="$(az identity show -g "$RG" -n "$MI" --query clientId -o tsv)"
MI_PRINCIPAL="$(az identity show -g "$RG" -n "$MI" --query principalId -o tsv)"
az keyvault create -g "$RG" -n "$KV" --enable-rbac-authorization true -o none
az role assignment create --role "Key Vault Secrets User" --assignee-object-id "$MI_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --scope "$(az keyvault show -n "$KV" --query id -o tsv)" -o none
az vm identity assign -g "$RG" -n "$VM" --identities "$MI_ID" -o none
```

A custom role that grants only `Microsoft.KeyVault/vaults/secrets/getSecret/action` works too. A
vault that uses access policies instead of RBAC needs a `get` secret permission for the identity. If
the vault firewall is on, allow the VM's subnet or use a private endpoint.

## Step R2 — Put the credential in the vault, off every command line

| Platform | Credential | Scope and lifetime |
|---|---|---|
| GitHub | a runner **registration token** (`POST .../actions/runners/registration-token`) | registration only; expires after about an hour, so register within the hour |
| Azure DevOps | a **PAT** with *Agent Pools (read, manage)* only | long-lived: set the shortest workable expiry, and delete it from the vault after registration |

Write it through a private temporary file so it never appears in `ps`, shell history or an argv:

```bash
umask 077
SECRET_FILE="$(mktemp)"
gh api -X POST repos/<OWNER>/<REPO>/actions/runners/registration-token --jq .token > "$SECRET_FILE"
#   Azure DevOps instead: paste the PAT into "$SECRET_FILE" with an editor; do not echo it.
az keyvault secret set --vault-name "$KV" --name runner-01-reg --file "$SECRET_FILE" \
  --expires "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" -o none
rm -f "$SECRET_FILE"
SECRET_ID="https://${KV}.vault.azure.net/secrets/runner-01-reg"
```

`SECRET_ID` is the only credential-related value that goes anywhere else, and it is a URL, not a
credential: without the VM's identity it reads nothing. Dispose of the secret once the runner shows
online (Step R6).

## Step R3 — Write the config

`/etc/primed/runner-config.json`, facts only. `primed-register` makes it root `0600` on entry and
refuses a key named `token` (at any depth), an unknown key, a duplicate key, or a key that belongs
to the other platform, with exit 2 and no side effects.

| Key | Platforms | Value |
|---|---|---|
| `platform` | both, required | `github` or `azdo` |
| `url` | both, required | `https://github.com/<owner>[/<repo>]` or `https://dev.azure.com/<org>` |
| `token_source` | both, required | `vault` (recommended), `imds` (Azure DevOps only, UNVERIFIED), `env` (see below) |
| `token_secret_id` | `vault` | the secret URL from Step R2; the host must be `*.vault.azure.net`, `*.vault.azure.cn` or `*.vault.usgovcloudapi.net`, no query string |
| `identity_client_id` | `vault`, `imds` | the client id of the user-assigned identity (`$MI_CLIENT_ID`); omit for a system-assigned identity |
| `agent_name` | both | default: the VM's short hostname |
| `labels` | `github` | a list, e.g. `["self-hosted","linux","x64","primed-hardened"]` |
| `runner_group` | `github` | default `Default` |
| `ephemeral` | `github` | `true` = one job, then GitHub removes it; default `false` |
| `pool` | `azdo` | default `Default` |
| `capabilities` | both | `{"NAME":"value"}` pairs written to the agent's `.env` |
| `update_policy` | both | `disabled` (default) or `enabled`; see [Update policy](#update-policy) |
| `docker` | both | `true` or `false`; default `true` with `token_source` `vault` or `imds`, `false` with `env`; see [Docker jobs](#docker-jobs). Ubuntu 1.0.3 and earlier: default `false` |
| `sudo` | both | `true` (default) or `false`; requires `token_source: vault` or `imds`, so with `env` the default is `false`; a VM that has had sudo registers only once; see [The agent's identity](#the-agents-identity). Ubuntu 1.0.3 and earlier: default `false` |
| `ssh` | both | `true` (default) leaves the firewall as shipped; `false` removes the image's inbound SSH rule (`22/tcp`) every time `primed-register` runs; see [Break-glass access](#break-glass-access). Ubuntu 1.0.3 and earlier refuse this key |
| `audit_argv` | both | `true` runs the kernel-audit argv proof around registration (needs `auditd` on the VM, which the image does not bake); default `false` |

GitHub example:

```json
{"platform":"github","url":"https://github.com/<OWNER>/<REPO>","agent_name":"runner-01",
 "labels":["self-hosted","linux","x64","primed-hardened"],"token_source":"vault",
 "token_secret_id":"https://kv-my-runners.vault.azure.net/secrets/runner-01-reg",
 "identity_client_id":"<MI_CLIENT_ID>"}
```

Azure DevOps example:

```json
{"platform":"azdo","url":"https://dev.azure.com/<ORG>","pool":"<POOL>","agent_name":"runner-01",
 "token_source":"vault","token_secret_id":"https://kv-my-runners.vault.azure.net/secrets/runner-01-reg",
 "identity_client_id":"<MI_CLIENT_ID>"}
```

**`imds` (Azure DevOps, UNVERIFIED):** `"token_source":"imds"` has the entrypoint mint an Entra token
for Azure DevOps with the VM identity, so no secret exists at all. It needs an Entra-backed
organization with the identity added to it and to the pool. Confirmed by: a live registration with
an identity granted in a real organization (brief 09 Phase B); until then use `vault`.

**`env`** reads `PRIMED_REG_TOKEN` from the entrypoint's own environment. It exists only for callers
that can prove the value lives in memory alone (an operator's interactive root shell using a
`VAR=value command` prefix). No Run Command, cloud-init or extension recipe may carry it; there is
none in this guide. It cannot be combined with `"sudo": true`: unsetting a variable does not remove
the inherited value from `/proc/<pid>/environ`, so sudo requires `vault` or `imds`. For the same reason Docker access, which is root-equivalent
too, is off by default with `env` (`"docker": true` turns it on, as before). The entrypoint says
in DIAG lines that neither was granted.

## Step R4 — Deliver the config and run the entrypoint

Pick one. None of them carries a credential.

**(a) At VM creation, with cloud-init.** The image's `primed-agent-bootstrap.service` runs the
entrypoint after cloud-init whenever `/etc/primed/runner-config.json` exists (it is inert without
one). Put the config in custom data and the identity on the create call:

```yaml
#cloud-config
write_files:
  - path: /etc/primed/runner-config.json
    permissions: '0600'
    owner: root:root
    content: |
      {"platform":"github","url":"https://github.com/<OWNER>/<REPO>","agent_name":"runner-01","labels":["self-hosted","linux","x64","primed-hardened"],"token_source":"vault","token_secret_id":"https://kv-my-runners.vault.azure.net/secrets/runner-01-reg","identity_client_id":"<MI_CLIENT_ID>"}
```

```bash
az vm create ... --assign-identity "$MI_ID" --custom-data runner-cloud-init.yaml
```

Custom data persists on the VM (`/var/lib/cloud/instance/`); that is acceptable only because the
config holds no credential. The entrypoint also refuses to register if it finds its own credential in
custom data or IMDS user data (exit 2). The unit's output is in `journalctl -u primed-agent-bootstrap`.

Ready-made Terraform and Bicep versions of Steps 2, R1, R3 and this route are in
[`examples/`](../examples/README.md).

**(b) On a running VM, with Run Command.** Build the script with the config inside its text
(`az vm run-command --parameters` splits a value at its first `=`, so do not pass JSON that way). The
script persists under `/var/lib/waagent/`; it holds no credential:

```bash
CONFIG='{"platform":"github","url":"https://github.com/<OWNER>/<REPO>","agent_name":"runner-01","labels":["self-hosted","linux","x64","primed-hardened"],"token_source":"vault","token_secret_id":"'"$SECRET_ID"'","identity_client_id":"'"$MI_CLIENT_ID"'"}'
cat > register.sh <<EOF
#!/bin/bash
set -uo pipefail
install -d -m 0700 -o root -g root /etc/primed || { echo "REGISTER=FAIL mkdir"; exit 5; }
cat > /etc/primed/runner-config.json <<'JSON' || { echo "REGISTER=FAIL config"; exit 5; }
$CONFIG
JSON
/opt/primed/bin/primed-register
EOF
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
  --scripts @register.sh --query "value[0].message" -o tsv
```

**(c) With the Custom Script Extension.** The same script from a storage URL, run by
`commandToExecute`. The extension's settings persist on the VM, which is why they may hold only the
config, never a credential.

> **UNVERIFIED:** the extension route. The contract's live proof for it (a real CSE deployment
> registering with `token_source: vault`) belongs to the A6 PR2 verification run, not yet done.

With (a), the secret must exist before the VM's first boot finishes, and a GitHub registration token
must still be inside its hour.

Keep `#!/bin/bash` as the literal first line of any Run Command script.

## Step R5 — Read the result

The last line is always exactly one `PRIMED_REGISTER=OK` or `PRIMED_REGISTER=FAIL`, with
`PRIMED_REGISTER_DIAG=` lines before it (they carry the platform and URL host, never config contents
or the credential). Exit codes:

| Exit | Meaning | What to do |
|---|---|---|
| 0 | registered, already registered (no change), or removed | nothing |
| 2 | config or argument rejected, platform swap, credential found in a persisted boot channel, not root | fix what the DIAG names |
| 3 | credential not obtained: IMDS, the vault, or `PRIMED_REG_TOKEN` | a vault `403` DIAG names the three causes: no `Key Vault Secrets User` (or get) for the identity, the vault firewall, an access-policy vault without `get` |
| 4 | pin, ancestry, state record or listener integrity failure | the image or its `/opt/primed` tree was altered; redeploy |
| 5 | configure, service, lock or observer failure | the DIAG carries the agent's own `config.sh` output, credential-scrubbed |
| 6 | credential residue or argv exposure found after configuring; the registration was rolled back | treat the credential as exposed: revoke it |

Then confirm from the platform's side — `gh api repos/<OWNER>/<REPO>/actions/runners` shows the
runner `online`; **Organization settings → Agent pools → your pool → Agents** shows the agent
**Online**. Re-running the command (or rebooting) on a registered VM exits 0 without reconfiguring;
naming the other platform exits 2.

## Step R6 — Dispose of the credential

```bash
az keyvault secret delete --vault-name "$KV" --name runner-01-reg -o none
az keyvault secret purge --vault-name "$KV" --name runner-01-reg -o none   # if soft-delete keeps it
```

Then detach the identity, so no job on this VM can mint its tokens:

```bash
az vm identity remove -g "$RG" -n "$VM" --identities "$MI_ID" -o none
```

Jobs can reach the runner as soon as it is online, and a job that runs before this step can read
the credential and mint the identity's tokens, so do this step immediately after Step R5. On
GitHub you can hold jobs off by registering with a label no workflow targets yet and adding your
working labels after this step. The runner keeps working: the agents authenticate
afterwards with their own credential, which they store under the agent directory, readable only
by `primed-agent`. If this VM was registered with `"sudo": false`, re-attach the identity and put a fresh
credential in the vault before a later registration. Dispose of a VM that has had sudo.

## Step R7 — Use it

```yaml
# GitHub
jobs:
  build:
    runs-on: [self-hosted, linux, x64, primed-hardened]
    steps:
      - uses: actions/checkout@v4
      - run: kubectl version --client && az version
```

```yaml
# Azure DevOps
pool:
  name: <POOL>
steps:
  - script: kubectl version --client && az version
```

## Step R8 — Deregister

Deregister from the platform's side. Do not send a removal token or a PAT into the VM to run
`config.sh remove`: a job on the agent could have replaced the agent's files and would capture the
credential (Eric 2026-09-26: removal is local-only; no removal credential reaches the VM). The
platform-side delete needs no credential on the VM, and it works even when the VM is already gone:

```bash
# GitHub (the path the certification harness takes on every run)
RUNNER_ID=$(gh api "repos/<OWNER>/<REPO>/actions/runners?name=runner-01" --jq '.runners[] | select(.name=="runner-01") | .id')
gh api -X DELETE repos/<OWNER>/<REPO>/actions/runners/$RUNNER_ID
```

Azure DevOps: **Organization settings → Agent pools → your pool → Agents → the agent → Delete**, or
REST `DELETE https://dev.azure.com/<ORG>/_apis/distributedtask/pools/<POOL_ID>/agents/<AGENT_ID>?api-version=7.1`,
the call the certification teardown makes (`certification/g4-certify.sh`). Then delete the VM.
Deleting a VM without deregistering leaves an offline entry in the pool or repository.

To keep a VM that has never granted passwordless sudo to jobs, run
`/opt/primed/bin/primed-register --remove` on it first (as root, for example through Run Command).
It cleans up locally with no credential: it stops and removes the unit, ends the agent's processes,
wipes the agent directory, its home and the state record, prints
`PRIMED_REGISTER_STATE=absent`, and prints an advisory `DELETE` line naming the agent's id. Delete
the id you looked up yourself, as above, and treat a mismatch as tampering. If jobs ran with Docker
access, dispose of the VM instead of reusing it: containers they started survive the agent's
removal. A VM that has had sudo (the default) must also be disposed of, not re-registered. Mount
workspace disks elsewhere, never at or under `/opt/primed/gh-runner`,
`/opt/primed/azdo-agent` or `/opt/primed/home`: registration and `--remove` exit 5 rather than
delete through a mount.

---

## After registration — things you will want

### Job environment

From 1.0.1, jobs receive the image's environment from `/etc/environment`, including the paths for
`cargo`, `ghc`, `ansible` and `yamllint`, and `JAVA_HOME_*_X64`, `AGENT_TOOLSDIRECTORY` and `CONDA`.
Runner-cert runs 39306328308 and 39243176754 passed `class3-image-env` during GitHub certify
runs 39305632119 and 39242485385 on build 0.0.37 (and 37607823093 / 37613622183 on build 0.0.36).

On 1.0.0 VMs, jobs do not receive those values. A job's PATH is only
`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/snap/bin`, and the image's values of its tool
variables (`AGENT_TOOLSDIRECTORY`, `RUNNER_TOOL_CACHE`, `JAVA_HOME_*_X64`, `CONDA`,
`CHROMEWEBDRIVER` and the rest) are missing. The tools are installed and work, but `cargo`, `ghc`,
`ansible` and `yamllint` report *command not found*, and scripts that pick a JDK through
`JAVA_HOME_17_X64` get an empty value. `setup-*` actions may not reuse the preinstalled tool caches;
that has not been checked in a live job.

Workaround for 1.0.0 VMs: load the file at the start of a script step. Verified as `primed-agent`
(cargo, ghc, ansible, yamllint and `JAVA_HOME_17_X64`):

```bash
set -a; . /etc/environment; set +a
```

On 1.0.0 GitHub VMs you can do it once per job, so later steps see it too. This adds only the
image's own directories to the PATH, so the system directories keep their order. It has not yet
been run in a live GitHub job:

```yaml
- name: Load the image environment
  shell: bash
  run: |
    ( set -a; . /etc/environment
      for n in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*' /etc/environment); do
        [ "$n" = PATH ] || printf '%s=%s\n' "$n" "${!n}"
      done ) >> "$GITHUB_ENV"
    cur="$PATH"
    ( . /etc/environment; tr ':' '\n' <<<"$PATH" ) | grep -vxF -f <(tr ':' '\n' <<<"$cur") >> "$GITHUB_PATH"
```

### Docker jobs

Docker is installed and the daemon runs. The agent runs as the non-root `primed-agent`, which the
entrypoint adds to the `docker` group by default and says so in a DIAG line (Ubuntu 1.0.3 and
earlier: only with `"docker": true`). Understand the grant: membership of the `docker` group is
**root-equivalent** on the host. Set `"docker": false` to register without it. That only keeps
`primed-agent` out of the group: a job with sudo can still reach Docker through `sudo`, so set
`"sudo": false` as well to keep jobs away from root on the host. On a VM registered with
`"sudo": false`, a later registration with `docker: false` (after `--remove`) revokes the group.

Docker is the supported container runtime for jobs. Verified on a 1.0.0 VM as `primed-agent`:
`docker run`, Compose, buildx, a kind cluster, and a Postgres service container with a published
port. Three limits:

- **podman and buildah** come with the upstream image but do not work rootless as `primed-agent`:
  the account has no subordinate user-ID ranges and no login session.
- **skopeo** works once it has somewhere to keep registry logins:
  `mkdir -p ~/.config/containers && export REGISTRY_AUTH_FILE=~/.config/containers/auth.json`.
  On a VM that runs more than one job, point it at a per-job path instead (for example under
  `$RUNNER_TEMP` on GitHub or `$AGENT_TEMPDIRECTORY` on Azure DevOps), so logins do not outlive the job.
- **A container on Docker's default bridge could not reach a server running on the VM itself**:
  the host firewall blocked the request. Run the server in a container too, on the same Docker
  network, or run both sides on the host. Do not treat this as a security boundary; Docker access is
  already root-equivalent.

On **Windows**, Docker runs **Windows containers** (process isolation; there is no Linux-container
backend). dockerd's pipe admits Administrators, SYSTEM and the local `docker-users` group, which the
image ships **empty**. A non-admin agent account needs membership:

```powershell
Add-LocalGroupMember -Group docker-users -Member <agent-user>   # then restart the agent service
```

The same warning applies: `docker-users` membership is **administrator-equivalent** on the host.
Base images must match the host build (Windows Server 2025, `ltsc2025` / 10.0.26100).

Proven on Windows 0.0.36: runner-cert run 36333549742, `class1-docker-build=PASS (windows
containers: digest-pinned nanoserver build + run)`.

### Update policy

`"update_policy": "disabled"` (the default) keeps the agent at the version baked into the image:
GitHub gets `--disableupdate`, Azure DevOps gets `agent.disableupdate=true` in the agent's `.env`.
You take agent updates by deploying a newer image version, which is how the listener you run stays
the one certified. `"enabled"` lets the agent update itself; after an update,
`primed-register --measure` reports the listener hash no longer matches the registration record
(exit 4), and a re-invocation refuses the changed listener. On a VM that has never used sudo, use
`--remove` before registering again; dispose of a VM that has had sudo.

**GitHub's 30-day rule.** With updates disabled, GitHub stops queueing jobs to a self-hosted runner
once a newer runner release has been available for 30 days (GitHub Docs, *Controlling runner
software updates on self-hosted runners*). Plan to redeploy from a newer image version within that
window. The runner version the image carries is in `/opt/primed/agents/agents.json` and on the
runner's **Settings → Actions → Runners** entry. Azure DevOps agents have no such window.

### The agent's identity

The agent runs as `primed-agent`, a system user with no login shell and its home under
`/opt/primed/home`, created at first registration, never baked. `RUNNER_ALLOW_RUNASROOT` and
`AGENT_ALLOW_RUNASROOT` are never set. Its unit is `primed-agent-github.service` or
`primed-agent-azdo.service`, written by the entrypoint; the agents' own `svc.sh` is not used.

Jobs get passwordless sudo by default, as they do on GitHub-hosted runners; set `"sudo": false` to
register without it. Ubuntu 1.0.3 and earlier default to no sudo: there, set `"sudo": true`
(available from 1.0.1, build 0.0.36).
Runner-cert runs 39306328308 and 39243176754 proved `class3-sudo=GRANTED` with `"sudo": true` and
`class3-sudo=DENIED` without it on build 0.0.37 (as 37607823093 and 37613622183 did on 0.0.36).
The grant gives `primed-agent` passwordless `sudo` for every command, which is root-equivalent just like the `docker` group. The drop-in is created at registration
time as `/etc/sudoers.d/primed-agent`; it is never baked into the image. The entrypoint verifies
by running `sudo -n /usr/bin/true` as `primed-agent` that the identity can run sudo without a password.
Sudo logging remains enabled at `/var/log/sudo.log`, but `timestamp_timeout` does not limit a
`NOPASSWD` grant. AIDE reports the new file as expected per-VM drift. Neither `sudo.log` nor AIDE is
tamper-evident against a job that already has sudo: that job is root and can alter the log, the AIDE
database, or the checker. The baked CIS scan is unchanged: password-for-escalation is a Level 2 rule
in the SSG 0.1.81 profile, while Level 1 forbids only a global `!authenticate` setting.

With sudo enabled, the agent identity is quiesced, the residue and argv proofs finish, and references
to the registration credential are dropped before a clean-environment finalizer installs the grant
and starts the listener. The listener never holds that registration credential. Editing an existing
registration's config does not change its grant, and completing an ephemeral job does not expire it.
`--remove` revokes only this managed drop-in and keeps the root-only
`/opt/primed/agents/.sudo-granted` taint marker. It cannot undo root-level changes a job made.

A VM that has ever held this grant is disposed of and never registered again. With sudo on by
default that is every VM not registered with `"sudo": false` or `token_source: env`: to move a
runner to another repository or pool, or after a registration that failed once the grant was
attempted, deploy a fresh VM. The same goes for an ephemeral runner that has served its job:
`--reset` is refused, and the next runner needs a fresh VM. On every registration
attempt, `primed-register` refuses before credential acquisition when it can see any of: state with
`sudo: true`, the managed drop-in, or the taint marker. This evidence check is best effort, not a
security boundary—a root job can erase all three. The operating rule is still disposal. A SIGKILL,
reboot or source/image rollback neither revokes a deployed grant nor restores trust; run the
U2-capable `--remove` only for local teardown, then dispose of the VM.

From 0.0.30 the agent cannot write `/usr/share`, `/usr/local/bin` or `/usr/local/sbin`, which
root reads or executes from. `npm install -g` of a package that adds a command therefore fails:
use `npx`, or a per-user prefix (`npm config set prefix ~/.npm-global` and put
`~/.npm-global/bin` on `PATH`). The tool caches (`/opt/hostedtoolcache`, `/usr/lib/jvm`,
`/usr/local/lib/node_modules` and similar) stay writable so setup actions work, so on a VM that
runs more than one job, a job can change the toolchains the next job uses. Run untrusted code,
such as pull requests from forks, on ephemeral VMs. `corepack enable` fails for the same reason as
`npm install -g`: it writes its shims into `/usr/local/bin`. Installing a further .NET SDK into
`/usr/share/dotnet` fails too, because that folder is read-only to the agent; the preinstalled
SDKs work.

**With `"sudo": false`, jobs cannot use `sudo`.** `primed-agent` then has no sudo rule, so
`sudo apt-get install …` fails with `sudo: a password is required`, and
`systemctl start postgresql` fails with `Interactive authentication required`. GitHub-hosted runners
allow passwordless sudo ([GitHub Docs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#administrative-privileges)),
so workflows written for them need a different route. Both of these were verified on 1.0.0 as
`primed-agent`:

- **A Postgres container with a published port** (needs Docker access, the default), with the password taken
  from the job's secret environment rather than written on the command line:
  `docker run -d -p 127.0.0.1:5432:5432 -e POSTGRES_PASSWORD postgres:16-alpine`.
  GitHub `services:` uses the same mechanism but has not been run live on this image.
- **The server run as the agent, on a high port**, for example Postgres:

  ```bash
  B=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
  "$B/initdb" -D pg -A trust -U postgres
  "$B/pg_ctl" -D pg -o "-p 15433 -k $PWD -c listen_addresses=" -l pg.log -w start
  ```
`primed-register` in 1.0.0 has no option to give jobs sudo; use 1.0.1 or later.

### Conda

Miniconda is at `$CONDA` (`/usr/share/miniconda`), which is read-only to the agent: create
environments in the workspace (`conda create -p ./env …`), not in `base`.

Use of Miniconda's default channels (`repo.anaconda.com`) is subject to
[Anaconda's Terms of Service](https://www.anaconda.com/legal/terms/terms-of-service); review them
for your use. In a job, conda detects CI (`CI` on GitHub, `TF_BUILD` on Azure DevOps) and records
acceptance of those terms itself; it prints `CI detected...` and `Terms of Service accepted`. This
is upstream Miniconda behaviour, not something this image adds. Outside CI it stops and prints
instructions for accepting the channel terms. To stay off Anaconda's channels, use conda-forge:
`conda create -p ./env --override-channels -c conda-forge python=3.12`. All four behaviours (the
read-only base, acceptance in CI, the stop outside CI, and conda-forge) were verified on a 1.0.0 VM
as `primed-agent`.

### Browsers

Chrome and Firefox run headless as `primed-agent`, and Selenium drives Chrome through
`$CHROMEWEBDRIVER` (on 1.0.0, load the image environment first, see above). Microsoft Edge aborts
at startup in 1.0.0 and 1.0.1 (`The SUID sandbox helper binary was found, but is not configured
correctly`); in those releases `--no-sandbox` makes Edge run, but it turns off the browser's own
isolation, so use it only for pages you trust. From 1.0.2 (build 0.0.37), Chrome and Edge start
sandboxed: the build restores their vendor helper permissions and its build gate verifies live
rendering and the reported sandbox layers; a live check on build 0.0.37 confirmed both start
sandboxed as `primed-agent`, without `--no-sandbox`. In 1.0.0-1.0.2, bundled
`chromium-browser` aborts at startup as the job user unless started with `--no-sandbox`, and
those releases' unpinned revision can also hang in headless `--dump-dom` even with it; use
`google-chrome`.
From 1.0.3 (build 0.0.43), bundled Chromium starts with its own namespace sandbox through the
`primed-chromium` AppArmor userns profile; `--no-sandbox` is no longer needed. The previously
reported headless hang did not reproduce on pinned revision 1717344. Chromium's
`--single-process` flag is unsupported. Browsers a job downloads itself through Puppeteer or
Playwright still need `--no-sandbox`, as they do on GitHub-hosted runners. These statements cover
the browser versions baked in the image; automatic upgrades are disabled, and vendor post-install
behavior on a manual upgrade is not covered.

### Network prerequisites

Outbound HTTP to IMDS (`169.254.169.254`), HTTPS to your vault host, and the platform's own endpoints
(GitHub: `github.com`, `api.github.com`, `*.actions.githubusercontent.com`; Azure DevOps:
`dev.azure.com` and your organization's hosts). Registration downloads nothing: the agent packages
come from `/opt/primed/agents`, and the certification leg proves it with the Azure DevOps download
hosts null-routed.

### AIDE file-integrity reports

The image ships an AIDE baseline captured at build time, checked by the packaged
`dailyaidecheck.timer`. **Your first report will list expected drift** — per-VM identity that
cannot be baselined at build time (SSH host keys, `/etc/machine-id`, `/etc/hostname`,
`/etc/resolv.conf`, `/etc/random.seed`) plus the account-database changes from Azure deprovision
and first-boot cloud-init. `docs/B3-DEVIATIONS.md` enumerates this set exactly; anything beyond it
is signal.

Once your VM is configured the way you want it, re-baseline:

```bash
sudo aideinit -y -f
```

> **UNVERIFIED:** the `aideinit -y -f` invocation. It is the command named in
> `docs/B3-DEVIATIONS.md` as the intended customer re-baseline, but no test or harness in this
> repository runs it. Confirmed by: running it on a deployed VM and confirming the next
> `dailyaidecheck` report is clean.

### Break-glass access

Preferred, and requiring no open port: **Azure Serial Console**, or `az vm run-command invoke` as
used throughout this guide. **Azure Bastion** connects to the VM's private address on port 22, so
it needs the SSH rule in the image's firewall.

SSH needs **two** things: the host firewall rule and a way in through your network. The image's
firewall allows inbound SSH (`22/tcp`); you add a matching inbound NSG rule, plus a public IP or a
route to the VM. Login is limited to members of the `sudo` group.

To close SSH on the VM (the agent keeps working):

```bash
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
  --scripts 'ufw delete allow in 22/tcp && ufw status'
```

Or close it from the config: put `"ssh": false` in it (Step R3) and `primed-register` removes
the rule every time it runs, before it fetches a token or configures the agent. It then reads the
firewall back and fails (exit 5) if the firewall is not active or still lists an inbound allow for
port 22. It does not examine port ranges or allow-everything rules you added yourself.
`"ssh": true`, the default, never changes the firewall, so it does not reopen a port you closed.

Ubuntu 1.0.3 and earlier ship no SSH rule; there, `ufw allow in 22/tcp` opens it.

### Restricting egress

The image ships **default-allow outbound**. A CI runner's egress is unbounded and CDN-rotating, so
an allowlist that is wrong silently breaks builds — including the agent's own control channel.
Restricting egress is supported but is yours to design and test:

```bash
sudo ufw default deny outgoing
# then add explicit allow rules for your package feeds, registries, and the agent control channel
```

Rationale and the failure mode are in `docs/B3-DEVIATIONS.md` (`set_ufw_default_rule`).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `az vm run-command` returns empty output | The payload's interpreter died before producing output — usually a syntax error, or a shebang that is not on line 1 | Keep `#!/bin/bash` as the literal first line of the script file |
| `PRIMED_REGISTER_DIAG=vault: 403 ...`, exit 3 | The identity cannot read the secret | Grant `Key Vault Secrets User` (or get) on the vault, open the vault firewall to the VM, or add a `get` access policy |
| `PRIMED_REGISTER_DIAG=imds: ...`, exit 3 | No managed identity on the VM, or `identity_client_id` names one that is not attached | `az vm identity assign`, and check the client id |
| `PRIMED_REGISTER_DIAG=config: ...`, exit 2 | The config is rejected; the DIAG names the key (never its value) | Fix the key; a `token` key is always rejected |
| `PRIMED_REGISTER_DIAG=config.sh: ...`, exit 5 | The agent's own registration failed: an expired GitHub token (about an hour), a PAT without *Agent Pools (manage)*, or a name collision | Put a fresh credential in the vault and re-run; collisions fail on purpose rather than steal a registration |
| `PRIMED_REGISTER_DIAG=state: ...`, exit 2 or 5 | A registration exists already (other platform, marker lost, or record without marker) | Follow the DIAG: `--remove` first, or remove on the platform and `--reset`. A VM that has had sudo refuses both routes back to a registration: deploy a fresh VM |
| Runner registered but never Online | Egress to the platform is blocked | See [Network prerequisites](#network-prerequisites); `systemctl status primed-agent-github` (or `-azdo`) |
| SSH connection hangs | No NSG rule or route for port 22, or (Ubuntu 1.0.3 and earlier) no SSH rule in the image's firewall | Use `run-command` or Serial Console; see [Break-glass access](#break-glass-access) |
| A job reports `cargo: command not found` (or `ghc`, `ansible`, `yamllint`), or `JAVA_HOME_17_X64` is empty | Ubuntu 1.0.0 jobs do not get `/etc/environment` | See [Job environment](#job-environment) |
| `sudo: a password is required` in a job | The agent was registered without sudo: `"sudo": false`, `token_source: env`, or Ubuntu 1.0.3 and earlier without `"sudo": true` | See [The agent's identity](#the-agents-identity) for sudo, service containers and user-run servers |

---

## Windows Server 2025

**Not yet available — but not because of its score.** The Windows image exists, is hardened, and
**clears its launch floor**: it measures **ACPR 84.8%** (295 of 348 applicable controls) on the
CIS Windows Server 2022 22H2 v3.0.0 L1 list — **"CIS L1, Member Server" scope**, a declared proxy
until a WS2025 list ships — against a ratified **≥ 80%** floor (85% stretch). Source:
`compliance/SCOREBOARD.md`, windows `0.0.36` row; the floor and the labelling rule are
`docs/CONTRACT.md` §4.

**What holds it back is Defender and the registration entrypoint.** Defender real-time protection
is an independent G3 gate — Windows cannot list with Defender off however high the score. The
image itself is functionally proven on both platforms (0.0.36: Azure DevOps and GitHub legs
green, Windows Docker and the GitHub AC7 decoy proven live), but it has no customer registration
path until the entrypoint below ships. `docs/evidence/RELEASED.json`
blesses only Windows `0.0.2` (2026-07-02). **Do not deploy this image yet.**

The Windows `primed-register` entrypoint is not built yet (it is being redesigned as its own
change), so there is no Windows registration path in this guide. When it ships, four differences
from the Ubuntu flow will apply:

- `-Remove` may exit 8 (`PRIMED_REGISTER_STATE=reboot_required`) when the agent's profile hive is
  still loaded; reboot, then run `-Remove` again.
- `run-command` uses `--command-id RunPowerShellScript`, and parameters arrive as **`name=value`**
  pairs rather than positionally — the split is at the **first** `=`, so a value containing `=`
  (a SAS URL, for example) will be mangled.
- Agent archives are staged at `C:\primed\agents\` with targets `C:\primed\gh-runner` and
  `C:\primed\azdo-agent` (`packer/windows/scripts/build/Install-AgentPackages.ps1`).
- **Deploy contract:** the image's account policy requires an administrator password of **at least
  14 characters** with complexity. Azure's own API minimum is 12, so a 12–13 character password
  will fail in-guest provisioning (`docs/B3-DEVIATIONS.md`, account-policy row).

---

## Reference

| | |
|---|---|
| Compliance posture, all versions | `compliance/SCOREBOARD.md` |
| Every accepted deviation and its rationale | `docs/B3-DEVIATIONS.md` |
| Evidence per image version | `docs/evidence/ubuntu/<version>/` and the signed release bundle (up to 1.0.2 also `/opt/compliance/` in the image) |
| Network posture summary | `README.md` |
| What is and is not claimed | `docs/marketplace-listing.md` |

**Compliance note.** This image **supports CIS Level 1 compliance posture**, assessed with
OpenSCAP. It is not CIS certified, and deploying it does not make your environment compliant with
any standard. See the disclaimer in `docs/marketplace-listing.md`.
