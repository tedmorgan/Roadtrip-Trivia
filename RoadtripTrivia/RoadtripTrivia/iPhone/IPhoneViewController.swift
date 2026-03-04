import UIKit
import Combine
import AuthenticationServices
import AVFoundation

/// iPhone companion screen showing game status during play and auth/setup when idle.
/// All gameplay happens on CarPlay; iPhone shows team name, round, score, and lightning timer.
/// Auth and settings are hidden behind a gear icon in the nav bar.
/// Visual theme: retro arcade / synthwave with neon glow effects.
class IPhoneViewController: UIViewController {

    private let gameViewModel = GameViewModel.shared
    private let authService = AuthService.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Arcade Color Palette
    let colorDeepPurple = UIColor(red: 0x1A / 255.0, green: 0x0A / 255.0, blue: 0x2E / 255.0, alpha: 1.0)
    let colorDarkVoid = UIColor(red: 0x0D / 255.0, green: 0x02 / 255.0, blue: 0x21 / 255.0, alpha: 1.0)
    let colorNeonPink = UIColor(red: 0xFF / 255.0, green: 0x2D / 255.0, blue: 0x95 / 255.0, alpha: 1.0)
    let colorNeonYellow = UIColor(red: 0xFF / 255.0, green: 0xE0 / 255.0, blue: 0x00 / 255.0, alpha: 1.0)
    let colorNeonCyan = UIColor(red: 0x00 / 255.0, green: 0xFF / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    let colorNeonGreen = UIColor(red: 0x00 / 255.0, green: 0xFF / 255.0, blue: 0x65 / 255.0, alpha: 1.0)
    let colorNeonOrange = UIColor(red: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x00 / 255.0, alpha: 1.0)
    let colorGridPurple = UIColor(red: 0x6B / 255.0, green: 0x00 / 255.0, blue: 0xCC / 255.0, alpha: 1.0)

    // Fun rounded fonts helper
    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let systemFont = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return systemFont
    }

    // Neon glow helper
    private func applyNeonGlow(to view: UIView, color: UIColor, radius: CGFloat = 12, opacity: Float = 0.9) {
        view.layer.shadowColor = color.cgColor
        view.layer.shadowRadius = radius
        view.layer.shadowOpacity = opacity
        view.layer.shadowOffset = .zero
    }

    // MARK: - Views
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let gridView = UIView() // synthwave grid background

    // Idle state views
    private let appIconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let idleMessageLabel = UILabel()

    // Playing state views (stacked in a container)
    private let playingContainer = UIView()
    private let teamNameLabel = UILabel()
    private let roundLabel = UILabel()
    private let categoryLabel = UILabel()
    private let scoreCardView = UIView()
    private let questionLabel = UILabel()
    private let roundPointsLabel = UILabel()
    private let totalPointsLabel = UILabel()

    // Lightning card (appears only during lightning round)
    private let lightningCardView = UIView()
    private let lightningHeaderLabel = UILabel()
    private let lightningTimerLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        print("[IPhoneViewController] viewDidLoad called")

        view.backgroundColor = colorDarkVoid
        setupGradientBackground()
        setupSynthwaveGrid()
        setupNavigationBar()
        setupScrollView()
        setupIdleStateViews()
        setupPlayingStateViews()
        setupLightningCard()

        observeGameViewModel()
        requestPermissions()
        updateDisplayMode()

