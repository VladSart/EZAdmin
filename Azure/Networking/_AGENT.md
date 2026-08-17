# Azure Networking (Hybrid Connectivity + NSG + AVNM + Virtual WAN + Private DNS + Private Link/Private Endpoints + ExpressRoute + Azure Firewall + Point-to-Site VPN + Azure Bastion + Application Gateway + Load Balancer + Front Door) — Agent Instructions

## What's in this folder

Runbooks and scripts for **Azure networking**, covering nine related but distinct topics. **Hybrid connectivity** — the VPN Gateway (site-to-site IPsec/BGP) and ExpressRoute (private circuit) paths that connect on-premises client networks to Azure: IPsec tunnel establishment, BGP peering and route propagation on both paths, ExpressRoute's three-zone (customer/provider/Microsoft) provisioning model, and the NSG/UDR data-plane checks that come after control-plane health is confirmed. **ExpressRoute (dedicated)** — a deeper, ExpressRoute-only layer on top of the combined circuit/BGP triage in Hybrid Connectivity: the two independent peering types (Azure Private Peering and Microsoft Peering, the latter requiring an attached Route Filter to deliver any routes at all), circuit SKU tier prefix ceilings, ExpressRoute Direct, Global Reach (circuit-to-circuit interconnection, distinct from Virtual WAN's own hub routing), FastPath (data-plane gateway bypass), and ExpressRoute Gateway SKU sizing independent of circuit bandwidth. **Network Security Groups (NSG)** — the general-purpose filtering layer itself: rule priority/evaluation order, the dual subnet-level+NIC-level enforcement model, service tags, Application Security Groups, augmented rules, and Security Admin Rules via Azure Virtual Network Manager. **Azure Virtual Network Manager (AVNM)** — the centralized governance control plane that deploys connectivity (mesh/hub-and-spoke), security admin, and routing configurations across many VNets/subscriptions at once: network manager scope/delegation, static vs. dynamic (Azure-Policy-based) network group membership, the connected-group construct behind mesh topologies, and the goal-state deployment model. **Azure Virtual WAN** — the Microsoft-managed global transit-network service: the Basic/Standard SKU capability boundary (one-way upgrade), the virtual hub and its embedded BGP router (with `ProvisioningState`/`RoutingState` as two independent health signals and a fixed ASN 65515 shared by VPN and ExpressRoute gateways), the connection association/propagation model, hub route tables and labels, and Routing Intent/Routing Policies (the declarative Internet/Private traffic-steering feature whose single biggest gotcha is silently taking over the Default route table on enable). NSG is the shared data-plane checkpoint that HybridConnectivity, AVNM's own Security Admin Rules, Virtual WAN spoke traffic, `Azure/AVD/AVD-Connectivity-A.md`, and `Azure/Windows365/Windows365-A.md` all converge on — this folder is where its mechanics are fully documented once rather than repeated in each of those files. AVNM's *connectivity configuration* topologies (mesh/hub-and-spoke) are a distinct, higher layer that can, in preview, target a Virtual WAN hub as its "hub" type — that's AVNM orchestrating Virtual WAN, not a duplicate of Virtual WAN's own native hub-routing model documented in `VirtualWAN-A.md`/`VirtualWAN-B.md`. **Private DNS zones** — the name-resolution layer that sits alongside all three connectivity topics above: the Azure-provided resolver (168.63.129.16), custom vs. `privatelink.*` reserved zones, the Virtual Network Link resource (resolution-only vs. registration-enabled — and the critical fact that peering never implies a link), Private Endpoint DNS Zone Group integration, and bridging custom/on-premises DNS into Azure zones via conditional forwarding or Azure DNS Private Resolver.

Private DNS is why a Private Endpoint or AVD/Windows 365 host can be fully reachable at the network layer (NSG/UDR/peering all correct) and still fail for end users — resolution is a separate dependency chain from connectivity, and this folder is where both are documented side by side.

**Azure Firewall (Standard/Premium)** — the firewall/NVA resource's own rule and policy authoring, a distinct layer from Virtual WAN's treatment of it purely as a Routing Intent Next Hop target: Firewall Policy architecture (its own SKU tier, separate from and not automatically matching the Firewall resource's SKU), rule collection groups/collections/rules and the two-layer evaluation order (fixed NAT→Network→Application type order, THEN priority number within type), and the Premium-only feature set — TLS inspection (a genuine two-hop proxy requiring Key Vault-backed CA certificates AND client-side trust deployment), IDPS (signature-based, 67,000+ rules, per-signature override tuning), URL filtering, and advanced web categories. This is the natural next stop once `VirtualWAN-A.md`/`VirtualWAN-B.md` has confirmed traffic is actually reaching the firewall via Routing Intent — this folder's Firewall coverage picks up from there and never re-litigates the routing question.

**Point-to-Site (P2S) VPN** — a customer-managed VPN Gateway's individual-client-to-VNet configuration, architecturally distinct from the site-to-site path in Hybrid Connectivity above: the OpenVPN/SSTP/IKEv2 protocol layer, the three cross-constrained authentication types (Certificate, Microsoft Entra ID — OpenVPN-only, via the Azure VPN Client — and RADIUS pass-through), client address pool sizing, root certificate lifecycle and Azure's own periodic gateway certificate migration, and the Windows-vs-non-Windows client route-refresh asymmetry after topology changes. Does not cover the User VPN/P2S gateway type embedded in a Virtual WAN hub (a different, Microsoft-managed configuration surface — see `VirtualWAN-A.md`/`VirtualWAN-B.md`) or Always On VPN (a wholly different Windows-native, RRAS-based technology — see `Windows/Troubleshooting/AlwaysOnVPN-A.md`).

**Azure Bastion** — browser/native-client RDP-SSH-over-TLS access to VMs without a public IP, agent, or exposed 3389/22: the four architecturally distinct SKU tiers (Developer's shared infrastructure vs. Basic/Standard/Premium's dedicated deployment), the all-or-nothing 8-rule NSG requirement on `AzureBastionSubnet`, the separate target-VM-subnet NSG requirement (the most common real-world connectivity gap), connection-method availability by SKU (native client/IP-Connect/shareable links/file transfer all require Standard+; session recording and private-only deployment require Premium), and the independent JIT (Just-In-Time) access role-assignment layer. `NSG-A.md`/`NSG-B.md` and `Windows/Troubleshooting/RDP-B.md` both reference Bastion as the recommended alternative to permanently-open management ports — this is where that recommendation's own mechanics are fully documented.

**Azure Application Gateway (Standard_v2/WAF_v2)** — the inbound reverse-proxy/WAF layer Azure Firewall's own scope note above points to: the dedicated-subnet requirement and v2's GatewayManager 65200-65535 control-plane NSG dependency (missing it produces blank/Unknown backend health, not an explicit deny — the #1 real-world "backend health won't show" cause), listener/routing-rule/backend-HTTP-settings request path, health probe default-200-399-healthy matching (the most common false "backend down" cause), and WAF policy precedence across three association levels — gateway, listener, and path — where the most specific always fully overrides rather than merges with a broader policy. Distinct from Azure Firewall (outbound/East-West TLS only) and from Azure Front Door (a separate global-edge L7 service, referenced only for the disambiguation).

Does not cover Application Gateway v1 (legacy, flagged for migration rather than troubleshot on its own terms), Application Gateway for Containers (a different, Kubernetes-native product sharing only the name), User-Defined Routes/route tables as a standalone routing topic outside the hub-routing context covered here (referenced only where they intersect NSG or Virtual WAN troubleshooting), or AVNM's IP Address Management (IPAM) feature (functionally and operationally independent of connectivity/security governance, no MSP-ticket history yet).

**Azure Load Balancer (Standard SKU)** — the Layer 4 (TCP/UDP) counterpart to Application Gateway's Layer 7 scope above, and the resource most often meant (or confused with Application Gateway) when a client says "the load balancer": 5-tuple hash-based flow distribution (not round-robin, not client-affinity), health probes and their differing effect on established TCP vs. UDP flows when they fail, and — the single most consequential post-migration fact in this topic — Standard SKU's secure-by-default outbound model, where a public load balancer's backend pool has **zero implicit outbound Internet path** (unlike the now-fully-retired Basic SKU) until one of exactly three explicit methods is configured: Load Balancer outbound rules (watch default SNAT port allocation, which shrinks per instance as the backend pool grows), NAT Gateway (Microsoft's current production recommendation), or an instance-level public IP. Also covers High Availability (HA) Ports (internal-only, NVA scale-out scenarios, Floating IP/DSR mode selection) and the zone-redundant/zonal/non-zonal frontend model.

Does not cover Basic SKU Load Balancer (retired September 30, 2025 — any surviving instance is a migration finding, not a troubleshooting target — see `LoadBalancer-A.md` Playbook 1), NAT Gateway's own dedicated health/capacity diagnostics beyond confirming its presence as one of the three outbound methods (a future standalone topic if ticket volume justifies it), or Gateway Load Balancer (a distinct SKU for transparent third-party NVA chaining via VXLAN, referenced only where HA Ports' flow-symmetry limitation points to it as the alternative).

