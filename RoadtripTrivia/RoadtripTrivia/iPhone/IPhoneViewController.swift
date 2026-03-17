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
    private let signInNoticeLabel = UILabel()

    // Playing state views (stacked in a container)
    private let playingContainer = UIView()
    private let playingAppTitleLabel = UILabel()
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
        startCarPlayPolling()
        updateDisplayMode()

        // Show "sign in to play" notice until user is authenticated
        signInNoticeLabel.isHidden = authService.isAuthenticated
        authService.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthed in
                self?.signInNoticeLabel.isHidden = isAuthed
            }
            .store(in: &cancellables)

        print("[IPhoneViewController] viewDidLoad complete")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateDisplayMode()
    }

    // MARK: - CarPlay Connection Polling

    private var carPlayPollTimer: Timer?
    private var lastKnownCarPlayState = false

    private func startCarPlayPolling() {
        carPlayPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let connected = self.isCarPlayConnected
            if connected != self.lastKnownCarPlayState {
                self.lastKnownCarPlayState = connected
                self.updateDisplayMode()
            }
        }
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
            UIColor(red: 0x15 / 255.0, green: 0x00 / 255.0, blue: 0x30 / 255.0, alpha: 1.0).cgColor
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

        let trophyButton = UIBarButtonItem(
            image: UIImage(systemName: "trophy.fill"),
            style: .plain,
            target: self,
            action: #selector(showLeaderboards)
        )
        trophyButton.tintColor = colorNeonCyan
        navigationItem.leftBarButtonItem = trophyButton

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

        signInNoticeLabel.translatesAutoresizingMaskIntoConstraints = false
        signInNoticeLabel.text = "Sign in or create an account on your iPhone before playing on CarPlay."
        signInNoticeLabel.font = roundedFont(size: 14, weight: .medium)
        signInNoticeLabel.textColor = UIColor.systemOrange
        signInNoticeLabel.textAlignment = .center
        signInNoticeLabel.numberOfLines = 0

        contentView.addSubview(appIconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(idleMessageLabel)
        contentView.addSubview(signInNoticeLabel)

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

            idleMessageLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 32),
            idleMessageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            idleMessageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            signInNoticeLabel.topAnchor.constraint(equalTo: idleMessageLabel.bottomAnchor, constant: 12),
            signInNoticeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            signInNoticeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            signInNoticeLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
        ])
    }

    // MARK: - Playing State

    private func setupPlayingStateViews() {
        playingContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playingContainer)

        // Compact app title shown during gameplay
        playingAppTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        playingAppTitleLabel.text = "Roadtrip Trivia"
        playingAppTitleLabel.font = roundedFont(size: 18, weight: .semibold)
        playingAppTitleLabel.textColor = colorNeonPink.withAlphaComponent(0.8)
        playingAppTitleLabel.textAlignment = .center

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

        playingContainer.addSubview(playingAppTitleLabel)
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

            playingAppTitleLabel.topAnchor.constraint(equalTo: playingContainer.topAnchor, constant: 4),
            playingAppTitleLabel.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            playingAppTitleLabel.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            teamNameLabel.topAnchor.constraint(equalTo: playingAppTitleLabel.bottomAnchor, constant: 2),
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
        lightningHeaderLabel.font = roundedFont(size: 26, weight: .heavy)
        lightningHeaderLabel.textColor = colorNeonOrange
        lightningHeaderLabel.textAlignment = .center
        lightningHeaderLabel.adjustsFontSizeToFitWidth = true
        lightningHeaderLabel.minimumScaleFactor = 0.7
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

    private var isCarPlayConnected: Bool {
        UIApplication.shared.connectedScenes.contains { $0.session.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication" }
    }

    private func updateDisplayMode() {
        let isPlaying = [GamePhase.playing, .speaking, .listening, .showingResult, .waiting, .paused].contains(gameViewModel.currentPhase)
        appIconView.isHidden = isPlaying
        titleLabel.isHidden = isPlaying
        subtitleLabel.isHidden = isPlaying
        idleMessageLabel.isHidden = isPlaying
        playingContainer.isHidden = !isPlaying

        if !isPlaying {
            if isCarPlayConnected {
                idleMessageLabel.text = "Connected to CarPlay\nStart a game from your car screen!"
            } else {
                idleMessageLabel.text = "Connect to CarPlay\nto start playing!"
            }
        }
    }

    private static let pointsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func formattedPoints(_ value: Int) -> String {
        Self.pointsFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func updateScoreDisplay() {
        roundPointsLabel.text = "Round     \(formattedPoints(gameViewModel.roundPoints)) pts"
        totalPointsLabel.text = "Total     \(formattedPoints(gameViewModel.totalPoints)) pts"
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
            if let sheetController = nav.sheetPresentationController {
                sheetController.detents = [.medium(), .large()]
                sheetController.prefersGrabberVisible = true
                sheetController.selectedDetentIdentifier = .large
            }
        }
        present(nav, animated: true)
    }

    @objc private func showLeaderboards() {
        let vc = LeaderboardViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }
}

