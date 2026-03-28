import UIKit
import StoreKit
import Combine

/// Full-screen paywall presented when the user has no rounds remaining.
/// Matches the retro arcade/synthwave visual theme of IPhoneViewController.
class PaywallViewController: UIViewController {

    // MARK: - Theme Colors (matching IPhoneViewController)

    private let colorDeepPurple  = UIColor(red: 0x1A/255, green: 0x0A/255, blue: 0x2E/255, alpha: 1)
    private let colorDarkVoid    = UIColor(red: 0x0D/255, green: 0x02/255, blue: 0x21/255, alpha: 1)
    private let colorNeonPink    = UIColor(red: 0xFF/255, green: 0x2D/255, blue: 0x95/255, alpha: 1)
    private let colorNeonYellow  = UIColor(red: 0xFF/255, green: 0xE0/255, blue: 0x00/255, alpha: 1)
    private let colorNeonCyan    = UIColor(red: 0x00/255, green: 0xFF/255, blue: 0xFF/255, alpha: 1)
    private let colorNeonGreen   = UIColor(red: 0x00/255, green: 0xFF/255, blue: 0x65/255, alpha: 1)
    private let colorNeonOrange  = UIColor(red: 0xFF/255, green: 0x6B/255, blue: 0x00/255, alpha: 1)

    private let storeService = StoreService.shared
    private let roundTracker = RoundTracker.shared
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var activityIndicator: UIActivityIndicatorView?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = colorDarkVoid
        title = "Get More Rounds"

        setupNavigationBar()
        setupScrollView()
        buildContent()

