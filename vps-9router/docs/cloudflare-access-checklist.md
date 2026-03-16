# Cloudflare Access Checklist for 9router

## Scope
Protect only `router.yourdomain.com`.

## DNS and SSL
1. Create `A/AAAA` record for `router.yourdomain.com` to VPS public IP.
2. Enable Cloudflare proxy (orange cloud).
3. Set SSL/TLS mode to `Full (strict)`.

## Zero Trust Access
1. Cloudflare Zero Trust -> Access -> Applications -> Add application.
2. App type: Self-hosted.
3. Domain: `router.yourdomain.com` and path `/*`.
4. Policy:
   - Include: your identity email/group only.
   - Exclude: none.
   - Deny all others.
5. Session duration: 8-24h.

## Optional WAF (secondary)
1. Add WAF custom rule for `http.host eq "router.yourdomain.com"`.
2. Add country/IP restrictions only as secondary controls.

## Anti-bypass notes
1. Keep `9router` bound to `127.0.0.1:20128`.
2. Do not expose `20128` in firewall.
3. Keep a default nginx server returning `444` for unknown hosts.

## Validation
1. Open private browser and visit `https://router.yourdomain.com`.
2. You must be challenged by Cloudflare Access before reaching dashboard.
3. Curl direct `http://<VPS_IP>:20128` from outside should fail.
