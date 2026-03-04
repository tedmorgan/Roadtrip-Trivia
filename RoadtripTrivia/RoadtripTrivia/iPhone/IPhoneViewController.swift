import UIKit
import Combine
import AuthenticationServices
import AVFoundation

/// iPhone companion screen showing game status during play and auth/setup when idle.
/// All gameplay happens on CarPlay; iPhone shows team name, round, score, and lightning timer.
/// Auth and settings are hidden behind a gear icon in the nav bar.
class IPhoneViewController: UIViewController {

    private let gameViewModel = GameViewModel.shared
    private let authService = AuthService.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Color Scheme (from app icon)
    let colorNavyBlue = UIColor(red: 0x1B / 255.0, green: 0x3A / 255.0, blue: 0x6B / 255.0, alpha: 1.0)
    let colorDarkBlue = UIColor(red: 0x0F / 255.0, green: 0x24 / 255.0, blue: 0x47 / 255.0, alpha: 1.0)
    let colorCrimsonRed = UIColor(red: 0xC0 / 255.0, green: 0x39 / 255.0, blue: 0x2B / 255.0, alpha: 1.0)
    let colorGoldenYellow = UIColor(red: 0xF4 / 255.0, green: 0xC4 / 255.0, blue: 0x30 / 255.0, alpha: 1.0)
    let colorSkyBlue = UIColor(red: 0x29 / 255.0, green: 0x80 / 255.0, blue: 0xB9 / 255.0, alpha: 1.0)

