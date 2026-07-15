// VaultStorefrontGate — the pure, hermetically-testable rule that decides whether the paid
// Vault purchase path (native plans + external web checkout) may be shown on this device
// (track T-STOREFRONT, design canon: funnel-and-auth-spine-design.md; proposal
// 20260715_vault_signup_funnel_and_auth_spine).
//
// Billing stays off Apple's 30% AND the app stays App-Review-clean by showing the purchase
// CTA ONLY where the App Store storefront allows external web checkout today — US-first.
// The gate keys on the StoreKit **Storefront** country code (the account's App Store
// storefront), NOT IP, NOT locale, NOT the SIM region — those are trivially spoofable and
// are not what Apple reviews against. The real `Storefront.current` read is a thin adapter
// at the app edge (App/VaultFunnelView.swift); this core takes the code as a plain value so
// it is fully deterministic under test.
//
// FAIL CLOSED: an unknown / nil / blank storefront yields `false` (sign-in only, no purchase
// CTA). We would rather withhold the purchase path from an undeterminable region than show it
// somewhere it isn't allowed — the review-clean default is "no CTA".

import Foundation

public enum VaultStorefrontGate {
    /// The App Store storefronts where external web checkout is offered today. StoreKit 2
    /// `Storefront.countryCode` returns an ISO-3166-1 **alpha-3** code ("USA"); StoreKit 1 /
    /// callers sometimes pass alpha-2 ("US"), so we accept both. US-first; more regions come
    /// with the non-US external-purchase programs (later, out of this track's scope).
    public static let purchaseEligibleStorefronts: Set<String> = ["US", "USA"]

    /// Whether the purchase CTA (plans + external checkout) may be shown, gated by the App
    /// Store storefront country code. US → true; every other determinable storefront → false;
    /// nil / blank / undeterminable → **false (fail closed)**.
    public static func purchaseAllowed(storefrontCountryCode: String?) -> Bool {
        guard let code = storefrontCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            return false   // fail closed — an undeterminable storefront never shows the CTA
        }
        return purchaseEligibleStorefronts.contains(code.uppercased())
    }
}