// MARK: - Leaderboards

enum LeaderboardPeriod: String, CaseIterable {
    case day = "day"
    case month = "month"
    case allTime = "all"

    var title: String {
        switch self {
        case .day: return "Today"
        case .month: return "This Month"
        case .allTime: return "All Time"
        }
    }
}

struct LeaderboardEntry: Decodable {
    let team_name: String
    let score: Int
    let played_at: String?
}

final class LeaderboardViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let periods: [LeaderboardPeriod] = [.day, .month, .allTime]
    private var selectedPeriod: LeaderboardPeriod = .day
    private var entries: [LeaderboardEntry] = []

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let segmentedControl = UISegmentedControl(items: ["Today", "This Month", "All Time"])
    private let activity = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.black
        title = "Leaderboards"

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissSelf)
        )

        setupSegmentedControl()
        setupTableView()
        setupActivity()
        setupErrorLabel()

        loadData()
    }

    @objc private func dismissSelf() {
        dismiss(animated: true)
    }

    private func setupSegmentedControl() {
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(periodChanged), for: .valueChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        // Improve contrast so non-selected segments are still clearly visible.
        segmentedControl.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        segmentedControl.selectedSegmentTintColor = UIColor.white
        segmentedControl.setTitleTextAttributes(
            [.foregroundColor: UIColor.black,
             .font: UIFont.systemFont(ofSize: 14, weight: .semibold)],
            for: .selected
        )
        segmentedControl.setTitleTextAttributes(
            [.foregroundColor: UIColor.white.withAlphaComponent(0.8),
             .font: UIFont.systemFont(ofSize: 14, weight: .regular)],
            for: .normal
        )

        view.addSubview(segmentedControl)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupActivity() {
        activity.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activity)
        NSLayoutConstraint.activate([
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func setupErrorLabel() {
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .systemOrange
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        errorLabel.isHidden = true
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func periodChanged() {
        selectedPeriod = periods[segmentedControl.selectedSegmentIndex]
        loadData()
    }

    private func loadData() {
        errorLabel.isHidden = true
        activity.startAnimating()

        fetchLeaderboard(period: selectedPeriod) { [weak self] result in
            guard let self else { return }
            self.activity.stopAnimating()
            switch result {
            case .success(let entries):
                self.entries = entries
                self.tableView.reloadData()
            case .failure(let error):
                self.errorLabel.text = "Failed to load leaderboards:\n\(error.localizedDescription)"
                self.errorLabel.isHidden = false
            }
        }
    }

    private func fetchLeaderboard(period: LeaderboardPeriod,
                                  completion: @escaping (Result<[LeaderboardEntry], Error>) -> Void) {
        let auth = AuthService.shared
        let baseURL = auth.supabaseApiBaseURL
        let apiKey = auth.supabaseApiKey

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("/rest/v1/leaderboard_scores"),
            resolvingAgainstBaseURL: false
        ) else { return }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "select", value: "team_name,score,played_at"),
            URLQueryItem(name: "order", value: "score.desc"),
            URLQueryItem(name: "limit", value: "50")
        ]

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        switch period {
        case .day:
            if let startOfDay = Calendar.current.date(bySettingHour: 0, minute: 0, second: 0, of: now) {
                queryItems.append(URLQueryItem(name: "played_at", value: "gte.\(isoFormatter.string(from: startOfDay))"))
            }
        case .month:
            if let startOfMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) {
                queryItems.append(URLQueryItem(name: "played_at", value: "gte.\(isoFormatter.string(from: startOfMonth))"))
            }
        case .allTime:
            break
        }

        components.queryItems = queryItems
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  let data = data else {
                DispatchQueue.main.async { completion(.success([])) }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let err = NSError(domain: "Leaderboard",
                                  code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: body])
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            do {
                let entries = try JSONDecoder().decode([LeaderboardEntry].self, from: data)
                DispatchQueue.main.async { completion(.success(entries)) }
            } catch {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[Leaderboard] Decode failed: \(error). Body: \(body)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cellId = "cell"
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId) ??
            UITableViewCell(style: .subtitle, reuseIdentifier: cellId)

        let entry = entries[indexPath.row]
        cell.backgroundColor = .clear
        cell.textLabel?.textColor = .white
        cell.detailTextLabel?.textColor = .lightGray

        let rank = indexPath.row + 1
        cell.textLabel?.text = "#\(rank)  \(entry.team_name)"
        cell.detailTextLabel?.text = "\(entry.score) pts"

        return cell
    }
}


