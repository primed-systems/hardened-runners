# Copy-and-paste examples: one runner VM with Terraform or Bicep

> **Draft.** The Marketplace offer is in Microsoft's review and is not live yet. The deploy
> commands below have not been run against the published offer. This notice is removed when
> they have.

Both examples create what [the quickstart](../docs/QUICKSTART.md) creates by hand: a VM from the
Primed Hardened Runner image (Trusted Launch, no public IP, no inbound rule), a managed identity
that can read one vault, and a registration config delivered by cloud-init. The VM registers itself
at first boot as a GitHub runner (deployed and proven, see below) or as an Azure DevOps agent (same
files, **UNVERIFIED**: not yet deployed).

The registration credential never goes through Terraform, Bicep, their state or their parameters.
You put it in the vault yourself, between two runs:

1. First run: network, identity and vault. No VM yet.
2. Put the credential in the vault.
3. Second run: the VM. It registers at first boot.
4. As soon as the runner is online: delete the credential and detach the identity (third run).

Each run is recorded in your variables file, not on the command line, so that a later run of the
same command keeps the VM and keeps the identity detached.

Accept the Marketplace terms for the image once per subscription first (quickstart Step 1). The VM
must be able to reach GitHub or Azure DevOps and your vault outbound (quickstart, "Network
prerequisites").

**What has been run.** On 2026-11-18 both examples were deployed as written against Ubuntu 1.0.3
for GitHub (Terraform 1.17.2 with azurerm 4.81.0; Bicep 0.41.2 with Azure CLI 2.92.0). Each VM
registered itself at first boot with `PRIMED_REGISTER=OK`, and stayed online after step 4. The
Azure DevOps setting (`platform = "azdo"`) uses the same files but has not been deployed. Since
then the image source in both files was changed from our own gallery to the Marketplace image and
its purchase plan; that change has been checked for syntax only and not yet deployed.

## Terraform

`terraform/main.tf`. Create `terraform.tfvars` next to it:

```hcl
subscription_id      = "<SUBSCRIPTION_ID>"
image_version        = "1.0.4"                  # optional; this is the default
key_vault_name       = "kv-my-runners"          # must be globally unique
admin_ssh_public_key = "ssh-ed25519 AAAA... you@example"
platform             = "github"                 # or "azdo"
url                  = "https://github.com/<OWNER>/<REPO>"   # or "https://dev.azure.com/<ORG>"
```

```bash
terraform init
terraform apply                         # 1. everything except the VM
```

Put the credential in the vault (step 2 below). Then add `deploy_vm = true` to `terraform.tfvars`
and run:

```bash
terraform apply                         # 3. the VM
```

As soon as the runner shows online, delete the credential (step 4 below), add
`attach_identity = false` to `terraform.tfvars` and run:

```bash
terraform apply                         # 4. detach the identity
```

Terraform grants the right to write the credential to the account that runs `terraform apply`. Do
step 2 as that same account.

## Bicep

`bicep/main.bicep`. Create `runner.parameters.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "keyVaultName": {"value": "kv-my-runners"},
    "adminSshPublicKey": {"value": "ssh-ed25519 AAAA... you@example"},
    "operatorObjectId": {"value": "<output of: az ad signed-in-user show --query id -o tsv>"},
    "platform": {"value": "github"},
    "url": {"value": "https://github.com/<OWNER>/<REPO>"}
  }
}
```

```bash
az group create -n rg-my-runners -l southcentralus
az deployment group create -g rg-my-runners -f main.bicep -p @runner.parameters.json   # 1.
```

Put the credential in the vault (step 2 below). Then add `"deployVm": {"value": true}` to the
parameters file and run the same command again (3.).

As soon as the runner shows online, delete the credential (step 4 below), add
`"attachIdentity": {"value": false}` to the parameters file and run the same command again (4.).

## Step 2: put the credential in the vault

Same as quickstart Step R2. The value goes through a private temporary file, never a command line:

```bash
KV=kv-my-runners                     # the vault name you chose above
umask 077
SECRET_FILE="$(mktemp)"
gh api -X POST repos/<OWNER>/<REPO>/actions/runners/registration-token --jq .token > "$SECRET_FILE"
#   Azure DevOps instead: paste the PAT into "$SECRET_FILE" with an editor; do not echo it.
az keyvault secret set --vault-name "$KV" --name runner-01-reg --file "$SECRET_FILE" \
  --expires "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" -o none
rm -f "$SECRET_FILE"
```

A GitHub registration token lasts about an hour, so do the second run within the hour. If the vault
refuses the write with `Forbidden`, either the role granted in the first run has not taken effect
yet (wait a minute and try again), or you are not the account the first run granted it to.

## Step 4: delete the credential, detach the identity

Same as quickstart Step R6: do it immediately. While the identity is attached, any job that reaches
the VM can read the vault, and jobs can reach the runner as soon as it is online. To hold jobs off
on GitHub, set `labels` to a label no workflow targets yet, and add your working labels in GitHub
(repository or organization **Settings > Actions > Runners**) after this step. Do not add them by
changing the example's `labels` afterwards: see "Changing or replacing the VM" below.

```bash
az keyvault secret delete --vault-name "$KV" --name runner-01-reg -o none
az keyvault secret purge  --vault-name "$KV" --name runner-01-reg -o none
```

Then do the detach run shown above for your tool. The runner keeps working: after registration it
uses its own credential, not the vault.

## Changing or replacing the VM

The registration config is fixed when the VM is created. Changing `labels`, `url`, the VM name or
the image version means a new VM that has to register again: Terraform plans to replace the VM;
with Bicep, delete the VM first. Before either, set `attach_identity` (`attachIdentity`) back to
true and put a fresh credential in the vault (step 2), then repeat step 4 afterwards. Remove the old
runner's registration on GitHub or Azure DevOps (quickstart Step R8). **UNVERIFIED:** this
replacement sequence has not been run.

## Check the result

GitHub: `gh api repos/<OWNER>/<REPO>/actions/runners` shows the runner `online`. Azure DevOps:
**Organization settings > Agent pools > your pool > Agents**. On the VM, the registration output is
in `journalctl -u primed-agent-bootstrap`; its last line is `PRIMED_REGISTER=OK` or
`PRIMED_REGISTER=FAIL` (quickstart Step R5 lists the exit codes).