        print("[IPhoneViewController] viewDidLoad complete")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Resize gradient to match view
        if let gradient = view.layer.sublayers?.first as? CAGradientLayer {
            gradient.frame = view.bounds
        }
        // Resize grid
        gridView.frame = view.bounds
        if let gridLayer = gridView.layer.sublayers?.first as? CAShapeLayer {
            gridLayer.frame = view.bounds
            gridLayer.path = createGridPath(in: view.bounds).cgPath
        }
    }

    // MARK: - Background Setup

    private func setupGradientBackground() {
        let gradient = CAGradientLayer()
        gradient.colors = [
            colorDeepPurple.cgColor,
            colorDarkVoid.cgColor,
            UIColor(red: 0x15, green: 0x00, blue: 0x30, alpha: 1.0).cgColor
        ]
        gradient.locations = [0.0, 0.5, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.frame = view.bounds
        view.layer.insertSublayer(gradient, at: 0)
    }

    private func setupSynthwaveGrid() {
        gridView.frame = view.bounds
        gridView.isUserInteractionEnabled = false
        view.addSubview(gridView)

        let gridLayer = CAShapeLayer()
        gridLayer.frame = view.bounds
        gridLayer.path = createGridPath(in: view.bounds).cgPath
        gridLayer.strokeColor = colorGridPurple.withAlphaComponent(0.3).cgColor
        gridLayer.fillColor = UIColor.clear.cgColor
        gridLayer.lineWidth = 0.8
        gridView.layer.addSublayer(gridLayer)
    }

    private func createGridPath(in bounds: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let spacing: CGFloat = 40

        // Horizontal lines (bottom half only for synthwave horizon feel)
        let startY = bounds.height * 0.55
        var y = startY
        while y < bounds.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
            y += spacing
        }

        // Vertical lines with perspective convergence
        let horizonY = bounds.height * 0.55
        let vanishX = bounds.width / 2.0
        let numLines = 11
        let bottomSpacing = bounds.width / CGFloat(numLines - 1)

        for i in 0..<numLines {
            let bottomX = CGFloat(i) * bottomSpacing
            path.move(to: CGPoint(x: vanishX, y: horizonY))
            path.addLine(to: CGPoint(x: bottomX, y: bounds.height))
        }

        return path
    }

    // MARK: - Navigation Bar

    private func setupNavigationBar() {
        navigationController?.navigationBar.barStyle = .black
        navigationController?.navigationBar.barTintColor = colorDarkVoid
        navigationController?.navigationBar.isTranslucent = false

        // No title in nav bar — the big neon title is in the content
        navigationItem.titleView = UIView()

        let gearButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape.fill"),
            style: .plain,
            target: self,
            action: #selector(showAccountSettings)
        )
        gearButton.tintColor = colorNeonYellow
        navigationItem.rightBarButtonItem = gearButton
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        contentView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.heightAnchor),
        ])
    }

    // MARK: - Idle State (before game starts)

    private func setupIdleStateViews() {
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.image = UIImage(named: "AppIcon") ?? UIImage(systemName: "car.fill")
        appIconView.contentMode = .scaleAspectFit
        appIconView.layer.cornerRadius = 30
        appIconView.clipsToBounds = true
        applyNeonGlow(to: appIconView, color: colorNeonPink, radius: 20, opacity: 0.8)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "ROADTRIP\nTRIVIA"
        titleLabel.font = roundedFont(size: 52, weight: .heavy)
        titleLabel.textColor = colorNeonPink
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        applyNeonGlow(to: titleLabel, color: colorNeonPink, radius: 20, opacity: 0.8)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Your CarPlay trivia adventure"
        subtitleLabel.font = roundedFont(size: 22, weight: .medium)
        subtitleLabel.textColor = colorNeonCyan
        subtitleLabel.textAlignment = .center

        idleMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        idleMessageLabel.text = "Connect to CarPlay\nto start playing!"
        idleMessageLabel.font = roundedFont(size: 26, weight: .bold)
        idleMessageLabel.textColor = colorNeonYellow
        idleMessageLabel.textAlignment = .center
        idleMessageLabel.numberOfLines = 0
        applyNeonGlow(to: idleMessageLabel, color: colorNeonYellow, radius: 15, opacity: 0.7)

        contentView.addSubview(appIconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(idleMessageLabel)

        NSLayoutConstraint.activate([
            appIconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            appIconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 100),
            appIconView.heightAnchor.constraint(equalToConstant: 100),

            titleLabel.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            idleMessageLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 50),
            idleMessageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            idleMessageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            idleMessageLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Playing State

    private func setupPlayingStateViews() {
        playingContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playingContainer)

        // Team name — BIG neon yellow with glow
        teamNameLabel.translatesAutoresizingMaskIntoConstraints = false
        teamNameLabel.font = roundedFont(size: 52, weight: .heavy)
        teamNameLabel.textColor = colorNeonYellow
        teamNameLabel.textAlignment = .center
        teamNameLabel.adjustsFontSizeToFitWidth = true
        teamNameLabel.minimumScaleFactor = 0.6
        applyNeonGlow(to: teamNameLabel, color: colorNeonYellow, radius: 18, opacity: 0.8)

        // Round label — neon pink
        roundLabel.translatesAutoresizingMaskIntoConstraints = false
        roundLabel.font = roundedFont(size: 40, weight: .heavy)
        roundLabel.textColor = colorNeonPink
        roundLabel.textAlignment = .center
        applyNeonGlow(to: roundLabel, color: colorNeonPink, radius: 14, opacity: 0.7)

        // Category — neon cyan
        categoryLabel.translatesAutoresizingMaskIntoConstraints = false
        categoryLabel.font = roundedFont(size: 24, weight: .semibold)
        categoryLabel.textColor = colorNeonCyan
        categoryLabel.textAlignment = .center
        categoryLabel.numberOfLines = 2
        categoryLabel.adjustsFontSizeToFitWidth = true
        categoryLabel.minimumScaleFactor = 0.8

        playingContainer.addSubview(teamNameLabel)
        playingContainer.addSubview(roundLabel)
        playingContainer.addSubview(categoryLabel)

        // Score card — dark with neon cyan border + glow
        scoreCardView.translatesAutoresizingMaskIntoConstraints = false
        scoreCardView.backgroundColor = colorDarkVoid.withAlphaComponent(0.85)
        scoreCardView.layer.cornerRadius = 16
        scoreCardView.layer.borderWidth = 2
        scoreCardView.layer.borderColor = colorNeonCyan.cgColor
        applyNeonGlow(to: scoreCardView, color: colorNeonCyan, radius: 16, opacity: 0.6)
        playingContainer.addSubview(scoreCardView)

        // Question label — white, big
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.font = roundedFont(size: 32, weight: .bold)
        questionLabel.textColor = .white
        questionLabel.textAlignment = .center

        // Round points — neon green, huge
        roundPointsLabel.translatesAutoresizingMaskIntoConstraints = false
        roundPointsLabel.font = roundedFont(size: 38, weight: .heavy)
        roundPointsLabel.textColor = colorNeonGreen
        roundPointsLabel.textAlignment = .center
        applyNeonGlow(to: roundPointsLabel, color: colorNeonGreen, radius: 10, opacity: 0.6)

        // Total points — neon yellow
        totalPointsLabel.translatesAutoresizingMaskIntoConstraints = false
        totalPointsLabel.font = roundedFont(size: 30, weight: .bold)
        totalPointsLabel.textColor = colorNeonYellow
        totalPointsLabel.textAlignment = .center

        scoreCardView.addSubview(questionLabel)
        scoreCardView.addSubview(roundPointsLabel)
        scoreCardView.addSubview(totalPointsLabel)

        NSLayoutConstraint.activate([
            playingContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            playingContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playingContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            teamNameLabel.topAnchor.constraint(equalTo: playingContainer.topAnchor, constant: 8),
            teamNameLabel.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            teamNameLabel.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            roundLabel.topAnchor.constraint(equalTo: teamNameLabel.bottomAnchor, constant: 4),
            roundLabel.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            roundLabel.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            categoryLabel.topAnchor.constraint(equalTo: roundLabel.bottomAnchor, constant: 4),
            categoryLabel.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            categoryLabel.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            scoreCardView.topAnchor.constraint(equalTo: categoryLabel.bottomAnchor, constant: 20),
            scoreCardView.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 20),
            scoreCardView.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -20),

            questionLabel.topAnchor.constraint(equalTo: scoreCardView.topAnchor, constant: 18),
            questionLabel.leadingAnchor.constraint(equalTo: scoreCardView.leadingAnchor, constant: 16),
            questionLabel.trailingAnchor.constraint(equalTo: scoreCardView.trailingAnchor, constant: -16),

            roundPointsLabel.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 12),
            roundPointsLabel.leadingAnchor.constraint(equalTo: scoreCardView.leadingAnchor, constant: 16),
            roundPointsLabel.trailingAnchor.constraint(equalTo: scoreCardView.trailingAnchor, constant: -16),

            totalPointsLabel.topAnchor.constraint(equalTo: roundPointsLabel.bottomAnchor, constant: 8),
            totalPointsLabel.leadingAnchor.constraint(equalTo: scoreCardView.leadingAnchor, constant: 16),
            totalPointsLabel.trailingAnchor.constraint(equalTo: scoreCardView.trailingAnchor, constant: -16),
            totalPointsLabel.bottomAnchor.constraint(equalTo: scoreCardView.bottomAnchor, constant: -18),
        ])
    }

    // MARK: - Lightning Round Card

    private func setupLightningCard() {
        lightningCardView.translatesAutoresizingMaskIntoConstraints = false
        lightningCardView.backgroundColor = UIColor(red: 0x3D / 255.0, green: 0x00 / 255.0, blue: 0x00 / 255.0, alpha: 0.9)
        lightningCardView.layer.cornerRadius = 16
        lightningCardView.layer.borderWidth = 2.5
        lightningCardView.layer.borderColor = colorNeonOrange.cgColor
        applyNeonGlow(to: lightningCardView, color: colorNeonOrange, radius: 20, opacity: 0.8)
        playingContainer.addSubview(lightningCardView)

        lightningHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        lightningHeaderLabel.text = "⚡ LIGHTNING ROUND"
        lightningHeaderLabel.font = roundedFont(size: 30, weight: .heavy)
        lightningHeaderLabel.textColor = colorNeonOrange
        lightningHeaderLabel.textAlignment = .center
        lightningCardView.addSubview(lightningHeaderLabel)

        lightningTimerLabel.translatesAutoresizingMaskIntoConstraints = false
        lightningTimerLabel.text = "2:00"
        lightningTimerLabel.font = .monospacedDigitSystemFont(ofSize: 86, weight: .bold)
        lightningTimerLabel.textColor = .white
        lightningTimerLabel.textAlignment = .center
        applyNeonGlow(to: lightningTimerLabel, color: colorNeonOrange, radius: 20, opacity: 0.9)
        lightningCardView.addSubview(lightningTimerLabel)

        NSLayoutConstraint.activate([
            lightningCardView.topAnchor.constraint(equalTo: scoreCardView.bottomAnchor, constant: 20),
            lightningCardView.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 20),
            lightningCardView.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -20),

            lightningHeaderLabel.topAnchor.constraint(equalTo: lightningCardView.topAnchor, constant: 16),
            lightningHeaderLabel.leadingAnchor.constraint(equalTo: lightningCardView.leadingAnchor, constant: 16),
            lightningHeaderLabel.trailingAnchor.constraint(equalTo: lightningCardView.trailingAnchor, constant: -16),

            lightningTimerLabel.topAnchor.constraint(equalTo: lightningHeaderLabel.bottomAnchor, constant: 8),
            lightningTimerLabel.leadingAnchor.constraint(equalTo: lightningCardView.leadingAnchor, constant: 16),
            lightningTimerLabel.trailingAnchor.constraint(equalTo: lightningCardView.trailingAnchor, constant: -16),
            lightningTimerLabel.bottomAnchor.constraint(equalTo: lightningCardView.bottomAnchor, constant: -16),
        ])

        lightningCardView.isHidden = true
    }

    // MARK: - Observation

    private func observeGameViewModel() {
        gameViewModel.$currentPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDisplayMode() }
            .store(in: &cancellables)

        gameViewModel.$displayTeamName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in self?.teamNameLabel.text = name.isEmpty ? "Team Trivia" : name }
            .store(in: &cancellables)

        gameViewModel.$displayRoundNumber
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roundNumber in
                self?.roundLabel.text = roundNumber > 0 ? "ROUND \(roundNumber)" : ""
            }
            .store(in: &cancellables)

        gameViewModel.$displayCategory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] category in self?.categoryLabel.text = category }
            .store(in: &cancellables)

        gameViewModel.$displayQuestionInRound
            .receive(on: DispatchQueue.main)
            .sink { [weak self] question in
                self?.questionLabel.text = question > 0 ? "Question \(question) / 5" : ""
            }
            .store(in: &cancellables)

        gameViewModel.$displayRoundCorrect
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateScoreDisplay() }
            .store(in: &cancellables)

        gameViewModel.$displayTotalCorrect
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateScoreDisplay() }
            .store(in: &cancellables)

        gameViewModel.$lightningSecondsRemaining
            .receive(on: DispatchQueue.main)
            .sink { [weak self] seconds in self?.updateLightningDisplay(seconds) }
            .store(in: &cancellables)
    }

    private func updateDisplayMode() {
        let isPlaying = [GamePhase.playing, .speaking, .listening, .showingResult, .waiting, .paused].contains(gameViewModel.currentPhase)
        appIconView.isHidden = isPlaying
        titleLabel.isHidden = isPlaying
        subtitleLabel.isHidden = isPlaying
        idleMessageLabel.isHidden = isPlaying
        playingContainer.isHidden = !isPlaying
    }

    private func updateScoreDisplay() {
        roundPointsLabel.text = "Round     \(gameViewModel.roundPoints) pts"
        totalPointsLabel.text = "Total     \(gameViewModel.totalPoints) pts"
    }

    private func updateLightningDisplay(_ seconds: Int?) {
        if let seconds = seconds, seconds > 0 {
            let mins = seconds / 60
            let secs = seconds % 60
            lightningTimerLabel.text = String(format: "%d:%02d", mins, secs)
            lightningCardView.isHidden = false
        } else {
            lightningCardView.isHidden = true
        }
    }

    private func requestPermissions() {
        LocationService.shared.requestAuthorization()
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { _ in }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }
    }

    // MARK: - Account Settings

    @objc private func showAccountSettings() {
        let sheet = AccountSettingsSheet(authService: authService)
        let nav = UINavigationController(rootViewController: sheet)
        nav.modalPresentationStyle = .formSheet
        if #available(iOS 16.0, *) {
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
            }
        }
        present(nav, animated: true)
    }
}