// MARK: - Account Settings Sheet

class AccountSettingsSheet: UIViewController {

    private let authService: AuthService

    // MARK: - Color Palette (matches app theme)
    private let colorDeepPurple = UIColor(red: 0x1A / 255.0, green: 0x0A / 255.0, blue: 0x2E / 255.0, alpha: 1.0)
    private let colorDarkVoid = UIColor(red: 0x0D / 255.0, green: 0x02 / 255.0, blue: 0x21 / 255.0, alpha: 1.0)
    private let colorNeonPink = UIColor(red: 0xFF / 255.0, green: 0x2D / 255.0, blue: 0x95 / 255.0, alpha: 1.0)
    private let colorNeonYellow = UIColor(red: 0xFF / 255.0, green: 0xE0 / 255.0, blue: 0x00 / 255.0, alpha: 1.0)
    private let colorNeonCyan = UIColor(red: 0x00 / 255.0, green: 0xFF / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
    private let colorNeonGreen = UIColor(red: 0x00 / 255.0, green: 0xFF / 255.0, blue: 0x65 / 255.0, alpha: 1.0)
    private let colorNeonOrange = UIColor(red: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x00 / 255.0, alpha: 1.0)
    private let colorGridPurple = UIColor(red: 0x6B / 255.0, green: 0x00 / 255.0, blue: 0xCC / 255.0, alpha: 1.0)

    // MARK: - UI State
    private enum AuthMode { case signIn, createAccount }
    private var currentMode: AuthMode = .signIn

    // Shared UI
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    // Tag constants for themed text fields
    private static let emailFieldTag = 100
    private static let passwordFieldTag = 101

    init(authService: AuthService) {
        self.authService = authService
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupGradientBackground()

        navigationItem.title = "Account"
        navigationController?.navigationBar.barStyle = .black
        navigationController?.navigationBar.barTintColor = colorDarkVoid
        navigationController?.navigationBar.titleTextAttributes = [
            .foregroundColor: colorNeonPink,
            .font: roundedFont(size: 18, weight: .bold)
        ]
        let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissSheet))
        doneButton.tintColor = colorNeonCyan
        navigationItem.rightBarButtonItem = doneButton

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)

        // Tap to dismiss keyboard
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tapGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tapGesture)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: scrollView.bottomAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        if authService.isAuthenticated {
            buildAuthenticatedUI()
        } else {
            buildUnauthenticatedUI()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let gradient = view.layer.sublayers?.first as? CAGradientLayer {
            gradient.frame = view.bounds
        }
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        let keyboardHeight = keyboardFrame.height - view.safeAreaInsets.bottom
        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset.bottom = keyboardHeight + 20
            self.scrollView.verticalScrollIndicatorInsets.bottom = keyboardHeight
        }
        // Scroll to active field
        if let activeField = view.findFirstResponder() {
            let fieldFrame = activeField.convert(activeField.bounds, to: scrollView)
            scrollView.scrollRectToVisible(fieldFrame.insetBy(dx: 0, dy: -60), animated: true)
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset.bottom = 0
            self.scrollView.verticalScrollIndicatorInsets.bottom = 0
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - Background

    private func setupGradientBackground() {
        let gradient = CAGradientLayer()
        gradient.colors = [colorDeepPurple.cgColor, colorDarkVoid.cgColor]
        gradient.locations = [0.0, 1.0]
        gradient.frame = view.bounds
        view.layer.insertSublayer(gradient, at: 0)
    }

    // MARK: - Theme Helpers

    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let systemFont = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return systemFont
    }

    private func applyNeonGlow(to view: UIView, color: UIColor, radius: CGFloat = 12, opacity: Float = 0.9) {
        view.layer.shadowColor = color.cgColor
        view.layer.shadowRadius = radius
        view.layer.shadowOpacity = opacity
        view.layer.shadowOffset = .zero
    }

    private func makeNeonButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = roundedFont(size: 17, weight: .bold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = color.withAlphaComponent(0.2)
        button.layer.cornerRadius = 12
        button.layer.borderWidth = 1.5
        button.layer.borderColor = color.cgColor
        applyNeonGlow(to: button, color: color, radius: 8, opacity: 0.5)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func makeThemedTextField(placeholder: String, isSecure: Bool = false, tag: Int) -> UITextField {
        let field = UITextField()
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.4)]
        )
        field.textColor = .white
        field.font = roundedFont(size: 16, weight: .medium)
        field.backgroundColor = colorDarkVoid.withAlphaComponent(0.8)
        field.layer.cornerRadius = 10
        field.layer.borderWidth = 1
        field.layer.borderColor = colorGridPurple.cgColor
        field.isSecureTextEntry = isSecure
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardAppearance = .dark
        field.returnKeyType = isSecure ? .go : .next
        field.delegate = self
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftViewMode = .always
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true
        field.tag = tag
        return field
    }

    private func makeSectionHeader(title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = roundedFont(size: 13, weight: .bold)
        label.textColor = colorNeonCyan.withAlphaComponent(0.7)
        return label
    }

    private func makeSectionCard() -> UIView {
        let card = UIView()
        card.backgroundColor = colorDeepPurple.withAlphaComponent(0.6)
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.layer.borderColor = colorGridPurple.withAlphaComponent(0.4).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private func makeOrDivider() -> UIView {
        let container = UIStackView()
        container.axis = .horizontal
        container.spacing = 12
        container.alignment = .center

        let leftLine = UIView()
        leftLine.backgroundColor = colorGridPurple.withAlphaComponent(0.5)
        leftLine.translatesAutoresizingMaskIntoConstraints = false
        leftLine.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let orLabel = UILabel()
        orLabel.text = "or"
        orLabel.textColor = colorGridPurple
        orLabel.font = roundedFont(size: 14, weight: .medium)

        let rightLine = UIView()
        rightLine.backgroundColor = colorGridPurple.withAlphaComponent(0.5)
        rightLine.translatesAutoresizingMaskIntoConstraints = false
        rightLine.heightAnchor.constraint(equalToConstant: 1).isActive = true

        container.addArrangedSubview(leftLine)
        container.addArrangedSubview(orLabel)
        container.addArrangedSubview(rightLine)
        leftLine.widthAnchor.constraint(equalTo: rightLine.widthAnchor).isActive = true

        return container
    }

    private func makeActionRow(icon: String, title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = color
        iconView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
        ])

        let label = UILabel()
        label.text = title
        label.font = roundedFont(size: 16, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = color.withAlphaComponent(0.5)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(chevron)
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])

        return button
    }

    private func makeRowSeparator() -> UIView {
        let sep = UIView()
        sep.backgroundColor = colorGridPurple.withAlphaComponent(0.3)
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return sep
    }

    // MARK: - Unauthenticated UI

    private func buildUnauthenticatedUI() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Segmented control
        let segmentedControl = UISegmentedControl(items: ["Sign In", "Create Account"])
        segmentedControl.selectedSegmentIndex = currentMode == .signIn ? 0 : 1
        segmentedControl.selectedSegmentTintColor = colorNeonPink.withAlphaComponent(0.3)
        segmentedControl.setTitleTextAttributes([
            .foregroundColor: UIColor.white.withAlphaComponent(0.6),
            .font: roundedFont(size: 14, weight: .semibold)
        ], for: .normal)
        segmentedControl.setTitleTextAttributes([
            .foregroundColor: colorNeonPink,
            .font: roundedFont(size: 14, weight: .bold)
        ], for: .selected)
        segmentedControl.backgroundColor = colorDarkVoid.withAlphaComponent(0.6)
        segmentedControl.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(segmentedControl)

        // Social sign-in card
        let socialCard = makeSectionCard()
        let socialStack = UIStackView()
        socialStack.axis = .vertical
        socialStack.spacing = 12
        socialStack.alignment = .fill
        socialStack.translatesAutoresizingMaskIntoConstraints = false
        socialCard.addSubview(socialStack)
        NSLayoutConstraint.activate([
            socialStack.topAnchor.constraint(equalTo: socialCard.topAnchor, constant: 16),
            socialStack.leadingAnchor.constraint(equalTo: socialCard.leadingAnchor, constant: 16),
            socialStack.trailingAnchor.constraint(equalTo: socialCard.trailingAnchor, constant: -16),
            socialStack.bottomAnchor.constraint(equalTo: socialCard.bottomAnchor, constant: -16),
        ])

        let appleButton = ASAuthorizationAppleIDButton(type: .signIn, style: .white)
        appleButton.cornerRadius = 12
        appleButton.addTarget(self, action: #selector(handleSignInWithApple), for: .touchUpInside)
        appleButton.translatesAutoresizingMaskIntoConstraints = false
        appleButton.heightAnchor.constraint(equalToConstant: 50).isActive = true
        socialStack.addArrangedSubview(appleButton)

        let googleButton = makeNeonButton(
            title: "  Sign in with Google",
            color: UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0),
            action: #selector(handleSignInWithGoogle)
        )
        googleButton.setImage(UIImage(systemName: "g.circle.fill"), for: .normal)
        googleButton.tintColor = .white
        socialStack.addArrangedSubview(googleButton)

        contentStack.addArrangedSubview(socialCard)

        // "or" divider
        contentStack.addArrangedSubview(makeOrDivider())

        // Email/password card
        let emailCard = makeSectionCard()
        let emailStack = UIStackView()
        emailStack.axis = .vertical
        emailStack.spacing = 12
        emailStack.alignment = .fill
        emailStack.translatesAutoresizingMaskIntoConstraints = false
        emailCard.addSubview(emailStack)
        NSLayoutConstraint.activate([
            emailStack.topAnchor.constraint(equalTo: emailCard.topAnchor, constant: 16),
            emailStack.leadingAnchor.constraint(equalTo: emailCard.leadingAnchor, constant: 16),
            emailStack.trailingAnchor.constraint(equalTo: emailCard.trailingAnchor, constant: -16),
            emailStack.bottomAnchor.constraint(equalTo: emailCard.bottomAnchor, constant: -16),
        ])

        let themedEmail = makeThemedTextField(placeholder: "Email", tag: Self.emailFieldTag)
        themedEmail.keyboardType = .emailAddress
        emailStack.addArrangedSubview(themedEmail)

        let themedPassword = makeThemedTextField(placeholder: "Password", isSecure: true, tag: Self.passwordFieldTag)
        emailStack.addArrangedSubview(themedPassword)

        // "Forgot Password?" link — only in sign-in mode
        if currentMode == .signIn {
            let forgotButton = UIButton(type: .system)
            forgotButton.setTitle("Forgot Password?", for: .normal)
            forgotButton.titleLabel?.font = roundedFont(size: 14, weight: .medium)
            forgotButton.setTitleColor(colorNeonCyan, for: .normal)
            forgotButton.contentHorizontalAlignment = .trailing
            forgotButton.addTarget(self, action: #selector(handleForgotPassword), for: .touchUpInside)
            emailStack.addArrangedSubview(forgotButton)
        }

        let actionTitle = currentMode == .signIn ? "Sign In" : "Create Account"
        let actionSelector = currentMode == .signIn ? #selector(handleEmailSignIn) : #selector(handleEmailSignUp)
        let actionButton = makeNeonButton(title: actionTitle, color: colorNeonPink, action: actionSelector)
        emailStack.addArrangedSubview(actionButton)

        contentStack.addArrangedSubview(emailCard)

        // Status label
        statusLabel.textColor = colorNeonOrange
        statusLabel.font = roundedFont(size: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = nil
        contentStack.addArrangedSubview(statusLabel)

        // Activity indicator
        activityIndicator.color = colorNeonCyan
        activityIndicator.hidesWhenStopped = true
        contentStack.addArrangedSubview(activityIndicator)
    }

    // MARK: - Authenticated UI

    private func buildAuthenticatedUI() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Account info card
        let infoCard = makeSectionCard()
        let infoStack = UIStackView()
        infoStack.axis = .vertical
        infoStack.spacing = 8
        infoStack.alignment = .center
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoCard.addSubview(infoStack)
        NSLayoutConstraint.activate([
            infoStack.topAnchor.constraint(equalTo: infoCard.topAnchor, constant: 20),
            infoStack.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 16),
            infoStack.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor, constant: -16),
            infoStack.bottomAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: -20),
        ])

        // Avatar circle
        let avatarView = UIView()
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 64),
            avatarView.heightAnchor.constraint(equalToConstant: 64),
        ])
        avatarView.layer.cornerRadius = 32
        avatarView.backgroundColor = colorGridPurple.withAlphaComponent(0.4)
        avatarView.layer.borderWidth = 2
        avatarView.layer.borderColor = colorNeonCyan.cgColor
        applyNeonGlow(to: avatarView, color: colorNeonCyan, radius: 10, opacity: 0.4)

        let avatarIcon = UIImageView(image: UIImage(systemName: "person.fill"))
        avatarIcon.tintColor = colorNeonCyan
        avatarIcon.translatesAutoresizingMaskIntoConstraints = false
        avatarView.addSubview(avatarIcon)
        NSLayoutConstraint.activate([
            avatarIcon.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarIcon.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            avatarIcon.widthAnchor.constraint(equalToConstant: 28),
            avatarIcon.heightAnchor.constraint(equalToConstant: 28),
        ])
        infoStack.addArrangedSubview(avatarView)

        // Email label
        let emailLabel = UILabel()
        emailLabel.text = authService.currentEmail ?? "Signed in"
        emailLabel.font = roundedFont(size: 17, weight: .semibold)
        emailLabel.textColor = .white
        emailLabel.textAlignment = .center
        infoStack.addArrangedSubview(emailLabel)

        // Fetch email if not cached
        if authService.currentEmail == nil {
            authService.fetchUserProfile { [weak emailLabel] email in
                guard let email = email else { return }
                emailLabel?.text = email
            }
        }

        // User ID (truncated)
        if let userId = authService.currentUserID {
            let idLabel = UILabel()
            let truncated = String(userId.prefix(8)) + "..."
            idLabel.text = "ID: \(truncated)"
            idLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            idLabel.textColor = colorGridPurple
            idLabel.textAlignment = .center
            infoStack.addArrangedSubview(idLabel)
        }

        contentStack.addArrangedSubview(infoCard)

        // Account actions section
        contentStack.addArrangedSubview(makeSectionHeader(title: "ACCOUNT"))

        let actionsCard = makeSectionCard()
        let actionsStack = UIStackView()
        actionsStack.axis = .vertical
        actionsStack.spacing = 0
        actionsStack.alignment = .fill
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsCard.addSubview(actionsStack)
        NSLayoutConstraint.activate([
            actionsStack.topAnchor.constraint(equalTo: actionsCard.topAnchor),
            actionsStack.leadingAnchor.constraint(equalTo: actionsCard.leadingAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: actionsCard.trailingAnchor),
            actionsStack.bottomAnchor.constraint(equalTo: actionsCard.bottomAnchor),
        ])

        actionsStack.addArrangedSubview(makeActionRow(
            icon: "key.fill", title: "Change Password", color: colorNeonCyan,
            action: #selector(handleChangePassword)
        ))
        actionsStack.addArrangedSubview(makeRowSeparator())
        actionsStack.addArrangedSubview(makeActionRow(
            icon: "rectangle.portrait.and.arrow.right", title: "Sign Out", color: colorNeonYellow,
            action: #selector(handleSignOut)
        ))

        contentStack.addArrangedSubview(actionsCard)

        // Danger zone section
        contentStack.addArrangedSubview(makeSectionHeader(title: "DANGER ZONE"))

        let dangerCard = makeSectionCard()
        dangerCard.layer.borderColor = colorNeonOrange.withAlphaComponent(0.3).cgColor
        let dangerStack = UIStackView()
        dangerStack.axis = .vertical
        dangerStack.spacing = 0
        dangerStack.alignment = .fill
        dangerStack.translatesAutoresizingMaskIntoConstraints = false
        dangerCard.addSubview(dangerStack)
        NSLayoutConstraint.activate([
            dangerStack.topAnchor.constraint(equalTo: dangerCard.topAnchor),
            dangerStack.leadingAnchor.constraint(equalTo: dangerCard.leadingAnchor),
            dangerStack.trailingAnchor.constraint(equalTo: dangerCard.trailingAnchor),
            dangerStack.bottomAnchor.constraint(equalTo: dangerCard.bottomAnchor),
        ])

        dangerStack.addArrangedSubview(makeActionRow(
            icon: "trash.fill", title: "Delete Account", color: colorNeonOrange,
            action: #selector(handleDeleteAccount)
        ))

        contentStack.addArrangedSubview(dangerCard)

        // Version label
        let versionLabel = UILabel()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        versionLabel.text = "Roadtrip Trivia v\(version) (\(build))"
        versionLabel.font = roundedFont(size: 12, weight: .regular)
        versionLabel.textColor = colorGridPurple.withAlphaComponent(0.5)
        versionLabel.textAlignment = .center
        contentStack.addArrangedSubview(versionLabel)
    }

    // MARK: - Actions

    @objc private func dismissSheet() {
        dismiss(animated: true)
    }

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        currentMode = sender.selectedSegmentIndex == 0 ? .signIn : .createAccount
        buildUnauthenticatedUI()
    }

    @objc private func handleSignInWithApple() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        authService.prepareAppleSignInRequest(request)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    @objc private func handleSignInWithGoogle() {
        authService.signInWithGoogle(presentingViewController: self) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.dismiss(animated: true)
                } else {
                    self?.statusLabel.text = error ?? "Google sign-in failed"
                }
            }
        }
    }

    @objc private func handleEmailSignIn() {
        guard let email = (view.viewWithTag(Self.emailFieldTag) as? UITextField)?.text, !email.isEmpty,
              let password = (view.viewWithTag(Self.passwordFieldTag) as? UITextField)?.text, !password.isEmpty else {
            statusLabel.text = "Please enter email and password"
            return
        }
        statusLabel.text = nil
        activityIndicator.startAnimating()
        authService.signInWithEmail(email: email, password: password) { [weak self] success, error in
            self?.activityIndicator.stopAnimating()
            if success {
                self?.dismiss(animated: true)
            } else {
                self?.statusLabel.text = error ?? "Sign in failed"
            }
        }
    }

    @objc private func handleEmailSignUp() {
        guard let email = (view.viewWithTag(Self.emailFieldTag) as? UITextField)?.text, !email.isEmpty,
              let password = (view.viewWithTag(Self.passwordFieldTag) as? UITextField)?.text, !password.isEmpty else {
            statusLabel.text = "Please enter email and password"
            return
        }
        guard password.count >= 6 else {
            statusLabel.text = "Password must be at least 6 characters"
            return
        }
        statusLabel.text = nil
        activityIndicator.startAnimating()
        authService.signUpWithEmail(email: email, password: password) { [weak self] success, error in
            self?.activityIndicator.stopAnimating()
            if success {
                self?.dismiss(animated: true)
            } else {
                self?.statusLabel.text = error ?? "Sign up failed"
            }
        }
    }

    @objc private func handleForgotPassword() {
        let emailText = (view.viewWithTag(Self.emailFieldTag) as? UITextField)?.text ?? ""

        if emailText.isEmpty {
            let alert = UIAlertController(
                title: "Reset Password",
                message: "Enter your email address to receive a password reset link.",
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.placeholder = "Email address"
                field.keyboardType = .emailAddress
                field.autocapitalizationType = .none
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Send Reset Link", style: .default) { [weak self] _ in
                guard let email = alert.textFields?.first?.text, !email.isEmpty else { return }
                self?.performPasswordReset(email: email)
            })
            present(alert, animated: true)
        } else {
            performPasswordReset(email: emailText)
        }
    }

    private func performPasswordReset(email: String) {
        activityIndicator.startAnimating()
        statusLabel.text = nil

        authService.sendPasswordReset(email: email) { [weak self] success, error in
            self?.activityIndicator.stopAnimating()
            if success {
                self?.statusLabel.textColor = self?.colorNeonGreen
                self?.statusLabel.text = "Password reset link sent! Check your email."
            } else {
                self?.statusLabel.textColor = self?.colorNeonOrange
                self?.statusLabel.text = error ?? "Failed to send reset link"
            }
        }
    }

    @objc private func handleChangePassword() {
        guard let email = authService.currentEmail else {
            let alert = UIAlertController(
                title: "Change Password",
                message: "Unable to determine your email. Please sign out and use \"Forgot Password?\" on the sign-in screen.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let alert = UIAlertController(
            title: "Change Password",
            message: "We'll send a password reset link to \(email).",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Send Link", style: .default) { [weak self] _ in
            self?.authService.sendPasswordReset(email: email) { success, error in
                let resultAlert = UIAlertController(
                    title: success ? "Link Sent" : "Error",
                    message: success ? "Check your email for the password reset link." : (error ?? "Failed to send reset link."),
                    preferredStyle: .alert
                )
                resultAlert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(resultAlert, animated: true)
            }
        })
        present(alert, animated: true)
    }

    @objc private func handleSignOut() {
        let alert = UIAlertController(
            title: "Sign Out",
            message: "Are you sure you want to sign out?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            self?.authService.signOut()
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    @objc private func handleDeleteAccount() {
        let alert = UIAlertController(
            title: "Delete Account",
            message: "This will permanently delete your account and all associated data. This action cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete My Account", style: .destructive) { [weak self] _ in
            let confirm = UIAlertController(
                title: "Are you absolutely sure?",
                message: "Type DELETE to confirm account deletion.",
                preferredStyle: .alert
            )
            confirm.addTextField { field in
                field.placeholder = "Type DELETE"
                field.autocapitalizationType = .allCharacters
            }
            confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            confirm.addAction(UIAlertAction(title: "Delete Forever", style: .destructive) { [weak self] _ in
                guard confirm.textFields?.first?.text == "DELETE" else {
                    let errorAlert = UIAlertController(
                        title: "Not Deleted",
                        message: "You must type DELETE to confirm.",
                        preferredStyle: .alert
                    )
                    errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(errorAlert, animated: true)
                    return
                }
                self?.authService.deleteAccount { success in
                    if success {
                        self?.dismiss(animated: true)
                    } else {
                        let errorAlert = UIAlertController(
                            title: "Error",
                            message: "Failed to delete account. Please try again later.",
                            preferredStyle: .alert
                        )
                        errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(errorAlert, animated: true)
                    }
                }
            })
            self?.present(confirm, animated: true)
        })
        present(alert, animated: true)
    }
}

// MARK: - Apple Sign-In Delegates

extension AccountSettingsSheet: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        activityIndicator.startAnimating()
        statusLabel.text = nil
        authService.signInWithApple(credential: credential) { [weak self] success in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activityIndicator.stopAnimating()
                if success {
                    self.buildAuthenticatedUI()
                } else {
                    self.statusLabel.text = "Apple sign-in could not be completed. Please try again."
                }
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("[Auth] Apple sign-in failed: \(error.localizedDescription)")
        statusLabel.text = "Apple sign-in was cancelled or failed."
    }
}

extension AccountSettingsSheet: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField.tag == Self.emailFieldTag {
            // Move to password field
            view.viewWithTag(Self.passwordFieldTag)?.becomeFirstResponder()
        } else {
            // Dismiss keyboard and trigger sign-in
            textField.resignFirstResponder()
        }
        return true
    }
}

extension AccountSettingsSheet: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        view.window!
    }
}

// MARK: - UIView First Responder Finder
private extension UIView {
    func findFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for sub in subviews {
            if let found = sub.findFirstResponder() { return found }
        }
        return nil
    }
}
