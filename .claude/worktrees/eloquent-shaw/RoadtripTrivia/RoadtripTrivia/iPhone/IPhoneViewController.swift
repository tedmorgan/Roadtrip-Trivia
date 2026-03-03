import UIKit
import AVFoundation
import AuthenticationServices

/// iPhone companion screen. Handles auth, settings, and
/// displays "Connect to CarPlay to play" messaging.
/// Per PRD: all gameplay happens on CarPlay. iPhone is for setup and account management.
class IPhoneViewController: UIViewController {

    private let authService = AuthService.shared

    // MARK: - UI Elements

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.text = "Roadtrip Trivia"
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.text = "Connect to CarPlay to start playing!"
        label.font = .systemFont(ofSize: 17)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var signInButton: ASAuthorizationAppleIDButton = {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
        button.addTarget(self, action: #selector(handleSignInWithApple), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Email Login UI (Bug 10)

    private lazy var orLabel: UILabel = {
        let label = UILabel()
        label.text = "— or sign in with email —"
        label.font = .systemFont(ofSize: 14)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var emailField: UITextField = {
        let field = UITextField()
        field.placeholder = "Email"
        field.borderStyle = .roundedRect
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private lazy var passwordField: UITextField = {
        let field = UITextField()
        field.placeholder = "Password"
        field.borderStyle = .roundedRect
        field.isSecureTextEntry = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private lazy var emailSignInButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Sign In"
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(handleEmailSignIn), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var emailSignUpButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "Create Account"
        config.baseForegroundColor = .systemBlue
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(handleEmailSignUp), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var emailErrorLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .systemRed
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    // MARK: - Settings UI (Bug 12)

    private lazy var settingsHeader: UILabel = {
        let label = UILabel()
        label.text = "Settings"
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var difficultyLabel: UILabel = {
        let label = UILabel()
        label.text = "Default Difficulty"
        label.font = .systemFont(ofSize: 17)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var difficultySegment: UISegmentedControl = {
        let items = Difficulty.allCases.map { $0.rawValue }
        let control = UISegmentedControl(items: items)
        let saved = UserDefaults.standard.string(forKey: "defaultDifficulty") ?? "Tricky"
        let index = Difficulty.allCases.firstIndex(where: { $0.rawValue == saved }) ?? 1
        control.selectedSegmentIndex = index
        control.addTarget(self, action: #selector(difficultyChanged), for: .valueChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private lazy var accountButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = "Account Settings"
        config.image = UIImage(systemName: "person.circle")
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(showAccountSettings), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        print("[IPhoneViewController] viewDidLoad called")
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        updateAuthState()

        // Request location + microphone permissions upfront on iPhone
        LocationService.shared.requestAuthorization()
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        print("[IPhoneViewController] viewDidLoad complete")
    }

    // MARK: - Layout

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        sv.keyboardDismissMode = .interactive
        return sv
    }()

    private func setupUI() {
        // Auth section
        let authStack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, signInButton,
            orLabel, emailField, passwordField, emailErrorLabel,
            emailSignInButton, emailSignUpButton
        ])
        authStack.axis = .vertical
        authStack.spacing = 12
        authStack.alignment = .center
        authStack.translatesAutoresizingMaskIntoConstraints = false

        // Settings section — always visible (difficulty can be set without signing in)
        let difficultyRow = UIStackView(arrangedSubviews: [difficultyLabel, difficultySegment])
        difficultyRow.axis = .horizontal
        difficultyRow.spacing = 12
        difficultyRow.translatesAutoresizingMaskIntoConstraints = false

        let settingsStack = UIStackView(arrangedSubviews: [settingsHeader, difficultyRow, accountButton])
        settingsStack.axis = .vertical
        settingsStack.spacing = 16
        settingsStack.alignment = .center
        settingsStack.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = UIStackView(arrangedSubviews: [authStack, settingsStack])
        mainStack.axis = .vertical
        mainStack.spacing = 40
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Wrap in scroll view so content is accessible on all screen sizes
        view.addSubview(scrollView)
        scrollView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            mainStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 40),
            mainStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -40),
            mainStack.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            mainStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            mainStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),

            signInButton.widthAnchor.constraint(equalToConstant: 280),
            signInButton.heightAnchor.constraint(equalToConstant: 50),
            emailField.widthAnchor.constraint(equalToConstant: 280),
            passwordField.widthAnchor.constraint(equalToConstant: 280),
            emailSignInButton.widthAnchor.constraint(equalToConstant: 280),
        ])
    }

