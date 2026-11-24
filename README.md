# Hardened GitHub Actions Runner & Azure DevOps Agent

> **Draft.** The Marketplace offer is not live yet. `<IMAGE_ID>`, `<PUBLISHER_ID>`, `<OFFER_ID>`
> and `<PLAN_ID>` are placeholders, and the deploy commands below have not been run against
> the published offer. This notice is removed when they have.

Documentation and release evidence for the Primed Systems hardened runner image, sold on the
Azure Marketplace.

- **[QUICKSTART.md](QUICKSTART.md)**: deploy a VM from the image and register it as a GitHub
  Actions self-hosted runner or an Azure DevOps agent.
- **[examples/](examples/)**: Terraform and Bicep templates that deploy and register a runner.
- **[Releases](../../releases)**: for each image release, the signed evidence bundle: the
  benchmark scan result, the list of operating-system packages, the register of known failures,
  and a manifest of file hashes. QUICKSTART.md shows how to verify the signature.

The image is built from Microsoft's open-source `actions/runner-images` project (MIT licence) on
the Ubuntu 24.04 LTS image published by Canonical, with our hardening on top. It supports CIS
Level 1 compliance posture as measured by OpenSCAP; it is not a certification. Primed Systems is
not affiliated with, endorsed by or certified by CIS or Canonical. Ubuntu is a registered
trademark of Canonical Ltd.

The build code is in a private repository. Questions and problems: <SUPPORT_CHANNEL>.