    // Fun rounded fonts helper
    private func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let systemFont = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return systemFont
    }

    // MARK: - Views
    private let scrollView = UIScrollView()
    private let contentView = UIView()

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
    private let lightningTimerLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        print("[IPhoneViewController] viewDidLoad called")

        view.backgroundColor = colorNavyBlue
        setupGradientBackground()
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

    // MARK: - Setup

    private func setupGradientBackground() {
        let gradient = CAGradientLayer()
        gradient.colors = [colorNavyBlue.cgColor, colorDarkBlue.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.frame = view.bounds
        view.layer.insertSublayer(gradient, at: 0)
    }

    private func setupNavigationBar() {
        navigationController?.navigationBar.barStyle = .black
        navigationController?.navigationBar.barTintColor = colorNavyBlue
        navigationController?.navigationBar.isTranslucent = false

        let titleView = UILabel()
        titleView.text = "Roadtrip Trivia"
        titleView.font = roundedFont(size: 22, weight: .heavy)
        titleView.textColor = colorGoldenYellow
        navigationItem.titleView = titleView

        let gearButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape.fill"),
            style: .plain,
            target: self,
            action: #selector(showAccountSettings)
        )
        gearButton.tintColor = colorGoldenYellow
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

    private func setupIdleStateViews() {
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.image = UIImage(named: "AppIcon") ?? UIImage(systemName: "car.fill")
        appIconView.contentMode = .scaleAspectFit
        appIconView.layer.cornerRadius = 60
        appIconView.clipsToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "ROADTRIP\nTRIVIA"
        titleLabel.font = roundedFont(size: 52, weight: .heavy)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Your CarPlay trivia adventure"
        subtitleLabel.font = roundedFont(size: 22, weight: .medium)
        subtitleLabel.textColor = colorSkyBlue
        subtitleLabel.textAlignment = .center

        idleMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        idleMessageLabel.text = "Connect to CarPlay\nto start playing!"
        idleMessageLabel.font = roundedFont(size: 24, weight: .semibold)
        idleMessageLabel.textColor = colorGoldenYellow
        idleMessageLabel.textAlignment = .center
        idleMessageLabel.numberOfLines = 0

        contentView.addSubview(appIconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(idleMessageLabel)

        NSLayoutConstraint.activate([
            appIconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 60),
            appIconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 120),
            appIconView.heightAnchor.constraint(equalToConstant: 120),

            titleLabel.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            idleMessageLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 40),
            idleMessageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            idleMessageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            idleMessageLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func setupPlayingStateViews() {
        playingContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playingContainer)

        // Team name — BIG and fun
        teamNameLabel.translatesAutoresizingMaskIntoConstraints = false
        teamNameLabel.font = roundedFont(size: 48, weight: .heavy)
        teamNameLabel.textColor = colorGoldenYellow
        teamNameLabel.textAlignment = .center
        teamNameLabel.adjustsFontSizeToFitWidth = true
        teamNameLabel.minimumScaleFactor = 0.7

        // Round label — large and bold
        roundLabel.translatesAutoresizingMaskIntoConstraints = false
        roundLabel.font = roundedFont(size: 38, weight: .bold)
        roundLabel.textColor = .white
        roundLabel.textAlignment = .center

        // Category — readable and colorful
        categoryLabel.translatesAutoresizingMaskIntoConstraints = false
        categoryLabel.font = roundedFont(size: 24, weight: .medium)
        categoryLabel.textColor = colorSkyBlue
        categoryLabel.textAlignment = .center
        categoryLabel.numberOfLines = 2
        categoryLabel.adjustsFontSizeToFitWidth = true
        categoryLabel.minimumScaleFactor = 0.8

        playingContainer.addSubview(teamNameLabel)
        playingContainer.addSubview(roundLabel)
        playingContainer.addSubview(categoryLabel)

        // Score card — full width, bigger padding
        scoreCardView.translatesAutoresizingMaskIntoConstraints = false
        scoreCardView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        scoreCardView.layer.cornerRadius = 20
        scoreCardView.layer.borderWidth = 1.5
        scoreCardView.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        playingContainer.addSubview(scoreCardView)

        // Score labels — all much bigger
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.font = roundedFont(size: 30, weight: .semibold)
        questionLabel.textColor = .white
        questionLabel.textAlignment = .center

        roundPointsLabel.translatesAutoresizingMaskIntoConstraints = false
        roundPointsLabel.font = roundedFont(size: 36, weight: .heavy)
        roundPointsLabel.textColor = colorGoldenYellow
        roundPointsLabel.textAlignment = .center

        totalPointsLabel.translatesAutoresizingMaskIntoConstraints = false
        totalPointsLabel.font = roundedFont(size: 28, weight: .bold)
        totalPointsLabel.textColor = .white
        totalPointsLabel.textAlignment = .center

        scoreCardView.addSubview(questionLabel)
        scoreCardView.addSubview(roundPointsLabel)
        scoreCardView.addSubview(totalPointsLabel)

        NSLayoutConstraint.activate([
            playingContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            playingContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playingContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            teamNameLabel.topAnchor.constraint(equalTo: playingContainer.topAnchor, constant: 10),
            teamNameLabel.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            teamNameLabel.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            roundLabel.topAnchor.constraint(equalTo: teamNameLabel.bottomAnchor, constant: 6),
            roundLabel.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            roundLabel.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            categoryLabel.topAnchor.constraint(equalTo: roundLabel.bottomAnchor, constant: 4),
            categoryLabel.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            categoryLabel.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            scoreCardView.topAnchor.constraint(equalTo: categoryLabel.bottomAnchor, constant: 24),
            scoreCardView.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            scoreCardView.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            questionLabel.topAnchor.constraint(equalTo: scoreCardView.topAnchor, constant: 20),
            questionLabel.leadingAnchor.constraint(equalTo: scoreCardView.leadingAnchor, constant: 20),
            questionLabel.trailingAnchor.constraint(equalTo: scoreCardView.trailingAnchor, constant: -20),

            roundPointsLabel.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 14),
            roundPointsLabel.leadingAnchor.constraint(equalTo: scoreCardView.leadingAnchor, constant: 20),
            roundPointsLabel.trailingAnchor.constraint(equalTo: scoreCardView.trailingAnchor, constant: -20),

            totalPointsLabel.topAnchor.constraint(equalTo: roundPointsLabel.bottomAnchor, constant: 10),
            totalPointsLabel.leadingAnchor.constraint(equalTo: scoreCardView.leadingAnchor, constant: 20),
            totalPointsLabel.trailingAnchor.constraint(equalTo: scoreCardView.trailingAnchor, constant: -20),
            totalPointsLabel.bottomAnchor.constraint(equalTo: scoreCardView.bottomAnchor, constant: -20),
        ])
    }

    private func setupLightningCard() {
        lightningCardView.translatesAutoresizingMaskIntoConstraints = false
        lightningCardView.backgroundColor = colorCrimsonRed
        lightningCardView.layer.cornerRadius = 20
        playingContainer.addSubview(lightningCardView)

        let lightningLabelView = UILabel()
        lightningLabelView.translatesAutoresizingMaskIntoConstraints = false
        lightningLabelView.text = "⚡ LIGHTNING ROUND"
        lightningLabelView.font = roundedFont(size: 28, weight: .heavy)
        lightningLabelView.textColor = .white
        lightningLabelView.textAlignment = .center
        lightningCardView.addSubview(lightningLabelView)

        lightningTimerLabel.translatesAutoresizingMaskIntoConstraints = false
        lightningTimerLabel.text = "2:00"
        lightningTimerLabel.font = .monospacedDigitSystemFont(ofSize: 80, weight: .bold)
        lightningTimerLabel.textColor = .white
        lightningTimerLabel.textAlignment = .center
        lightningCardView.addSubview(lightningTimerLabel)

        NSLayoutConstraint.activate([
            lightningCardView.topAnchor.constraint(equalTo: scoreCardView.bottomAnchor, constant: 24),
            lightningCardView.leadingAnchor.constraint(equalTo: playingContainer.leadingAnchor, constant: 16),
            lightningCardView.trailingAnchor.constraint(equalTo: playingContainer.trailingAnchor, constant: -16),

            lightningLabelView.topAnchor.constraint(equalTo: lightningCardView.topAnchor, constant: 20),
            lightningLabelView.leadingAnchor.constraint(equalTo: lightningCardView.leadingAnchor, constant: 20),
            lightningLabelView.trailingAnchor.constraint(equalTo: lightningCardView.trailingAnchor, constant: -20),

            lightningTimerLabel.topAnchor.constraint(equalTo: lightningLabelView.bottomAnchor, constant: 10),
            lightningTimerLabel.leadingAnchor.constraint(equalTo: lightningCardView.leadingAnchor, constant: 20),
            lightningTimerLabel.trailingAnchor.constraint(equalTo: lightningCardView.trailingAnchor, constant: -20),
            lightningTimerLabel.bottomAnchor.constraint(equalTo: lightningCardView.bottomAnchor, constant: -20),
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