    private func updateAuthState() {
        let isAuth = authService.isAuthenticated
        // Hide auth elements when signed in
        signInButton.isHidden = isAuth
        orLabel.isHidden = isAuth
        emailField.isHidden = isAuth
        passwordField.isHidden = isAuth
        emailSignInButton.isHidden = isAuth
        emailSignUpButton.isHidden = isAuth
        emailErrorLabel.isHidden = true

        // Settings are always visible (difficulty can be set without signing in)
        settingsHeader.isHidden = false
        difficultyLabel.isHidden = false
        difficultySegment.isHidden = false
        // Only show account button when signed in
        accountButton.isHidden = !isAuth

        if isAuth {
            statusLabel.text = "You're signed in. Connect to CarPlay to start playing!"
        } else {
            statusLabel.text = "Sign in to save your progress, or just connect to CarPlay to play!"
        }
    }

    // MARK: - Sign in with Apple

    @objc private func handleSignInWithApple() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - Email Auth (Bug 10)

    @objc private func handleEmailSignIn() {
        guard let email = emailField.text, !email.isEmpty,
              let password = passwordField.text, !password.isEmpty else {
            showEmailError("Please enter both email and password")
            return
        }
        emailErrorLabel.isHidden = true
        authService.signInWithEmail(email: email, password: password) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.updateAuthState()
                } else {
                    self?.showEmailError(error ?? "Sign in failed")
                }
            }
        }
    }

    @objc private func handleEmailSignUp() {
        guard let email = emailField.text, !email.isEmpty,
              let password = passwordField.text, !password.isEmpty else {
            showEmailError("Please enter both email and password")
            return
        }
        guard (passwordField.text?.count ?? 0) >= 6 else {
            showEmailError("Password must be at least 6 characters")
            return
        }
        emailErrorLabel.isHidden = true
        authService.signUpWithEmail(email: email, password: password) { [weak self] success, error in
            DispatchQueue.main.async {
                if success {
                    self?.updateAuthState()
                } else {
                    self?.showEmailError(error ?? "Sign up failed")
                }
            }
        }
    }

    private func showEmailError(_ message: String) {
        emailErrorLabel.text = message
        emailErrorLabel.isHidden = false
    }

    // MARK: - Difficulty Setting (Bug 12)

    @objc private func difficultyChanged() {
        let index = difficultySegment.selectedSegmentIndex
        let difficulty = Difficulty.allCases[index]
        UserDefaults.standard.set(difficulty.rawValue, forKey: "defaultDifficulty")
        print("[Settings] Default difficulty set to \(difficulty.rawValue)")
    }

    // MARK: - Account Settings

    @objc private func showAccountSettings() {
        let alert = UIAlertController(title: "Account", message: nil, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: "Sign Out", style: .default) { [weak self] _ in
            self?.authService.signOut()
            self?.updateAuthState()
        })

        alert.addAction(UIAlertAction(title: "Delete Account", style: .destructive) { [weak self] _ in
            self?.confirmAccountDeletion()
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        present(alert, animated: true)
    }

    private func confirmAccountDeletion() {
        let confirm = UIAlertController(
            title: "Delete Account?",
            message: "This will permanently delete your account and all data. This cannot be undone.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.authService.deleteAccount { success in
                DispatchQueue.main.async {
                    self?.updateAuthState()
                }
            }
        })
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(confirm, animated: true)
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension IPhoneViewController: ASAuthorizationControllerDelegate {

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
        authService.signInWithApple(credential: credential) { [weak self] success in
            DispatchQueue.main.async {
                self?.updateAuthState()
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("[Auth] Sign in failed: \(error.localizedDescription)")
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension IPhoneViewController: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return view.window!
    }
}