// MARK: - Account Settings Sheet

class AccountSettingsSheet: UIViewController {
    let authService: AuthService
    private var isAuthenticated = false

    init(authService: AuthService) {
        self.authService = authService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        navigationItem.title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissSheet))

        isAuthenticated = authService.isAuthenticated
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        if !isAuthenticated {
            let appleButton = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
            appleButton.addTarget(self, action: #selector(handleSignInWithApple), for: .touchUpInside)
            appleButton.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(appleButton)
            NSLayoutConstraint.activate([appleButton.widthAnchor.constraint(equalToConstant: 280)])
        } else {
            let signOutButton = UIButton(configuration: .filled())
            signOutButton.setTitle("Sign Out", for: .normal)
            signOutButton.addTarget(self, action: #selector(handleSignOut), for: .touchUpInside)
            stack.addArrangedSubview(signOutButton)
            NSLayoutConstraint.activate([signOutButton.widthAnchor.constraint(equalToConstant: 200)])
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    @objc private func dismissSheet() {
        dismiss(animated: true)
    }

    @objc private func handleSignInWithApple() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    @objc private func handleSignOut() {
        authService.signOut()
        dismiss(animated: true)
    }
}

extension AccountSettingsSheet: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        authService.signInWithApple(credential: credential) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss(animated: true)
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("[Auth] Sign in failed: \(error.localizedDescription)")
    }
}

extension AccountSettingsSheet: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        view.window!
    }
}