**Azure Front Door (Standard/Premium)** — the global-edge Layer 7 counterpart to Application Gateway's regional scope above, and the resource actually meant when a client describes multi-region routing, global edge caching, or a WAF block on a site fronted from more than one Azure region: the profile → endpoint → route → origin-group → origin resource hierarchy, EXACT frontend-host route matching with no wildcard-host fallback (a stricter model than the wildcard-path matching that follows it), the WAF-policy-is-a-separate-resource-until-a-Security-Policy-associates-it indirection layer, the tier ceiling where Standard WAF supports custom rules only (no managed rule set/DRS, Bot Protection, or JS Challenge — Premium-only), custom domain validation and the apex-domain certificate autorotation trap (no CNAME exists at a zone apex, so managed-certificate autorotation silently fails and needs recurring manual revalidation), Rule Set Route Configuration Override actions that can redirect traffic to a different origin group than the route's own static association, and the fail-open (round-robin across all origins) behavior when an entire origin group's health probes fail simultaneously.

Does not cover Front Door (classic) beyond identification and migration guidance (retires March 31, 2027 — no new domain onboarding or managed certificates from that point; see `FrontDoor-A.md` Playbook 1), Azure Traffic Manager (DNS-based global distribution, a fundamentally different mechanism with no proxying/caching/WAF), or Front Door's Private Link origins workflow (now its own dedicated topic — see below).

**Azure Front Door Premium — Private Link Origins** — a tight, Premium-only follow-up to both Front Door and Private Link/Private Endpoints above: Front Door acting as the Private Endpoint CONSUMER (the reverse direction from the general Private Link pattern — it creates the PE from its own Microsoft-managed regional VNet and requests approval from the origin owner, who is very often a different team than whoever manages the Front Door profile), the supported/unsupported origin type list (App Service/Storage/Storage Static Website/internal Load Balancer/API Management/Application Gateway/Container Apps — explicitly NOT App Service Slots or Static Web Apps), the resource-ID+Group-ID+region Private Endpoint reuse/dedup mechanics and its documented same-PE-different-port routing-issue trap, the mixed-origin-group platform constraint (most often tripped by converting multiple public origins to private in one non-atomic batch), and the 7200 RPS-per-regional-cluster-per-profile rate ceiling specific to Private Link traffic.