        // Rebuild content when products load or subscription status changes
        storeService.$products
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildContent() }
            .store(in: &cancellables)

        storeService.$isSubscribed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildContent() }
            .store(in: &cancellables)
    }

    // MARK: - Navigation Bar

    private func setupNavigationBar() {
        navigationController?.navigationBar.barTintColor = colorDeepPurple
        navigationController?.navigationBar.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: roundedFont(size: 18, weight: .bold)
        ]

        let closeButton = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        closeButton.tintColor = colorNeonCyan
        navigationItem.leftBarButtonItem = closeButton
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // MARK: - Scroll View Layout

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stackView.axis = .vertical
        stackView.spacing = 16
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
        ])
    }

    // MARK: - Build Content

    private func buildContent() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Status banner
        addStatusBanner()

        // Subscriptions section
        addSectionHeader("Subscriptions")
        addSubscriptionCards()

        // Round packs section
        addSectionHeader("Round Packs")
        addRoundPackCards()

        // Restore button
        addRestoreButton()
    }

    // MARK: - Status Banner

    private func addStatusBanner() {
        let container = UIView()
        container.backgroundColor = colorDeepPurple
        container.layer.cornerRadius = 12
        container.layer.borderColor = colorNeonPink.cgColor
        container.layer.borderWidth = 1

        let statusLabel = UILabel()
        statusLabel.text = roundTracker.statusSummary
        statusLabel.font = roundedFont(size: 16, weight: .semibold)
        statusLabel.textColor = colorNeonYellow
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        stackView.addArrangedSubview(container)
    }

    // MARK: - Subscription Cards

    private func addSubscriptionCards() {
        let subscriptions = storeService.subscriptionProducts

        if subscriptions.isEmpty {
            addLoadingPlaceholder()
            return
        }

        for product in subscriptions {
            let isActive = storeService.purchasedSubscriptionIDs.contains(product.id)
            let roundsLabel: String
            let accentColor: UIColor

            if product.id == StoreProducts.weeklyPass {
                roundsLabel = "5 rounds per week"
                accentColor = colorNeonCyan
            } else {
                roundsLabel = "10 rounds per month"
                accentColor = colorNeonGreen
            }

            let card = makeProductCard(
                title: product.displayName,
                subtitle: roundsLabel,
                priceText: isActive ? "Active" : product.displayPrice,
                accentColor: accentColor,
                isActive: isActive,
                action: isActive ? nil : { [weak self] in
                    self?.handlePurchase(product)
                }
            )
            stackView.addArrangedSubview(card)
        }
    }

    // MARK: - Round Pack Cards

    private func addRoundPackCards() {
        let packs = storeService.consumableProducts

        if packs.isEmpty {
            addLoadingPlaceholder()
            return
        }

        for product in packs {
            let roundCount = StoreProducts.roundsForProduct(product.id)
            let card = makeProductCard(
                title: "\(roundCount)-Round Pack",
                subtitle: "Use anytime, never expires",
                priceText: product.displayPrice,
                accentColor: colorNeonOrange,
                isActive: false,
                action: { [weak self] in
                    self?.handlePurchase(product)
                }
            )
            stackView.addArrangedSubview(card)
        }
    }

    // MARK: - Reusable Product Card

    private func makeProductCard(
        title: String,
        subtitle: String,
        priceText: String,
        accentColor: UIColor,
        isActive: Bool,
        action: (() -> Void)?
    ) -> UIView {
        let card = UIView()
        card.backgroundColor = colorDeepPurple
        card.layer.cornerRadius = 12
        card.layer.borderColor = accentColor.withAlphaComponent(0.5).cgColor
        card.layer.borderWidth = 1

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = roundedFont(size: 18, weight: .bold)
        titleLabel.textColor = .white

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = roundedFont(size: 14, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let button = UIButton(type: .system)
        button.setTitle(priceText, for: .normal)
        button.titleLabel?.font = roundedFont(size: 16, weight: .bold)

        if isActive {
            button.setTitleColor(colorNeonGreen, for: .normal)
            button.isEnabled = false
            button.backgroundColor = .clear
            button.layer.borderColor = colorNeonGreen.cgColor
            button.layer.borderWidth = 1
        } else {
            button.setTitleColor(colorDarkVoid, for: .normal)
            button.backgroundColor = accentColor
        }

        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        if let action = action {
            let handler = UIAction { _ in action() }
            button.addAction(handler, for: .touchUpInside)
        }

        let hStack = UIStackView(arrangedSubviews: [textStack, button])
        hStack.axis = .horizontal
        hStack.alignment = .center
        hStack.spacing = 12
        hStack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            hStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            hStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])

        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        return card
    }

    // MARK: - Section Header

    private func addSectionHeader(_ text: String) {
        let spacer = UIView()
        spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true
        stackView.addArrangedSubview(spacer)

        let label = UILabel()
        label.text = text.uppercased()
        label.font = roundedFont(size: 13, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        label.accessibilityTraits = .header
        stackView.addArrangedSubview(label)
    }

    // MARK: - Loading Placeholder

    private func addLoadingPlaceholder() {
        let label = UILabel()
        label.text = "Loading products..."
        label.font = roundedFont(size: 14, weight: .regular)
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        label.textAlignment = .center
        stackView.addArrangedSubview(label)
    }

    // MARK: - Restore Button

    private func addRestoreButton() {
        let spacer = UIView()
        spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
        stackView.addArrangedSubview(spacer)

        let button = UIButton(type: .system)
        button.setTitle("Restore Purchases", for: .normal)
        button.titleLabel?.font = roundedFont(size: 14, weight: .medium)
        button.setTitleColor(colorNeonCyan.withAlphaComponent(0.7), for: .normal)
        button.addAction(UIAction { [weak self] _ in
            self?.handleRestore()
        }, for: .touchUpInside)

        stackView.addArrangedSubview(button)
    }

    // MARK: - Purchase Handling

    private func handlePurchase(_ product: Product) {
        showLoading(true)

        Task {
            do {
                let success = try await storeService.purchase(product)
                showLoading(false)
                if success {
                    // If user now has rounds, auto-dismiss
                    if roundTracker.canPlayRound {
                        dismiss(animated: true)
                    }
                }
            } catch {
                showLoading(false)
                showAlert(title: "Purchase Failed", message: error.localizedDescription)
            }
        }
    }

    private func handleRestore() {
        showLoading(true)
        Task {
            await storeService.restorePurchases()
            showLoading(false)

            if roundTracker.canPlayRound {
                dismiss(animated: true)
            } else {
                showAlert(title: "No Purchases Found", message: "We didn't find any active subscriptions or round packs for this Apple ID.")
            }
        }
    }

    // MARK: - Loading Indicator

    private func showLoading(_ show: Bool) {
        if show {
            let indicator = UIActivityIndicatorView(style: .large)
            indicator.color = colorNeonCyan
            indicator.center = view.center
            indicator.startAnimating()
            view.addSubview(indicator)
            activityIndicator = indicator
            view.isUserInteractionEnabled = false
        } else {
            activityIndicator?.removeFromSuperview()
            activityIndicator = nil
            view.isUserInteractionEnabled = true
        }
    }

    // MARK: - Alert

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Font Helper

    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let systemFont = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return systemFont
    }
}
