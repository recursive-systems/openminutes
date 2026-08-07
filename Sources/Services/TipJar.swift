import Foundation
import StoreKit

/// Optional tips. Not a paywall — nothing in the app is ever gated on one.
///
/// The app is MIT-licensed and anyone can build it themselves, so selling
/// capability would be selling something the user already has. Tips ask for
/// support instead, which is honest about what the transaction is.
///
/// Products are **consumable**: a tip should be repeatable, and nothing is
/// unlocked by making one, so there is no entitlement to restore. That also
/// means there is no purchase state to sync — `hasTipped` is a local
/// courtesy flag for saying thank you, nothing more.
///
/// Privacy note: purchases go through iOS's own StoreKit daemons, the same
/// as every paid app. No app-code network calls, and no effect on the
/// "Data Not Collected" label.
@MainActor
@Observable
final class TipJar {

    /// Ascending by price. Must match the products created in App Store
    /// Connect and `Config/OpenMinutes.storekit`.
    static let productIDs = [
        "dev.recursivesystems.openminutes.tip.small",
        "dev.recursivesystems.openminutes.tip.medium",
        "dev.recursivesystems.openminutes.tip.large",
    ]

    private static let hasTippedKey = "hasTipped"

    private(set) var products: [Product] = []
    private(set) var purchaseError: String?
    private(set) var isPurchasing = false
    /// Local only, and only used to say thank you.
    private(set) var hasTipped = UserDefaults.standard.bool(forKey: hasTippedKey)

    /// Empty when the products have not loaded — on a build whose products
    /// do not exist yet in App Store Connect, the section simply does not
    /// appear rather than showing broken rows.
    var isAvailable: Bool { !products.isEmpty }

    /// Runs for the process lifetime, deliberately without a cancel path.
    /// `AppServices` owns the one TipJar, and a listener that stopped when
    /// some view went away would miss exactly the transactions it exists to
    /// catch. `[weak self]` keeps it from holding the object alive.
    private var updates: Task<Void, Never>?

    /// Tips also arrive outside `tip(_:)`: an Ask to Buy approved hours
    /// later, a purchase that completed while the app was killed, a payment
    /// held for a billing fix. Nothing is unlocked by a tip, so the stake is
    /// not entitlement — it is that an unfinished consumable is re-delivered
    /// on every launch forever, and the person has already paid.
    init() {
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.acknowledge(update)
            }
        }
    }

    /// Finishes a transaction whether or not it verified. An unverified one
    /// grants nothing here — there is nothing to grant — but it still repeats
    /// until finished, so leaving it open only punishes the payer.
    private func acknowledge(_ result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
            hasTipped = true
            UserDefaults.standard.set(true, forKey: Self.hasTippedKey)
        case .unverified(let transaction, _):
            await transaction.finish()
        }
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        let loaded = (try? await Product.products(for: Self.productIDs)) ?? []
        products = loaded.sorted { $0.price < $1.price }
    }

    func tip(_ product: Product) async {
        purchaseError = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                await acknowledge(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }
}