**Azure Private Link / Private Endpoints** — the client-side consumer mechanics that `PrivateDNS-A.md`/`PrivateDNS-B.md`'s general zone/link architecture, `KeyVault-A.md`/`KeyVault-B.md`, `AVD/AVD-Connectivity-A.md`, and several other files' Private Endpoint mentions all point back to as the single source of truth for this layer: the connection approval workflow (Automatic vs. Manual; Pending/Approved/Rejected/Disconnected, where only Approved carries any traffic at all); the reserved `privatelink.*` DNS zone naming convention and the Private DNS Zone Group automation layer that manages A records (the #1 real-world "DNS resolves to the public IP" root cause when absent); the hard rule against sharing one private DNS zone across two different Azure services (each service's Zone Group reconciliation silently overwrites a conflicting record from another); the six documented DNS resolution topologies spanning single-VNet, peered/hub-and-spoke, and on-premises-via-forwarder-or-Private-Resolver scenarios; and `PrivateEndpointNetworkPolicies` being disabled by default on every subnet — a structural exemption from NSG/UDR evaluation for Private Endpoint traffic, not a permissive default rule, and the source of most "my NSG change had no effect" confusion on a PE subnet.

Does not cover Private Link Service (the provider side — publishing your own service behind a Standard Load Balancer for others to consume; this topic is consumer/client-side only), Service Endpoints (an older, architecturally distinct mechanism referenced only for disambiguation — extends VNet identity via route injection but keeps the resource's public IP, versus Private Link's actual private IP in the VNet), or Azure DNS Private Resolver's own deployment/scaling/health troubleshooting as a standalone topic beyond its role as the on-premises resolution bridge (a plausible future topic of its own).

---

## Before responding, also check

- **Azure/AVD/AVD-Connectivity-A.md** — treats NSG rules and service tags specifically as they affect AVD session host reachability; use that runbook instead of this one if the ticket is AVD-specific, not general hybrid connectivity
- **Windows/Troubleshooting/AlwaysOnVPN-A.md** — a different VPN technology entirely (client-to-Azure/on-prem via Windows' native VPN client), not to be confused with the site-to-site VPN Gateway covered here
- **Security/ConditionalAccess** — if the underlying complaint is "users can't reach an app" rather than "sites can't reach each other," confirm this isn't actually a CA/identity issue before assuming a network-path fault
- **VirtualWAN-A.md/VirtualWAN-B.md vs. AzureFirewall-A.md/AzureFirewall-B.md** — if a client's Azure Firewall sits inside a Virtual WAN secured hub, "traffic isn't reaching the firewall" is a Routing Intent/Next Hop question (VirtualWAN files); "traffic reaches the firewall but is allowed/denied unexpectedly, or a Premium feature isn't working" is a rule/policy question (AzureFirewall files) — don't debug rule content on a firewall traffic never reached
- **AppGateway-A.md/AppGateway-B.md vs. AzureFirewall-A.md/AzureFirewall-B.md** — Application Gateway is the inbound reverse-proxy/WAF layer (HTTP/HTTPS, terminates client-facing TLS, Layer 7 routing to a backend pool); Azure Firewall is a general-purpose outbound/East-West filter that does not do inbound reverse-proxying. A "site returns 403/502/504" ticket belongs in AppGateway files even if an Azure Firewall also sits somewhere in the path
- **LoadBalancer-A.md/LoadBalancer-B.md vs. AppGateway-A.md/AppGateway-B.md** — Load Balancer is Layer 4 only (TCP/UDP, 5-tuple hash, zero path/host/cookie/WAF awareness); Application Gateway is Layer 7. A client saying "the load balancer" while describing path-based routing, a WAF block, or hostname rules is describing Application Gateway — confirm which resource actually fronts the traffic before troubleshooting the wrong one. Both files carry this disambiguation in their own Learning Pointers.
- **FrontDoor-A.md/FrontDoor-B.md vs. AppGateway-A.md/AppGateway-B.md vs. LoadBalancer-A.md/LoadBalancer-B.md** — all three distribute traffic, but at different scopes: Front Door is GLOBAL edge (multi-region, DNS-resolved to Microsoft's edge network, its own WAF-tier model); Application Gateway is REGIONAL Layer 7 (single-region reverse proxy/WAF); Load Balancer is REGIONAL Layer 4. A client describing multi-region failover, global edge caching, or a `*.azurefd.net` hostname is describing Front Door — confirm scope (global vs. regional) before assuming it's the same troubleshooting model as the other two.
- **PrivateLink-A.md/PrivateLink-B.md vs. PrivateDNS-A.md/PrivateDNS-B.md** — Private Link/Private Endpoints is the resource-connectivity layer (creating the NIC, the approval workflow, the Zone Group automation); Private DNS is the general zone/link/registration mechanics that layer depends on. A "Private Endpoint resolves to the public IP" ticket usually starts in PrivateLink-B.md's Zone Group check, which then points into PrivateDNS-B.md's link/zone mechanics if the gap is at that layer — the two files are deliberately complementary, not duplicative.
- **FrontDoorPrivateLink-A.md/FrontDoorPrivateLink-B.md vs. PrivateLink-A.md/PrivateLink-B.md** — Front Door's Private Link origin feature is a Premium-only, Front-Door-specific application of Private Link where FRONT DOOR is the consumer (creates the PE, requests approval) — the reverse of the general client-consumes-a-PaaS-resource pattern documented generically in `PrivateLink-A.md`. A ticket about a Front Door origin's connection state belongs in `FrontDoorPrivateLink-B.md` first; only fall back to the general `PrivateLink-B.md` mechanics if the question is about DNS/Zone Group behavior once traffic is already flowing privately.
- **PrivateLink-A.md/PrivateLink-B.md vs. NSG-A.md/NSG-B.md** — NSG's general rule-evaluation architecture assumes it's actually being evaluated; Private Link's `PrivateEndpointNetworkPolicies` (disabled by default) determines whether NSG/UDR apply to Private Endpoint traffic AT ALL. An NSG rule that "does nothing" on a PE subnet is a PrivateLink-B.md Fix 7 question before it's an NSG-B.md rule-priority question.

---

## Folder contents

| File | What it covers |
|------|----------------|
| `HybridConnectivity-B.md` | Hotfix runbook — IPsec tunnel down, BGP peer not connecting/flapping, ExpressRoute circuit/provider provisioning stuck, eBGP peering mismatch, routes present but traffic blocked |
| `HybridConnectivity-A.md` | Deep dive — full IPsec/BGP and ExpressRoute three-zone architecture, dependency stack from physical/provisioning layer through data plane, migration and provider-outage playbooks |
| `Scripts/Get-HybridConnectivityHealth.ps1` | Read-only sweep across VPN Gateways and ExpressRoute circuits — connection/BGP/peering state, near-prefix-limit warning, control-plane-vs-data-plane traffic sanity check |
| `ExpressRoute-B.md` | ExpressRoute hotfix runbook — peering-specific triage (Private vs. Microsoft), missing Route Filter on Microsoft Peering, eBGP Idle/Connect (VLAN/ASN/subnet/MD5 mismatch), Global Reach authorization-not-redeemed, FastPath/gateway-SKU throughput issues, SKU tier prefix-ceiling confusion |
| `ExpressRoute-A.md` | ExpressRoute deep dive — three-party (customer/provider/Microsoft) provisioning model, independent Private/Microsoft peering architecture, Route Filters, ExpressRoute Direct, Global Reach, FastPath, gateway SKU sizing, Connection Monitor/Traffic Collector visibility |
| `Scripts/Get-ExpressRouteCircuitAudit.ps1` | Read-only sweep across every ExpressRoute circuit — provisioning state (both parties), peering state, missing Route Filters, single-link (non-redundant) BGP sessions, prefix-ceiling warnings by SKU tier, Global Reach NotConnected, FastPath-not-enabled flags |
| `NSG-B.md` | NSG hotfix runbook — priority conflicts, subnet/NIC dual-layer conflicts, service tag and ASG misconfigurations, default-deny blocks, Security Admin Rule check |
| `NSG-A.md` | NSG deep dive — rule evaluation architecture, Security Admin Rules (AVNM), service tags, ASGs, augmented rules, flow log migration (NSG flow logs retiring Sept 30, 2027) |
| `Scripts/Get-NSGRuleAudit.ps1` | Read-only fleet-wide sweep — broad management-port exposure, priority-collision risk, dual-layer NIC/subnet coverage inventory, Security Admin Rule presence |
| `AVNM-B.md` | AVNM hotfix runbook — VNet not receiving configuration (scope/never-deployed), dynamic membership lag, goal-state redeploy trap, "use hub as gateway" silent partial-peering, mesh IP-overlap drops |
| `AVNM-A.md` | AVNM deep dive — scope/delegation model, network groups (static/dynamic), connectivity configuration architecture (mesh/hub-and-spoke/connected groups), goal-state deployment model, migration and fleet-audit playbooks |
| `Scripts/Get-AVNMConfigAudit.ps1` | Read-only sweep — network group membership (flags empty static groups), configurations defined but never deployed, multi-config goal-state risk regions, failed deployments, optional single-VNet effective-state check |
| `VirtualWAN-B.md` | Virtual WAN hotfix runbook — hub/router health split (ProvisioningState vs. RoutingState), Basic-SKU capability gaps, Routing Intent's Default-route-table takeover on enable, shared-ASN (65515) VPN/ExpressRoute gateway conflicts, connection association checks |
| `VirtualWAN-A.md` | Virtual WAN deep dive — Basic/Standard SKU architecture, virtual hub router, connection association/propagation/labels model, Routing Intent and secured virtual hub architecture, scale limits, greenfield/retrofit/SKU-upgrade/fleet-audit playbooks |
| `Scripts/Get-VirtualWANHealth.ps1` | Read-only sweep across every Virtual WAN — hub/router health, Basic-SKU gateway anomalies, half-finished secured-hub builds (Firewall present, no Routing Intent), inconsistent branch/spoke route-table association, optional ExpressRoute prefix-count flag |
| `PrivateDNS-B.md` | Private DNS hotfix runbook — Private Endpoint resolving to public IP (missing/broken Zone Group), peered VNet not linked to a zone, custom DNS not forwarding to 168.63.129.16, missing DNS suffix search list, stale autoregistered records |
| `PrivateDNS-A.md` | Private DNS deep dive — zone/link/registration architecture, `privatelink.*` reserved zone naming, Zone Group mechanics, Azure DNS Private Resolver for hybrid forwarding, fleet-wide remediation playbooks |
| `Scripts/Get-PrivateDNSZoneAudit.ps1` | Read-only sweep — orphaned zones with no links, peered-but-unlinked VNets, Private Endpoints missing or with unhealthy DNS Zone Groups, stale autoregistered records vs. current VM inventory |
| `AzureFirewall-B.md` | Azure Firewall hotfix runbook — SKU/policy-SKU mismatch, priority/rule-type evaluation-order conflicts, TLS inspection certificate/trust issues, IDPS false-positive tuning, DNAT-without-matching-Network-rule |
| `AzureFirewall-A.md` | Azure Firewall deep dive — SKU tier feature ceiling (Basic/Standard/Premium), Firewall Policy architecture and inheritance via Firewall Manager, two-layer rule evaluation order (type then priority), TLS inspection proxy architecture and certificate chain, IDPS signature model, greenfield/retrofit/SKU-migration/fleet-audit playbooks |
| `Scripts/Get-AzureFirewallPolicyAudit.ps1` | Read-only sweep — Firewall vs. Policy SKU tier mismatches, TLS inspection certificate expiry/misconfiguration, IDPS posture and signature-override tuning-debt, Rule Collection Group priority collisions, DNAT-without-Network-rule heuristic flag |
| `P2SVPN-B.md` | P2S VPN hotfix runbook — gateway SKU capability ceiling (Basic SKU + IKEv2/RADIUS), address pool exhaustion, missing/wrong root cert, stale client profile after topology change, RADIUS unreachable, Entra ID Audience mismatch |
| `P2SVPN-A.md` | P2S VPN deep dive — protocol/auth cross-constraint matrix, client profile lifecycle, Windows-vs-non-Windows route-refresh asymmetry, greenfield/migration/diagnosis playbooks |
| `Scripts/Get-P2SVPNGatewayHealth.ps1` | Read-only sweep — Basic SKU feature-gap detection, address pool/root-cert/RADIUS/Entra ID configuration presence, optional best-effort RADIUS reachability probe |
| `Bastion-B.md` | Bastion hotfix runbook — AzureBastionSubnet NSG 8-rule completeness, target-VM-subnet NSG gap (most common real fault), black screen diagnosis, SKU feature ceiling, JIT role-assignment gap |
| `Bastion-A.md` | Bastion deep dive — four-SKU architecture comparison, all-or-nothing NSG rule requirement, connection-method availability matrix, greenfield/SKU-upgrade/multi-VNet playbooks |
| `Scripts/Get-AzureBastionHealth.ps1` | Read-only sweep — SKU/provisioning state, AzureBastionSubnet sizing compliance, NSG rule-completeness check against the full 8-rule set, optional target-VM-subnet NSG check |
| `AppGateway-B.md` | Application Gateway hotfix runbook — backend health Unknown-for-all (GatewayManager NSG gap) vs. Unhealthy-for-specific-servers (probe misconfiguration), WAF 403 false-positive tuning, 502/504 with healthy backend (timeout/Proxy Protocol), WAF policy precedence override diagnosis, SNAT/capacity exhaustion |
| `AppGateway-A.md` | Application Gateway deep dive — v2 dedicated-subnet and control-plane architecture, listener/routing-rule/backend-HTTP-settings request path, health probe default-match behavior, three-level WAF policy precedence (gateway/listener/path, full override not merge), autoscale/SNAT capacity model, Front-Door/Azure-Firewall disambiguation |
| `Scripts/Get-AppGatewayHealth.ps1` | Read-only sweep across every Application Gateway — provisioning state and legacy-v1-SKU flag, dedicated-subnet GatewayManager 65200-65535 NSG rule check, per-server backend health (flags all-Unknown as a likely NSG issue distinct from real per-server Unhealthy), WAF policy mode and precedence at all three association levels, backend HTTP settings timeout/HostName flags, diagnostic settings presence, autoscale configuration |
| `LoadBalancer-B.md` | Load Balancer hotfix runbook — Basic SKU (retired/unsupported) flag, no-outbound-path diagnosis for public LB backends (the #1 post-migration ticket), SNAT port exhaustion under load, NSG explicit-allow gap (Standard SKU has no implicit inbound permit), probe-hitting-a-WinHTTP-restricted-port diagnosis, HA Ports Floating IP mode mismatch, Layer 7 symptom redirect to Application Gateway |
| `LoadBalancer-A.md` | Load Balancer deep dive — 5-tuple hash distribution model, health probe behavior on established TCP vs. UDP flows, the three explicit outbound-access methods and their precedence, default vs. manual SNAT port allocation, HA Ports Floating IP/DSR architecture and flow-symmetry limits, zone-redundant/zonal frontend model, Basic SKU migration playbook |
| `Scripts/Get-LoadBalancerHealth.ps1` | Read-only sweep across every Load Balancer — Basic SKU flag, frontend type/zone configuration, backend pool membership and health, probe restricted-port check, outbound-access-method detection for public LB backends (flags a genuine zero-method gap), SNAT allocation vs. backend pool size, NSG presence on backend subnets, HA Ports rule/Floating-IP-mode detection |
| `FrontDoor-B.md` | Front Door hotfix runbook — Classic-tier migration flag, disabled-endpoint diagnosis, custom domain validation/apex-certificate-autorotation triage, exact-host-match 404 diagnosis, origin health probe troubleshooting, WAF tier-ceiling diagnosis (Standard = custom rules only), Rule Set Route Configuration Override detection, stale-cache purge guidance |
| `FrontDoor-A.md` | Front Door deep dive — profile/endpoint/route/origin-group resource hierarchy, exact-host + most-specific-path route matching architecture, 3-step health probe determination and fail-open behavior, custom domain validation and the apex-domain certificate autorotation trap, WAF-policy-is-a-separate-resource-until-associated model and tier capability ceiling, Rule Set Route Configuration Override precedence, Classic-to-Standard/Premium migration and domain-onboarding playbooks |
| `Scripts/Get-FrontDoorHealth.ps1` | Read-only sweep across every Front Door profile — Classic SKU flag, endpoint EnabledState, custom domain validation state with an apex-domain certificate-autorotation-risk flag, domain-to-route association gap check, origin group health/probe configuration (flags empty groups), WAF tier-gap detection when a Standard-tier policy is associated to a domain, Rule Set presence flag for manual Route Configuration Override review |
| `FrontDoorPrivateLink-B.md` | Front Door Premium Private Link origin hotfix runbook — Pending-connection-needs-origin-side-approval triage, Rejected/Timeout dead-connection rebuild, mixed public/private origin group error diagnosis, same-PE-different-port routing trap, transient post-approval establishment window, 7200 RPS/region/profile 429 diagnosis, unsupported-mTLS clarification, "no access" Portal PE-object explanation |
| `FrontDoorPrivateLink-A.md` | Front Door Premium Private Link origin deep dive — reversed PE-consumer architecture (Front Door creates the endpoint, the origin owner approves), supported/unsupported origin type table, region-availability/latency trade-off, Private Endpoint reuse-by-tuple and shared-PE port-conflict mechanics, mixed-origin-group sequential-update pitfall, rate-limit architecture and multi-region mitigation, mTLS non-support, greenfield/conversion/rate-limit-relief playbooks |
| `Scripts/Get-FrontDoorPrivateLinkAudit.ps1` | Read-only sweep across every Front Door profile's origins — Private Link connection-state flag (Pending/dead-connection), tier-mismatch sanity check, mixed-origin-group detection, shared-Private-Endpoint port-conflict detection, best-effort supported-region reference-list check; explicitly does not approve origin-side connections or query live RPS metrics |
| `PrivateLink-B.md` | Private Link/Private Endpoint hotfix runbook — connection approval-state triage (Pending/Rejected/Disconnected all carry zero traffic), DNS-resolves-to-public-IP diagnosis (the #1 real-world ticket), missing/empty Zone Group, missing VNet link for the client's own VNet (peering never implies one), cross-service zone record contamination, `PrivateEndpointNetworkPolicies`-disabled NSG-has-no-effect diagnosis, on-premises resolution bridging |
| `PrivateLink-A.md` | Private Link/Private Endpoint deep dive — connection state machine and owner-vs-consumer action model, `privatelink.*` reserved DNS zone naming and Zone Group automation architecture, the six documented DNS resolution topologies (VNet/peered/on-prem × with or without Azure Private Resolver), network policy (NSG/UDR/ASG) subnet-level exemption model and its documented limitations, static-IP-unsupported resource types, Service-Endpoint disambiguation |
| `Scripts/Get-PrivateEndpointAudit.ps1` | Read-only sweep across every Private Endpoint — connection approval state flag, DNS Zone Group presence, per-zone Virtual Network Link coverage check against the endpoint's own VNet, cross-service zone record-contamination heuristic, best-effort live DNS resolution vs. private-IP-range check, subnet `PrivateEndpointNetworkPolicies` state (informational) |

---

## Common entry points

- **"Site-to-site VPN won't connect"** → `HybridConnectivity-B.md` Fix 1 — confirm IPsec tunnel before touching BGP
- **"BGP won't come up over our VPN"** → `HybridConnectivity-B.md` Triage row 2 — BGP cannot start until the IPsec tunnel itself is Connected
- **"VPN BGP session keeps dropping"** → `HybridConnectivity-B.md` Fix 3 — check for IPsec tunnel flapping and packet loss against the fixed 180s hold timer (no BFD support)
- **"ExpressRoute circuit shows Not provisioned"** → `HybridConnectivity-B.md` Triage — split Microsoft-side vs. provider-side immediately, escalate to the correct owner
- **"ExpressRoute BGP peering Active/Idle instead of Established"** → `HybridConnectivity-B.md` Fix 4 — VLAN/ASN/subnet/MD5 mismatch against the linked CE/PE-MSEE
- **"Routes look fine but traffic still doesn't reach the destination"** → `HybridConnectivity-B.md` Fix 5 — check GatewaySubnet and destination-subnet NSG/UDR
- **"Should we move this client from static routes to BGP?"** → `HybridConnectivity-A.md` Playbook 1
- **"Fleet-wide hybrid connectivity health check across clients"** → `Scripts/Get-HybridConnectivityHealth.ps1`
- **"Microsoft Peering is Provisioned/Enabled but we're not getting any M365 routes"** → `ExpressRoute-B.md` Fix 1 — check for a missing Route Filter, the peering's health tells you nothing about whether one is attached
- **"Two of our on-prem sites, each on their own ExpressRoute circuit, can't reach each other"** → `ExpressRoute-B.md` Fix 4 — Global Reach not configured, or an authorization was created but never redeemed on the peer circuit
- **"ExpressRoute circuit and gateway both show healthy but throughput is below what we're paying for"** → `ExpressRoute-B.md` Fix 5 — check gateway SKU vs. circuit bandwidth, and FastPath status
- **"On-prem routes missing past a certain count on ExpressRoute"** → `ExpressRoute-B.md` Fix 6 — check `Sku.Tier` (not `Sku.Family`) prefix ceiling, not just `HybridConnectivity-B.md`'s general prefix-limit check
- **"Fleet-wide ExpressRoute circuit/peering/Global Reach/FastPath audit across clients"** → `Scripts/Get-ExpressRouteCircuitAudit.ps1`
- **"I added an NSG allow rule and traffic is still blocked"** → `NSG-B.md` Fix 1 (priority conflict) then Fix 2 (subnet/NIC dual-layer gap)
- **"NSG rules look correct but traffic still misbehaves"** → `NSG-B.md` Triage step 5 — check for a Security Admin Rule (Azure Virtual Network Manager) first
- **"Rule uses a service tag and doesn't behave as expected"** → `NSG-B.md` Fix 3 — `VirtualNetwork` includes peered VNets + on-prem + gateway VIP, not just the local VNet
- **"Client wants NSG flow logs turned on"** → redirect to VNet flow logs; NSG flow logs can no longer be newly created (cutoff June 30, 2025, retiring Sept 30, 2027) — see `NSG-A.md` Learning Pointers
- **"Fleet-wide NSG hygiene / exposed management-port review"** → `Scripts/Get-NSGRuleAudit.ps1`
- **"I deployed an AVNM connectivity config and nothing happened"** → `AVNM-B.md` Fix 1 — check scope, then check it was actually deployed to the VNet's region (configurations are inert until deployed)
- **"New VNet isn't picking up our dynamic network group policy"** → `AVNM-B.md` Fix 2 — Azure Policy evaluation lag (~30 min, up to 24h at scale), not necessarily a bug
- **"I can't find the peering for our AVNM mesh connection"** → `AVNM-B.md` Triage — mesh is realized as a connected group, never a peering resource; check effective connectivity config or effective routes instead
- **"A previously-working AVNM connection broke after an unrelated change"** → `AVNM-A.md` Playbook 2 — goal-state redeploy trap, the unrelated deploy likely omitted this configuration
- **"Hub-and-spoke peering is one-sided (hub→spoke exists, spoke→hub doesn't)"** → `AVNM-B.md` Fix 4 — hub gateway didn't exist yet when "use hub as gateway" was deployed
- **"Fleet-wide AVNM configuration health check across clients"** → `Scripts/Get-AVNMConfigAudit.ps1`
- **"Our Virtual WAN hub shows healthy but I can't update routes"** → `VirtualWAN-B.md` Fix 1 — `ProvisioningState`/`RoutingState` are independent; use "Reset router," not a full hub reset
- **"Client wants ExpressRoute/P2S/Firewall/Routing Intent but the portal won't let them"** → `VirtualWAN-B.md` Fix 3 — Virtual WAN is on the `Basic` SKU; plan a one-way upgrade to Standard
- **"Our Virtual WAN static route disappeared after we set up the firewall"** → `VirtualWAN-B.md` Fix 4 — enabling Routing Intent silently took over the Default route table and connection associations
- **"Traffic isn't going through our Azure Firewall in Virtual WAN"** → `VirtualWAN-B.md` Triage — confirm the spoke's Hub VNet connection is associated to the route table Routing Intent manages
- **"Some on-prem routes aren't reaching the other gateway type in the same hub"** → `VirtualWAN-B.md` Fix 6 — both VPN and ExpressRoute gateways share a fixed ASN 65515; check for an on-prem ASN collision
- **"Should we move this client from traditional hub-and-spoke to Virtual WAN?"** → `VirtualWAN-A.md` Learning Pointers — a genuine trade-off conversation, not a strict upgrade; Virtual WAN earns its overhead mainly at 30+ spokes or 3+ regions
- **"Fleet-wide Virtual WAN health check across clients"** → `Scripts/Get-VirtualWANHealth.ps1`
- **"Our Private Endpoint resolves to the public IP, not the private one"** → `PrivateDNS-B.md` Fix 1 — check the DNS Zone Group first, not the zone or link
- **"Resolution works from the hub VNet but not the peered spoke"** → `PrivateDNS-B.md` Fix 2 — peering never implies a DNS zone link; the spoke needs its own link
- **"We pointed the VNet at our own DNS server and now private zone names don't resolve"** → `PrivateDNS-B.md` Fix 3 — custom DNS must forward the zone's suffix to 168.63.129.16, or deploy Azure DNS Private Resolver for hybrid
- **"On-prem can't resolve our Azure private DNS names"** → `PrivateDNS-A.md` Playbook 3 — Azure DNS Private Resolver is the current recommended bridge, not a manual forwarder VM
- **"A deleted VM's hostname still resolves to its old IP"** → `PrivateDNS-B.md` Fix 6 — stale autoregistered record, safe to remove manually
- **"Fleet-wide Private DNS hygiene check across clients"** → `Scripts/Get-PrivateDNSZoneAudit.ps1`
- **"Client wants IDPS/TLS inspection/URL filtering and the portal won't show it"** → `AzureFirewall-B.md` Fix 1 — confirm Firewall SKU is genuinely Premium first, this is a SKU ceiling not a setting
- **"Firewall is Premium but I can't find the TLS inspection blade"** → `AzureFirewall-B.md` Fix 2 — check the Firewall POLICY's own SKU, it's separate from and doesn't auto-match the Firewall resource's SKU
- **"I added an allow rule and traffic is still denied"** → `AzureFirewall-B.md` Fix 3 — check rule-TYPE evaluation order (NAT→Network→Application, fixed) before assuming it's a priority-number issue
- **"TLS inspection is on but HTTPS sites won't load / cert warnings"** → `AzureFirewall-B.md` Fix 4 — almost always the Root CA never got pushed to client devices, not a policy problem
- **"IDPS is blocking something legitimate"** → `AzureFirewall-B.md` Fix 5 — override the specific Signature ID, never drop the policy-wide IDPS mode
- **"DNAT rule configured but inbound traffic still fails"** → `AzureFirewall-B.md` Fix 6 — check for a missing companion Network rule and confirm the Public IP/IpConfiguration binding
- **"Fleet-wide Azure Firewall policy hygiene audit across clients"** → `Scripts/Get-AzureFirewallPolicyAudit.ps1`
- **"A remote user can't connect to our P2S VPN"** → `P2SVPN-B.md` Triage — confirm gateway SKU capability first (Basic silently doesn't support IKEv2/RADIUS)
- **"P2S worked yesterday, some users broken today, others fine"** → `P2SVPN-B.md` Fix 3 — stale Windows client profile after a topology change; non-Windows clients refresh routes automatically, Windows doesn't
- **"P2S users authenticating via RADIUS all failing at once"** → `P2SVPN-B.md` Fix 4 — check the gateway's own S2S tunnel to on-prem RADIUS first, not the P2S config itself
- **"Fleet-wide P2S VPN Gateway configuration health check across clients"** → `Scripts/Get-P2SVPNGatewayHealth.ps1`
- **"Can't create/apply an NSG on AzureBastionSubnet"** → `Bastion-B.md` Fix 1 — missing one or more of the 8 required rules, applied together not incrementally
- **"Azure Bastion shows a black screen, no error"** → `Bastion-B.md` Fix 4 / Fix 2 — almost always the TARGET VM subnet's NSG, not the Bastion subnet's
- **"Native RDP/SSH client / file transfer / IP-Connect not available in Bastion"** → `Bastion-B.md` Fix 3 — feature requires Standard or Premium SKU, not a bug
- **"User can see the VM in the portal but Bastion connection is still blocked"** → `Bastion-B.md` Fix 6 — missing JIT role assignment, independent of Bastion/NSG configuration
- **"Fleet-wide Azure Bastion SKU/subnet/NSG health check across clients"** → `Scripts/Get-AzureBastionHealth.ps1`
- **"Application Gateway backend health shows blank/Unknown for every server"** → `AppGateway-B.md` Fix 2 — check the GatewayManager 65200-65535 NSG rule on the gateway's own subnet before assuming a real backend outage
- **"Some Application Gateway backend servers show Unhealthy, others fine"** → `AppGateway-B.md` Fix 2 — check the probe path/expected match; a 401/403/302 response is outside the default 200-399 healthy range
- **"Users see a 403 with a WAF-branded error page"** → `AppGateway-B.md` Fix 3 — WAF Prevention-mode block, add a targeted rule exclusion, don't disable the whole managed rule set
- **"502/504 errors but backend health shows Healthy"** → `AppGateway-B.md` Fix 4 — check RequestTimeout and, on HTTPS backend settings with client IP preservation, whether the backend parses the Proxy Protocol header
- **"One path or site on the gateway behaves differently than the rest"** → `AppGateway-B.md` Fix 5 — check for a listener- or path-level WAF policy override; most specific fully overrides, doesn't merge with the gateway-level policy
- **"Client wants to know why WAF rule updates seem to have stopped applying"** → `AppGateway-A.md` Learning Pointers — confirm outbound Internet isn't blocked on the gateway subnet, WAF_v2 needs it for engine/signature updates
- **"Fleet-wide Application Gateway backend health / WAF policy precedence audit across clients"** → `Scripts/Get-AppGatewayHealth.ps1`
- **"We migrated off Basic Load Balancer and now our VMs can't reach the internet"** → `LoadBalancer-B.md` Fix 2 — Standard SKU has zero implicit outbound path, one of three explicit methods must be configured
- **"Load balancer outbound worked fine, now fails intermittently under load"** → `LoadBalancer-B.md` Fix 3 — SNAT port exhaustion, usually a large backend pool still on default port allocation
- **"Client can't reach our public load balancer frontend, no NSG deny logged"** → `LoadBalancer-B.md` Fix 4 — Standard SKU is secure-by-default, NSG must explicitly allow, nothing is implicit
- **"Load balancer health probe shows everything Unhealthy but the app works fine directly"** → `LoadBalancer-B.md` Fix 5 — check the probe port against the WinHTTP HTTP-probe restricted-port list first
- **"Client describes path-based routing or a WAF block on 'the load balancer'"** → `LoadBalancer-B.md` Fix 6 — this is almost always Application Gateway, not this Layer 4 resource; redirect to `AppGateway-B.md`
- **"We still have a Basic SKU load balancer in this environment"** → `LoadBalancer-B.md` Fix 1 / `LoadBalancer-A.md` Playbook 1 — retired Sept 30, 2025, unsupported, schedule a migration
- **"Fleet-wide Load Balancer SKU/outbound-access/probe hygiene audit across clients"** → `Scripts/Get-LoadBalancerHealth.ps1`
- **"Client wants to onboard a new domain on Front Door and it's stuck on validation"** → `FrontDoor-B.md` Fix 3 — check the `_dnsauth` TXT record first; if it's an apex domain, there's no CNAME and autorotation needs manual revalidation
- **"An apex domain's HTTPS broke with no recent config change"** → `FrontDoor-B.md` Fix 3 / `FrontDoor-A.md` Learning Pointers — managed-certificate autorotation silently fails on apex domains, this is a recurring operational task, not a one-time setup
- **"A hostname 404s on Front Door even though a route exists for the site"** → `FrontDoor-B.md` Fix 4 — Front Door requires an EXACT frontend host match, there's no wildcard-host fallback the way there is for paths
- **"Front Door origin health shows everything Unhealthy but the app works directly"** → `FrontDoor-B.md` Fix 5 — check probe path/protocol match and confirm nothing origin-side is blocking Front Door's own probe traffic
- **"I set up a WAF policy on Front Door and it's not blocking common attacks"** → `FrontDoor-B.md` Fix 6 — confirm tier first; Standard supports custom rules only, no managed rule set/Bot Protection/JS Challenge without Premium
- **"Traffic on Front Door goes to the wrong origin group despite the route looking correct"** → `FrontDoor-B.md` Fix 7 — check the route's attached Rule Set for a Route Configuration Override action
- **"Client still has a Front Door (classic) profile"** → `FrontDoor-B.md` Fix 1 / `FrontDoor-A.md` Playbook 1 — retires March 31, 2027, no new domains/certs from that point, schedule a migration
- **"Fleet-wide Front Door tier/domain-validation/origin-health/WAF-tier audit across clients"** → `Scripts/Get-FrontDoorHealth.ps1`
- **"We enabled Private Link on a Front Door origin and nothing connects"** → `FrontDoorPrivateLink-B.md` Fix 2 — check `SharedPrivateLinkResource.Status`; the ORIGIN owner must approve it, this doesn't happen automatically even in the same tenant
- **"Origin Group can only have origins with private links or origins without private links" error on Front Door** → `FrontDoorPrivateLink-B.md` Fix 4 — almost always from converting multiple public origins to private at the same time; convert one at a time
- **"Front Door origins on the same backend with different ports behave inconsistently"** → `FrontDoorPrivateLink-B.md` Fix 5 — a shared Private Endpoint (same resource ID/Group ID/region) with mismatched ports is a documented platform limitation
- **"Front Door Private Link origin returning 429s under load"** → `FrontDoorPrivateLink-B.md` Fix 7 — check against the 7200 RPS/regional-cluster/profile cap before assuming an origin-side throttle
- **"Client wants mTLS between Front Door and a Private Link origin"** → `FrontDoorPrivateLink-B.md` Fix 8 — unsupported on Front Door entirely, public or private origins, not a missing setting
- **"Fleet-wide Front Door Private Link origin connection-state/mixed-group/port-conflict audit across clients"** → `Scripts/Get-FrontDoorPrivateLinkAudit.ps1`
- **"Our Private Endpoint resolves to the resource's public IP instead of the private one"** → `PrivateLink-B.md` Fix 3 — check the DNS Zone Group first, not the zone or link directly
- **"Private Endpoint exists, DNS even looks right, but nothing connects"** → `PrivateLink-B.md` Fix 1/2 — check connection approval state before anything else; only Approved carries traffic
- **"A working Private Endpoint suddenly broke right after we deployed an unrelated one for a different service"** → `PrivateLink-B.md` Fix 6 — two services sharing one private DNS zone, the new one's Zone Group overwrote the old record
- **"Private Endpoint resolves fine in the hub VNet but not a peered spoke"** → `PrivateLink-B.md` Fix 5 — VNet peering never implies a private DNS zone link, the spoke needs its own explicit link
- **"I added an NSG rule to the Private Endpoint's subnet and it has no effect at all"** → `PrivateLink-B.md` Fix 7 — `PrivateEndpointNetworkPolicies` is disabled by default; NSG/UDR are structurally not evaluated for PE traffic until enabled
- **"On-premises users can't resolve our Private Endpoint's FQDN, but VNet clients can"** → `PrivateLink-B.md` Fix 8 / `PrivateLink-A.md` Playbook 3 — needs a DNS forwarder or Azure Private Resolver bridge; on-prem can't query 168.63.129.16 directly
- **"Fleet-wide Private Endpoint connection-state/DNS-Zone-Group/network-policy audit across clients"** → `Scripts/Get-PrivateEndpointAudit.ps1`

---

## Key diagnostic commands

```powershell
# VPN Gateway type, SKU, BGP capability — always check first
Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName> | Select GatewayType, VpnType, Sku, EnableBgp

# VPN tunnel (connection) status — confirm before troubleshooting BGP
Get-AzVirtualNetworkGatewayConnection -ResourceGroupName <rg> -Name <connectionName> | Select ConnectionStatus

# VPN BGP peer state and route counts
Get-AzVirtualNetworkGatewayBgpPeerStatus -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName>

# ExpressRoute circuit + provider provisioning state
Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName> | Select CircuitProvisioningState, ServiceProviderProvisioningState

# ExpressRoute MSEE route table (eBGP peering state lives here)
Get-AzExpressRouteCircuitRouteTable -DevicePath Primary -ExpressRouteCircuitName <circuitName> -PeeringType AzurePrivatePeering -ResourceGroupName <rg>

# ExpressRoute — both peering types' state + whether Microsoft Peering has a Route Filter attached
(Get-AzExpressRouteCircuit -ResourceGroupName <rg> -Name <circuitName>).Peerings | Select PeeringType, ProvisioningState, State, RouteFilter

# ExpressRoute — Global Reach connection state (circuit-to-circuit, not circuit-to-VNet)
Get-AzExpressRouteCircuitConnectionConfig -ResourceGroupName <rg> -ExpressRouteCircuitName <circuitName>

# ExpressRoute — FastPath status on the connection (gateway-bypass for data plane only)
Get-AzExpressRouteConnection -ResourceGroupName <rg> -ExpressRouteGatewayName <gatewayName> | Select FastPathEnabled

# Effective NSG rules for a NIC — the pre-merged, authoritative view
az network nic list-effective-nsg --resource-group <rg> --name <nicName> -o table

# Synthetic packet test — allowed or denied, and by which rule
az network watcher test-ip-flow --direction Inbound --protocol TCP --local <ip>:<port> --remote <ip>:* --vm <vmResourceId> --nic <nicName>

# Security Admin Rules (Azure Virtual Network Manager) — invisible from the NSG blade
Get-AzNetworkManager | Get-AzNetworkManagerSecurityAdminConfiguration

# AVNM — the authoritative "what's actually applied" view for a VNet (check this before anything else)
Get-AzNetworkManagerEffectiveConnectivityConfiguration -VirtualNetworkName <vnetName> -VirtualNetworkResourceGroupName <vnetRg>

# AVNM — per-region deployment status and failure detail (configurations do nothing until deployed)
Get-AzNetworkManagerDeploymentStatus -ResourceGroupName <nmRg> -NetworkManagerName <nm> -DeploymentType @("Connectivity")

# Virtual WAN — SKU (Basic vs Standard) — check first for any capability question
Get-AzVirtualWan -ResourceGroupName <rg> -Name <vwanName> | Select VirtualWANType

# Virtual WAN — hub + router health (two independent signals)
Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName> | Select ProvisioningState, RoutingState, VirtualRouterAsn

# Virtual WAN — Routing Intent policies and Next Hop for a hub
Get-AzRoutingIntent -ResourceGroupName <rg> -ParentResourceId (Get-AzVirtualHub -ResourceGroupName <rg> -Name <hubName>).Id

# Virtual WAN — spoke connection status and routing configuration (association/propagation)
Get-AzVirtualHubVnetConnection -ResourceGroupName <rg> -ParentResourceName <hubName> -Name <connectionName>

# Private DNS — test resolution against Azure's resolver directly (bypasses local/custom DNS)
Resolve-DnsName -Name <fqdn> -Type A -Server 168.63.129.16

# Private DNS — which VNets are linked to a zone, and is autoregistration on?
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <zoneName> | Select Name, VirtualNetworkId, RegistrationEnabled

# Private DNS — does this Private Endpoint have DNS integration configured at all?
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup

# Private DNS — is the VNet using Azure-provided DNS or a custom server?
(Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>).DhcpOptions.DnsServers

# Azure Firewall — SKU and whether it's Virtual WAN secured-hub-hosted (HubIPAddresses populated)
Get-AzFirewall -ResourceGroupName <rg> -Name <fwName> | Select Sku, ProvisioningState, HubIPAddresses

# Azure Firewall — Policy SKU (check against Firewall SKU — the #1 silent mismatch)
Get-AzFirewallPolicy -ResourceGroupName <rg> -Name <policyName> | Select Sku, ThreatIntelMode

# Azure Firewall — Rule Collection Groups in priority order (remember: NAT→Network→Application type order wins first)
Get-AzFirewallPolicyRuleCollectionGroup -ResourceGroupName <rg> -PolicyName <policyName> | Sort Priority | Select Name, Priority

# Azure Firewall — TLS inspection cert/identity config
(Get-AzFirewallPolicy -ResourceGroupName <rg> -Name <policyName>).TransportSecurity

# Azure Firewall — IDPS mode and signature overrides
(Get-AzFirewallPolicy -ResourceGroupName <rg> -Name <policyName>).IntrusionDetection

# P2S VPN — gateway SKU + VpnClientConfiguration in one shot (auth types, protocols, address pool)
Get-AzVirtualNetworkGateway -ResourceGroupName <rg> -Name <gatewayName> | Select GatewayType, VpnType, Sku, VpnClientConfiguration

# P2S VPN — regenerate the client profile package (required after ANY gateway-side config change)
New-AzVpnClientConfiguration -ResourceGroupName <rg> -VirtualNetworkGatewayName <gatewayName> -AuthenticationMethod EAPTLS

# Azure Bastion — resource state and SKU
Get-AzBastion -ResourceGroupName <rg> -Name <bastionName> | Select Name, ProvisioningState, SkuText

# Azure Bastion — AzureBastionSubnet sizing check (must be /26 or larger)
Get-AzVirtualNetworkSubnetConfig -Name AzureBastionSubnet -VirtualNetwork (Get-AzVirtualNetwork -ResourceGroupName <rg> -Name <vnetName>)

# Application Gateway — state, SKU, backend health (the #1 first check for any "site is down" ticket)
Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName> | Select ProvisioningState, OperationalState, Sku
Get-AzApplicationGatewayBackendHealth -ResourceGroupName <rg> -Name <gwName>

# Application Gateway — WAF policy mode/association at gateway, listener, and path level (most specific wins)
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).FirewallPolicy
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).HttpListeners | Select Name, FirewallPolicy
(Get-AzApplicationGateway -ResourceGroupName <rg> -Name <gwName>).UrlPathMaps.PathRules | Select Paths, FirewallPolicy

# Application Gateway — control-plane NSG rule required by v2 SKU (GatewayManager, TCP 65200-65535)
Get-AzNetworkSecurityGroup -ResourceGroupName <rg> -Name <nsgName> | Get-AzNetworkSecurityRuleConfig |
    Where-Object { $_.SourceAddressPrefix -match "GatewayManager" }

# Load Balancer — SKU and backend health (the #1 first check; flag Basic as unsupported/retired)
Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName> | Select Sku, ProvisioningState
Get-AzLoadBalancerBackendHealth -ResourceGroupName <rg> -Name <lbName>

# Load Balancer — outbound-access method check (public LB backends — Standard SKU has NO implicit path)
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).OutboundRules
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).NatGateway
(Get-AzNetworkInterface -ResourceGroupName <rg> -Name <nicName>).IpConfigurations.PublicIpAddress

# Load Balancer — health probe protocol/port (check against the WinHTTP restricted-port list)
(Get-AzLoadBalancer -ResourceGroupName <rg> -Name <lbName>).Probes | Select Name, Protocol, Port, RequestPath

# Load Balancer — fleet-wide check for any surviving (unsupported) Basic SKU instances
Get-AzLoadBalancer | Where-Object { $_.Sku.Name -eq 'Basic' } | Select Name, ResourceGroupName

# Front Door — profile tier and endpoint state (the #1 first check; flag Classic as retiring 2027)
Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName> | Select Sku, ResourceState
Get-AzFrontDoorCdnEndpoint -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName>

# Front Door — custom domain validation state and certificate type (apex domains need manual re-validation)
Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName>

# Front Door — origin group health probe configuration
Get-AzFrontDoorCdnOriginGroup -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName>

# Front Door — WAF policy tier (Standard = custom rules only) and its Security Policy domain association
Get-AzFrontDoorWafPolicy -ResourceGroupName <rg> -Name <wafPolicyName> | Select Sku, ManagedRules
Get-AzFrontDoorCdnSecurityPolicy -ResourceGroupName <rg> -ProfileName <profileName> -SecurityPolicyName <policyName>

# Front Door — fleet-wide check for any surviving Classic profiles
Get-AzFrontDoorCdnProfile | Where-Object { $_.Sku.Name -like 'Classic*' } | Select Name, ResourceGroupName

# Front Door Private Link origin — per-origin connection state (only Approved carries traffic)
(Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <ogName> -OriginName <originName>).SharedPrivateLinkResource

# Front Door Private Link origin — approve a pending connection (run on the ORIGIN resource, not the FD profile)
Get-AzPrivateEndpointConnection -ResourceGroupName <originRg> -ServiceName <originResourceName> -PrivateLinkResourceType <resourceType> |
    Approve-AzPrivateEndpointConnection -Description "Approved for Front Door Premium origin connectivity"

# Private Link — connection approval state (the #1 first check; only Approved carries traffic)
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateLinkServiceConnections |
    Select Name, PrivateLinkServiceConnectionState

# Private Link — DNS Zone Group presence (empty = DNS is unmanaged for this endpoint)
(Get-AzPrivateEndpoint -ResourceGroupName <rg> -Name <peName>).PrivateDnsZoneGroup

# Private Link — zone's Virtual Network Links (confirm the CLIENT's VNet specifically is present)
Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName <rg> -ZoneName <privatelinkZoneName>

# Private Link — live resolution test (expect a private IP, not the resource's public IP)
Resolve-DnsName -Name <resourceFqdn>

# Private Link — subnet network policy state (off by default; NSG/UDR not evaluated for PE traffic until Enabled)
(Get-AzVirtualNetworkSubnetConfig -ResourceId <subnetId>).PrivateEndpointNetworkPolicies

# Private Link — fleet-wide: every endpoint's connection state in one pass
Get-AzPrivateEndpoint | Select Name, ResourceGroupName, @{N='State';E={$_.PrivateLinkServiceConnections[0].PrivateLinkServiceConnectionState.Status}}
```

---

## Key dependency chain

```
VPN Gateway path                          ExpressRoute path
─────────────────                          ─────────────────
On-prem VPN device                         Customer CE router
    │                                          │
IPsec/IKE tunnel (PSK/cert)                Provider network (PE / PE-MSEE)
    │  ← must be Connected first               │  ← ServiceProviderProvisioningState
    ▼                                          ▼
BGP session (ASN/peer-IP/timers)           Microsoft network (MSEE)
    │  ← rides ON TOP of the tunnel            │  ← CircuitProvisioningState
    ▼                                          ▼
Learned + advertised routes                eBGP peering (VLAN/ASN/subnet/MD5)
    │                                          │
    ▼                                          ▼
GatewaySubnet + destination NSG/UDR   ←──  Virtual Network Gateway (ExpressRoute SKU)
    │                                          │
    ▼                                          ▼
              Traffic flows (both paths converge here)


NSG evaluation (NSG-A.md/NSG-B.md — the data-plane layer both paths above converge on):

Security Admin Rules (AVNM)  ← evaluated first, invisible from the NSG resource itself
    │  AlwaysAllow/Deny terminate here; Allow passes through
    ▼
Subnet-level NSG  ──AND──  NIC-level NSG   (order is direction-dependent: subnet-first inbound, NIC-first outbound)
    │  both must independently allow — first rule match per NSG wins, evaluation stops
    ▼
Default rules (65000/65001/65500) — cannot be deleted, only overridden by a lower-priority custom rule
    │
    ▼
Packet delivered (or dropped)
```

AVNM's own layer, which *provisions* the connectivity NSGs then filter (AVNM-A.md/AVNM-B.md):

```
Network Manager scope (management group/subscription) — hard ceiling, out-of-scope VNets get nothing
    │
    ▼
Network Group membership — static (immediate) or dynamic (Azure Policy, ~30min-24h lag)
    │
    ▼
Configuration object (connectivity/security admin/routing) — inert until deployed
    │
    ▼
Deployment (per-region commit, GOAL-STATE: exclusive per region, not additive across deploy actions)
    │
    ▼
Mesh → Connected Group (never a peering) | Hub-and-spoke → real peering | VWAN hub (preview) → VWAN connection
    │
    ▼
Effective state (Get-AzNetworkManagerEffectiveConnectivityConfiguration — the only authoritative view)
```

Private DNS resolution chain (PrivateDNS-A.md/PrivateDNS-B.md — a separate dependency chain from connectivity above; a resource can be fully reachable and still fail to resolve):

```
Azure-provided DNS (168.63.129.16) — default for every VNet unless overridden
    │
    ├─ VNet DNS = Default        → private zone resolution works automatically
    └─ VNet DNS = Custom server  → must forward the zone's suffix to 168.63.129.16, or use DNS Private Resolver
    ▼
Private DNS Zone (custom, or reserved privatelink.* name — exact match required per service)
    │
    ▼
Virtual Network Link (peering NEVER creates this — each VNet needs its own explicit link)
    │  ├─ Resolution-only
    │  └─ Registration-enabled (custom zones only)
    ▼
Records populated
    │  ├─ Custom zone       → VM autoregistration
    │  └─ privatelink.* zone → Private Endpoint's DNS Zone Group (unrelated to registration flag)
    ▼
Client resolves correctly (private IP) or falls through to public DNS (public IP / NXDOMAIN)
```

P2S VPN dependency chain (P2SVPN-A.md/P2SVPN-B.md — an individual-client path, NOT the S2S/ExpressRoute chain above):

```
Gateway SKU capability ceiling (Basic: no IKEv2/RADIUS/IPv6 — silent, not an error)
    │
    ▼
VpnClientConfiguration: address pool + protocol(s) + auth type(s)
    │  ├─ Certificate → root CA trust chain uploaded to gateway
    │  ├─ Entra ID     → App ID/Audience, OpenVPN-only, Azure VPN Client required
    │  └─ RADIUS       → pass-through; on-prem RADIUS needs a live S2S tunnel for reachability
    ▼
Client profile package (point-in-time snapshot — regenerate after ANY gateway-side change)
    │  ├─ Windows     → routes baked in at generation time, does NOT auto-refresh
    │  └─ non-Windows → routes refresh dynamically on topology change
    ▼
Tunnel established → routing (BGP-off: no transitive multi-hop; BGP-on: transitive, Windows still needs a profile refresh)
```

Azure Bastion dependency chain (Bastion-A.md/Bastion-B.md — the management-plane access path NSG-B.md/RDP-B.md point to as the Bastion alternative to open 3389/22):

```
SKU tier (Developer/Basic/Standard/Premium) — determines EVERY capability below, not just cost
    │
    ▼
AzureBastionSubnet (/26+) + Public IP (dedicated SKUs; Premium can go private-only)
    │
    ▼
AzureBastionSubnet NSG (if applied) — ALL 8 required rules together, or Azure rejects the NSG
    │
    ▼
Target VM subnet NSG — a SEPARATE inbound allow for 3389/22 FROM AzureBastionSubnet (#1 real-world gap)
    │
    ▼
[If JIT enabled] connecting user has BOTH jitNetworkAccessPolicies/read AND /write at scope
    │
    ▼
Session over TLS 443 (browser: all SKUs | native client/IP-Connect/shareable link: Standard+ only)
```

Application Gateway request path (AppGateway-A.md/AppGateway-B.md — the inbound reverse-proxy/WAF layer distinct from Azure Firewall's outbound/East-West scope above):

```
Dedicated subnet (Application Gateway ONLY — no other resource type may share it)
    │
NSG allows GatewayManager inbound TCP 65200-65535 (v2 control-plane health reporting —
    missing this = blank/Unknown backend health for EVERY server, not an explicit deny)
    │
Listener (frontend IP + port + protocol + hostname if multi-site)
    │
[If WAF_v2] WAF policy — gateway/listener/path level, MOST SPECIFIC FULLY OVERRIDES (no merge)
    │
Routing rule (Basic or Path-based) → backend pool + HTTP settings
    │
Health probe (default: any 200-399 = healthy — a 401/403/302 probe response reads as Unhealthy
    even when the app itself is fine)
    │
Backend pool member responds within RequestTimeout
    │
Response returned to client
```

Load Balancer dependency chain (LoadBalancer-A.md/LoadBalancer-B.md — the Layer 4 counterpart to Application Gateway's Layer 7 chain above; distribution is per-flow via 5-tuple hash, not round-robin or client-affinity):

```
Frontend IP configuration (public or private — decides LB type; zone setting fixed at creation)
    │
NSG explicitly allows the intended traffic (Standard SKU = secure-by-default, NO implicit inbound
    permit — the #1 "traffic just times out" gap for anyone assuming Basic SKU's old implicit allow)
    │
Backend pool populated with real instances (single VNet scope; no Private Endpoints)
    │
Health probe (TCP/HTTP/HTTPS) passing — blocks NEW flows only on failure, does NOT reset established
    TCP connections; ALL-instances-unhealthy DOES terminate every UDP flow immediately (no grace period)
    │
Load-balancing rule OR Inbound NAT rule maps frontend IP:port → backend
    │
[Public LB backend needing outbound Internet] EXACTLY ONE explicit method present:
    LB outbound rule (watch default SNAT allocation shrinking as pool grows) |
    NAT Gateway (MS production recommendation) | instance-level public IP
    — Standard SKU provides NONE of these implicitly; this is THE most common post-migration ticket
    │
Traffic flows to/from backend instance
```

Front Door dependency chain (FrontDoor-A.md/FrontDoor-B.md — the GLOBAL-edge Layer 7 counterpart to Application Gateway's regional chain above; a profile can front origins in multiple regions/services at once):

```
Profile (Standard/Premium — Classic retires March 31, 2027, no new domains/certs from then on)
    │
Endpoint EnabledState = Enabled (a disabled endpoint fails EVERY route on it identically)
    │
Custom domain DomainValidationState = Approved
    ├─ Non-apex: _dnsauth TXT record (ownership) + CNAME to the endpoint (routing + managed-cert issuance/autorotation)
    └─ Apex: _dnsauth TXT record only — NO CNAME possible; managed-cert AUTOROTATION silently fails at
       renewal and needs manual re-validation (recurring operational task, not one-time setup)
    │
Route: protocol → EXACT host match (no wildcard-host fallback, unlike path matching) → most-specific PATH match
    │
[If Rule Set attached] check for a RouteConfigurationOverride action — can redirect to a
    DIFFERENT origin group than the route's own static association, evaluated AFTER normal matching
    │
[If Security Policy associates a WAF policy] tier gates capability:
    Standard = custom rules only | Premium = custom + managed rules (DRS) + Bot Protection + JS Challenge
    Evaluation order: custom → rate-limit → bot protection → managed rules
    │
Origin group health probe (HTTP/HTTPS, HEAD default) — 3-step: exclude disabled →
    exclude SampleSize/SuccessfulSamplesRequired failures → latency-rank survivors
    ALL origins failing = fail-OPEN round robin, not fail-closed
    │
Origin responds within timeout → cached per route config (if enabled) or passed through
```

Private Link / Private Endpoint dependency chain (PrivateLink-A.md/PrivateLink-B.md — the resource-connectivity layer several other files in this folder, and KeyVault/AVD/Monitor elsewhere, point back to as the single source of truth):

```
Private-link resource supports Private Link for the specific SUBRESOURCE needed
    │  (per-subresource, not per-service — e.g., Storage blob vs. file are separate PEs)
    ▼
Private Endpoint created — one static private IP for its lifetime
    │
Connection approval state = Approved
    │  (Automatic if requester owns the resource; Manual otherwise — Pending/Rejected/
    │   Disconnected ALL carry ZERO traffic no matter how complete DNS/network looks)
    ▼
Private DNS Zone Group attached (the automation layer for A records)
    │  (absent = DNS unmanaged; the #1 real-world "resolves to the public IP" root cause)
    ▼
Zone uses the EXACT reserved privatelink.<service> name
    │  (NEVER shared across two DIFFERENT services — each Zone Group's reconciliation
    │   overwrites a conflicting record left by another service)
    ▼
Virtual Network Link connects the zone to EVERY VNet needing resolution
    │  (peering NEVER implies this link — one shared zone extended by links, not
    │   duplicate zones; see PrivateDNS-A.md/PrivateDNS-B.md for the general mechanics)
    ▼
[On-premises clients] DNS forwarder or Azure Private Resolver bridges resolution
    │  (168.63.129.16 isn't reachable from on-prem directly; forward the PUBLIC
    │   suffix, never the privatelink.-prefixed name)
    ▼
Client resolves FQDN → private IP → reaches the Private Endpoint NIC
    │
[If NSG/UDR enforcement required] PrivateEndpointNetworkPolicies = Enabled on the subnet
    │  (Disabled by default = NSG/UDR structurally NOT evaluated for this traffic at all —
    │   an "NSG rule has no effect" ticket on a PE subnet starts here, not in NSG-B.md)
    ▼
Traffic reaches the private-link resource
```

---

## Response format reminder (always 3 layers)

1. **Immediate action** — classify VPN vs. ExpressRoute, confirm transport layer (tunnel/circuit) before routing layer (BGP) (Mode B)
2. **Root cause** — which of the six dependency-stack layers actually failed, and which organization owns the fix (Mode A)
3. **Prevention** — diagnostic logging enabled, prefix-count monitoring, and confirming provider/Microsoft escalation contacts are documented before the next incident
