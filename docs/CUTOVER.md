# Domain cutover

This guide describes the gates for moving the package stack from temporary Firebase Hosting hostnames to custom domains. The site IDs and URLs below describe intended endpoints, not evidence that any site is deployed.

## Temporary endpoints

Each site has two Firebase Hosting hostnames:

| Site | Temporary hostnames |
| --- | --- |
| Proxy | `https://iyi-proxy.web.app`, `https://iyi-proxy.firebaseapp.com` |
| Checksum service | `https://iyi-sum.web.app`, `https://iyi-sum.firebaseapp.com` |
| Probe | `https://iyi-probe.web.app`, `https://iyi-probe.firebaseapp.com` |

Keep responses on both hostnames for every site marked `noindex` while they are temporary. An `X-Robots-Tag: noindex` response header can cover non-HTML responses as well as pages. Do not rely on a `robots.txt` block as a substitute: a crawler must be able to read the response to see its `noindex` instruction.

## Prepare the custom domains

Custom domains are opt-in. `custom_domains_enabled` defaults to `false`. Enable it through the reviewed CI path only when the domains and ownership are ready.

Use the [Firebase Hosting custom domain setup](https://firebase.google.com/docs/hosting/custom-domain) for each site. Obtain the actual records and challenge from Firebase at cutover; do not invent or reuse verification values.

1. Add the ownership TXT record Firebase provides and retain it as instructed by Firebase.
2. Follow Firebase's selected setup flow for certificate provisioning. Advanced setup may provide an ACME DNS TXT challenge or an HTTP challenge file.
3. Add the A or AAAA records Firebase requests for that flow and remove conflicting records only as directed. Preserve unrelated DNS records, including mail records.
4. Confirm ownership, certificate provisioning, and the Firebase domain status before routing users to the custom hostname.

Google's Firebase Hosting documentation does not establish a general requirement to set Cloudflare records to DNS-only during certificate provisioning. That requirement is unverified; check the current provider guidance and the actual Firebase status for the domain.

## Switch public URLs

Set the `public_base_urls` input for each service to its intended public origin. The service configuration supplies the corresponding `PUBLIC_BASE_URL` environment variable. Confirm the application uses that value before changing traffic:

- Canonical links and sitemap URLs point to the permanent hostname.
- Open Graph URLs point to the permanent hostname.
- Client and release configuration uses the intended proxy and checksum endpoints.

The proxy and checksum URLs are transport endpoints; changing them does not change module identity or the identity recorded in `iyi.sum`. Do not rewrite module paths or checksum identity merely because a service hostname changes.

Keep `noindex` in place until the permanent hostname, metadata, certificate, and application behavior are ready. Once indexing is intentionally enabled for a permanent hostname, keep temporary hostnames marked `noindex` or redirect them to their corresponding permanent URLs. Verify the response for each hostname; do not assume a site-wide header can distinguish them.

## Checksum signing identity

Until production is ready, use only the clearly named staging key and a staging log. Never present staging checkpoints as production checkpoints.

This configuration creates no production signing key, checkpoint, or log before namespace readiness. A maintainer must explicitly choose the production signing key name before signing the first production checkpoint. The key name cannot change after a production checkpoint has been published. A later proxy or checksum URL change does not change that signing identity.

`production_namespace_ready` defaults to `false`. A production cutover requires a chosen key name and separately provisioned production storage and secret resources. The flag does not generate a production key or publish a checkpoint. Keep staging and production identities separate.

The main-branch CI job generates and validates the staging key in memory,
then sends it directly to Secret Manager. Terraform does not handle the key.

