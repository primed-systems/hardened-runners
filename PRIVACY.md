# Privacy

This page covers the Primed Systems hardened runner image sold on the Azure Marketplace.

## What the image sends to us

Nothing. The image contains no telemetry and no call-home of ours, and Primed Systems runs no
service that the image contacts. We cannot see your virtual machines, your jobs, your code or
your logs.

## What a virtual machine made from the image does contact

- **GitHub or Azure DevOps**, because you register it there as a runner or agent.
- **Your own Azure Key Vault and the Azure instance metadata service**, to read the registration
  credential you put in the vault.
- **Whatever your jobs contact**: package feeds, container registries and so on.
- **The vendors of tools in the image.** Some of the pre-installed tools check for updates or
  send usage data to their own makers under their own default settings. That data goes to those
  vendors, not to us, and each tool documents how to turn it off.

## What we receive when you buy

Microsoft operates the Azure Marketplace and handles the purchase and the billing. Through the
Marketplace, Microsoft gives us:

- the contact details of the buyer: name, email address, company and country;
- how much the image was used, so that Microsoft can pay us.

We use the contact details to support the product and to tell you about security updates to
it. We do not sell them or pass them to anyone else. Microsoft's own handling of your data is
described in Microsoft's privacy statement.

## Support requests

Support is handled in this repository's public issue tracker. Anything you write there is
public, so leave out secrets, tokens, internal hostnames and anything else you would not want
others to read. For anything private, including a security problem, write to
support@primed-systems.com instead.

## Questions and requests

To ask what we hold about you, or to have it corrected or deleted, write to
support@primed-systems.com.

Last updated 2026-11-25.
