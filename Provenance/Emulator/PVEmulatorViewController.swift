//  Converted to Swift 4 by Swiftify v4.1.6640 - https://objectivec2swift.com/
//
//  PVEmulatorViewController.swift
//  Provenance
//
//  Created by James Addyman on 14/08/2013.
//  Copyright (c) 2013 James Addyman. All rights reserved.
//

import PVLibrary
import PVSupport
import QuartzCore
import RealmSwift
import UIKit

private weak var staticSelf: PVEmulatorViewController?

func uncaughtExceptionHandler(exception _: NSException?) {
    if let staticSelf = staticSelf, staticSelf.core.supportsSaveStates {
        staticSelf.autoSaveState { result in
            switch result {
            case .success:
                break
            case let .error(error):
                ELOG(error.localizedDescription)
            }
        }
    }
}

#if os(tvOS)
    typealias PVEmulatorViewControllerRootClass = GCEventViewController
#else
    typealias PVEmulatorViewControllerRootClass = UIViewController
#endif

class MenuButton: UIButton, HitAreaEnlarger {
    var hitAreaInset: UIEdgeInsets = UIEdgeInsets(top: -5, left: -5, bottom: -5, right: -5)
}

extension UIViewController {
    func presentMessage(_ message: String, title: String, completion _: (() -> Swift.Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

        let presentingVC = presentedViewController ?? self

        if presentingVC.isBeingDismissed || presentingVC.isBeingPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                presentingVC.present(alert, animated: true, completion: nil)
            }
        } else {
            presentingVC.present(alert, animated: true, completion: nil)
        }
    }

    func presentError(_ message: String, completion: (() -> Swift.Void)? = nil) {
        ELOG("\(message)")
        presentMessage(message, title: "Error", completion: completion)
    }

    func presentWarning(_ message: String, completion: (() -> Swift.Void)? = nil) {
        WLOG("\(message)")
        presentMessage(message, title: "Warning", completion: completion)
    }
}

final class PVEmulatorViewController: PVEmulatorViewControllerRootClass, PVAudioDelegate, PVSaveStatesViewControllerDelegate {
    let core: PVEmulatorCore
    let game: PVGame

    var batterySavesPath: URL { return PVEmulatorConfiguration.batterySavesPath(forGame: game) }
    var BIOSPath: URL { return PVEmulatorConfiguration.biosPath(forGame: game) }
    var menuButton: MenuButton?

    private(set) lazy var glViewController: PVGLViewController = PVGLViewController(emulatorCore: core)
    private(set) lazy var controllerViewController: (UIViewController & StartSelectDelegate)? = PVCoreFactory.controllerViewController(forSystem: game.system, core: core)

    var audioInited: Bool = false
    private(set) lazy var gameAudio: OEGameAudio = {
        audioInited = true
        return OEGameAudio(core: core)
    }()

    var fpsTimer: Timer?
    let fpsLabel: UILabel = UILabel()
    var secondaryScreen: UIScreen?
    var secondaryWindow: UIWindow?
    var menuGestureRecognizer: UITapGestureRecognizer?

    var isShowingMenu: Bool = false {
        willSet {
            if newValue == true {
                glViewController.isPaused = true
            }
        }
        didSet {
            if isShowingMenu == false {
                glViewController.isPaused = false
            }
        }
    }

    let minimumPlayTimeToMakeAutosave: Double = 60

    required init(game: PVGame, core: PVEmulatorCore) {
        self.core = core
        self.game = game

        super.init(nibName: nil, bundle: nil)

        staticSelf = self

        if PVSettingsModel.shared.autoSave {
            NSSetUncaughtExceptionHandler(uncaughtExceptionHandler)
        } else {
            NSSetUncaughtExceptionHandler(nil)
        }

        // Add KVO watcher for isRunning state so we can update play time
        core.addObserver(self, forKeyPath: "isRunning", options: .new, context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of _: Any?, change _: [NSKeyValueChangeKey: Any]?, context _: UnsafeMutableRawPointer?) {
        if keyPath == "isRunning" {
            #if os(tvOS)
            PVControllerManager.shared.setSteamControllersMode(core.isRunning ? .gameController : .keyboardAndMouse)
            #endif
            if core.isRunning {
                if gameStartTime != nil {
                    ELOG("Didn't expect to get a KVO update of isRunning to true while we still have an unflushed gameStartTime variable")
                }
                gameStartTime = Date()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.updatePlayedDuration()
                }
            }
        }
    }

    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // These need to be first or mutli-threaded cores can cause crashes on close
        NotificationCenter.default.removeObserver(self)
        core.removeObserver(self, forKeyPath: "isRunning")

        core.stopEmulation()
        // Leave emulation loop first
        if audioInited {
            gameAudio.stop()
        }
        NSSetUncaughtExceptionHandler(nil)
        staticSelf = nil
        glViewController.willMove(toParent: nil)
        glViewController.view?.removeFromSuperview()
        glViewController.removeFromParent()
        #if os(iOS)
            GCController.controllers().forEach { $0.controllerPausedHandler = nil }
        #endif
        updatePlayedDuration()
        destroyAutosaveTimer()

        if let menuGestureRecognizer = menuGestureRecognizer {
            view.removeGestureRecognizer(menuGestureRecognizer)
        }
    }

    private func initNotifcationObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.appWillEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.appDidEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.appWillResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.appDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.controllerDidConnect(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.controllerDidDisconnect(_:)), name: .GCControllerDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.screenDidConnect(_:)), name: UIScreen.didConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.screenDidDisconnect(_:)), name: UIScreen.didDisconnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PVEmulatorViewController.handleControllerManagerControllerReassigned(_:)), name: .PVControllerManagerControllerReassigned, object: nil)
    }

    private func initCore() {
        core.audioDelegate = self
        core.saveStatesPath = saveStatePath.path
        core.batterySavesPath = batterySavesPath.path
        core.biosPath = BIOSPath.path
        core.controller1 = PVControllerManager.shared.player1
        core.controller2 = PVControllerManager.shared.player2
        core.controller3 = PVControllerManager.shared.player3
        core.controller4 = PVControllerManager.shared.player4

        let md5Hash: String = game.md5Hash
        core.romMD5 = md5Hash
        core.romSerial = game.romSerial
    }

    private func addControllerOverlay() {
        if let aController = controllerViewController {
            addChild(aController)
        }
        if let aView = controllerViewController?.view {
            view.addSubview(aView)
        }
        controllerViewController?.didMove(toParent: self)
    }

    private func initMenuButton() {
        let alpha: CGFloat = CGFloat(PVSettingsModel.shared.controllerOpacity)
        menuButton = MenuButton(type: .custom)
        menuButton?.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
        menuButton?.setImage(UIImage(named: "button-menu"), for: .normal)
        menuButton?.setImage(UIImage(named: "button-menu-pressed"), for: .highlighted)
        // Commenting out title label for now (menu has changed to graphic only)
        // [self.menuButton setTitle:@"Menu" forState:UIControlStateNormal];
        // menuButton?.titleLabel?.font = UIFont.systemFont(ofSize: 12)
        // menuButton?.setTitleColor(UIColor.white, for: .normal)
        menuButton?.layer.shadowOffset = CGSize(width: 0, height: 1)
        menuButton?.layer.shadowRadius = 3.0
        menuButton?.layer.shadowColor = UIColor.black.cgColor
        menuButton?.layer.shadowOpacity = 0.75
        menuButton?.tintColor = UIColor.white
        menuButton?.alpha = alpha
        menuButton?.addTarget(self, action: #selector(PVEmulatorViewController.showMenu(_:)), for: .touchUpInside)
        view.addSubview(menuButton!)
    }

    private func initFPSLabel() {
        fpsLabel.textColor = UIColor.yellow
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsLabel.textAlignment = .right
        fpsLabel.isOpaque = true
        #if os(tvOS)
            fpsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        #else
            fpsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        #endif
        glViewController.view.addSubview(fpsLabel)
        view.addConstraint(NSLayoutConstraint(item: fpsLabel, attribute: .top, relatedBy: .equal, toItem: glViewController.view, attribute: .top, multiplier: 1.0, constant: 30))
        view.addConstraint(NSLayoutConstraint(item: fpsLabel, attribute: .right, relatedBy: .equal, toItem: glViewController.view, attribute: .right, multiplier: 1.0, constant: -40))

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true, block: { [weak self] (_: Timer) -> Void in
            guard let `self` = self else { return }

            let coreSpeed = self.core.renderFPS/self.core.frameInterval * 100
            let drawTime =  self.glViewController.timeSinceLastDraw * 1000
            let fps = 1000 / drawTime
            self.fpsLabel.text = String( format: "Core speed %03.02f%% - Draw time %02.02f%ms - FPS %03.02f%", coreSpeed, drawTime, fps)
        })
    }

    // TODO: This method is way too big, break it up
    override func viewDidLoad() {
        super.viewDidLoad()
        title = game.title
        view.backgroundColor = UIColor.black

        initNotifcationObservers()
        initCore()

        // Load now. Moved here becauase Mednafen needed to know what kind of game it's working with in order
        // to provide the correct data for creating views.
        let m3uFile: URL? = PVEmulatorConfiguration.m3uFile(forGame: game)
        let romPathMaybe: URL? = m3uFile ?? game.file.url

        guard let romPath = romPathMaybe else {
            presentingViewController?.presentError("Game has a nil rom path.")
            return
        }

        //		guard FileManager.default.fileExists(atPath: romPath.absoluteString) else {
        //			ELOG("File doesn't exist at path \(romPath.absoluteString)")
        //			presentingViewController?.presentError("File doesn't exist at path \(romPath.absoluteString)")
        //			return
        //		}

        do {
            try core.loadFile(atPath: romPath.path)
        } catch {
            let alert = UIAlertController(title: error.localizedDescription, message: (error as NSError).localizedRecoverySuggestion, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { (_: UIAlertAction) -> Void in
                self.dismiss(animated: true, completion: nil)
            }))
            let code = (error as NSError).code
            if code == PVEmulatorCoreErrorCode.missingM3U.rawValue {
                alert.addAction(UIAlertAction(title: "View Wiki", style: .cancel, handler: { (_: UIAlertAction) -> Void in
                    if let url = URL(string: "https://bitly.com/provm3u") {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: { [weak self] in
                self?.present(alert, animated: true) { () -> Void in }
            })

            return
        }

        if UIScreen.screens.count > 1 {
            secondaryScreen = UIScreen.screens[1]
            if let aBounds = secondaryScreen?.bounds {
                secondaryWindow = UIWindow(frame: aBounds)
            }
            if let aScreen = secondaryScreen {
                secondaryWindow?.screen = aScreen
            }
            secondaryWindow?.rootViewController = glViewController
            glViewController.view?.frame = secondaryWindow?.bounds ?? .zero
            if let aView = glViewController.view {
                secondaryWindow?.addSubview(aView)
            }
            secondaryWindow?.isHidden = false
        } else {
            addChild(glViewController)
            if let aView = glViewController.view {
                view.addSubview(aView)
            }
            glViewController.didMove(toParent: self)
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
            addControllerOverlay()
            initMenuButton()
        #endif

        if PVSettingsModel.shared.showFPSCount {
            initFPSLabel()
        }

        #if !targetEnvironment(simulator)
            if !GCController.controllers().isEmpty {
                menuButton?.isHidden = true
            }
        #endif

        convertOldSaveStatesToNewIfNeeded()

        core.startEmulation()

        gameAudio.volume = PVSettingsModel.shared.volume
        gameAudio.outputDeviceID = 0
        gameAudio.start()
        #if os(tvOS)
        // On tvOS the siri-remotes menu-button will default to go back in the hierachy (thus dismissing the emulator), we don't want that behaviour
        // (we'd rather pause the game), so we just install a tap-recognizer here (that doesn't do anything), and add our own logic in `setupPauseHandler`
        if menuGestureRecognizer == nil {
            menuGestureRecognizer = UITapGestureRecognizer()
            menuGestureRecognizer?.allowedPressTypes = [.menu]
            view.addGestureRecognizer(menuGestureRecognizer!)
        }
        #endif
        GCController.controllers().forEach {
			$0.setupPauseHandler(onPause: { [weak self] in
				guard let self = self else { return }
				self.controllerPauseButtonPressed()
			})
		}
    }

    public override func viewDidAppear(_: Bool) {
        super.viewDidAppear(true)
        // Notifies UIKit that your view controller updated its preference regarding the visual indicator

        #if os(iOS)
            setNeedsUpdateOfHomeIndicatorAutoHidden()

            // Ignore Smart Invert
            view.ignoresInvertColors = true
        #endif

        if PVSettingsModel.shared.timedAutoSaves {
            createAutosaveTimer()
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        destroyAutosaveTimer()
    }

    var autosaveTimer: Timer?

    var gameStartTime: Date?
    @objc
    public func updatePlayedDuration() {
        defer {
            // Clear any temp pointer to start time
            self.gameStartTime = nil
        }
        guard let gameStartTime = gameStartTime else {
            return
        }

        // Calcuate what the new total spent time should be
        let duration = gameStartTime.timeIntervalSinceNow * -1
        let totalTimeSpent = game.timeSpentInGame + Int(duration)
        ILOG("Played for duration \(duration). New total play time: \(totalTimeSpent) for \(game.title)")
        // Write that to the database
        do {
            try RomDatabase.sharedInstance.writeTransaction {
                game.timeSpentInGame = totalTimeSpent
            }
        } catch {
            presentError("\(error.localizedDescription)")
        }
    }

    @objc public func updateLastPlayedTime() {
        ILOG("Updating last played")
        do {
            try RomDatabase.sharedInstance.writeTransaction {
                game.lastPlayed = Date()
            }
        } catch {
            presentError("\(error.localizedDescription)")
        }
    }

    #if os(iOS) && !targetEnvironment(simulator)
        // Check Controller Manager if it has a Controller connected and thus if Home Indicator should hide…
        override var prefersHomeIndicatorAutoHidden: Bool {
            let shouldHideHomeIndicator: Bool = PVControllerManager.shared.hasControllers
            return shouldHideHomeIndicator
        }
    #endif

    #if os(iOS)
        var safeAreaInsets: UIEdgeInsets {
            if #available(iOS 11.0, tvOS 11.0, *) {
                return view.safeAreaInsets
            } else {
                return UIEdgeInsets.zero
            }
        }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if os(iOS)
            layoutMenuButton()
        #endif
    }

    #if os(iOS)
        func layoutMenuButton() {
            if let menuButton = self.menuButton {
                let height: CGFloat = 42
                let width: CGFloat = 42
                menuButton.imageView?.contentMode = .center
                let frame = CGRect(x: safeAreaInsets.left + 10, y: safeAreaInsets.top + 5, width: width, height: height)
                menuButton.frame = frame
            }
        }
    #endif
    func documentsPath() -> String? {
        #if os(tvOS)
            let paths = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        #else
            let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        #endif
        let documentsDirectoryPath: String = paths[0]
        return documentsDirectoryPath
    }

    #if os(iOS)
        override var prefersStatusBarHidden: Bool {
            return true
        }

        override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
            return .bottom
        }

        override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            return .all
        }
    #endif

    @objc func appWillEnterForeground(_: Notification?) {
        updateLastPlayedTime()
    }

    @objc func appDidEnterBackground(_: Notification?) {}

    @objc func appWillResignActive(_: Notification?) {
        if PVSettingsModel.shared.autoSave, core.supportsSaveStates {
            autoSaveState { result in
                switch result {
                case .success:
                    break
                case let .error(error):
                    ELOG("Auto-save failed \(error.localizedDescription)")
                }
            }
        }
        gameAudio.pause()
        showMenu(self)
    }

    @objc func appDidBecomeActive(_: Notification?) {
        if !isShowingMenu {
            core.setPauseEmulation(false)
        }
        core.setPauseEmulation(true)
        gameAudio.start()
    }

    func enableControllerInput(_ enabled: Bool) {
        #if os(tvOS)
            controllerUserInteractionEnabled = enabled
        #else
            // Can enable when we change to iOS 10 base
            // and change super class to GCEventViewController
            //    if (@available(iOS 10, *)) {
            //        self.controllerUserInteractionEnabled = enabled;
            //    }
        #endif
    }

    @objc func hideMoreInfo() {
        dismiss(animated: true, completion: { () -> Void in
            #if os(tvOS)
                self.showMenu(nil)
            #else
                self.hideMenu()
            #endif
        })
    }

    func hideMenu() {
        enableControllerInput(false)
        if presentedViewController is UIAlertController {
            dismiss(animated: true) { () -> Void in }
            isShowingMenu = false
        }
        updateLastPlayedTime()
        core.setPauseEmulation(false)
    }

    @objc func updateFPSLabel() {
        #if DEBUG
            print("FPS: \(glViewController.framesPerSecond)")
        #endif
        fpsLabel.text = String(format: "%2.02f", core.emulationFPS)
    }

    func captureScreenshot() -> UIImage? {
        fpsLabel.alpha = 0.0
        let width: CGFloat? = glViewController.view.frame.size.width
        let height: CGFloat? = glViewController.view.frame.size.height
        let size = CGSize(width: width ?? 0.0, height: height ?? 0.0)
        UIGraphicsBeginImageContextWithOptions(size, false, UIScreen.main.scale)
        let rec = CGRect(x: 0, y: 0, width: width ?? 0.0, height: height ?? 0.0)
        glViewController.view.drawHierarchy(in: rec, afterScreenUpdates: true)
        let image: UIImage? = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        fpsLabel.alpha = 1.0
        return image
    }

    #if os(iOS)
        @objc func takeScreenshot() {
            if let screenshot = captureScreenshot() {
                DispatchQueue.global(qos: .default).async(execute: { () -> Void in
                    UIImageWriteToSavedPhotosAlbum(screenshot, nil, nil, nil)
                })

                if let pngData = screenshot.pngData() {
                    let dateString = PVEmulatorConfiguration.string(fromDate: Date())

                    let fileName = game.title + " - " + dateString + ".png"
                    let imageURL = PVEmulatorConfiguration.screenshotsPath(forGame: game).appendingPathComponent(fileName, isDirectory: false)
                    do {
                        try pngData.write(to: imageURL)
                        try RomDatabase.sharedInstance.writeTransaction {
                            let newFile = PVImageFile(withURL: imageURL, relativeRoot: .iCloud)
                            game.screenShots.append(newFile)
                        }
                    } catch {
                        presentError("Unable to write image to disk, error: \(error.localizedDescription)")
                    }
                }
            }
            core.setPauseEmulation(false)
            isShowingMenu = false
        }

    #endif
    @objc func showSpeedMenu() {
        let actionSheet = UIAlertController(title: "Game Speed", message: nil, preferredStyle: .actionSheet)
        if traitCollection.userInterfaceIdiom == .pad, let menuButton = menuButton {
            actionSheet.popoverPresentationController?.sourceView = menuButton
            actionSheet.popoverPresentationController?.sourceRect = menuButton.bounds
        }
        let speeds = ["Slow", "Normal", "Fast"]
        speeds.enumerated().forEach { idx, title in
            let action = UIAlertAction(title: title, style: .default, handler: { (_: UIAlertAction) -> Void in
                self.core.gameSpeed = GameSpeed(rawValue: idx) ?? .normal
                self.core.setPauseEmulation(false)
                self.isShowingMenu = false
                self.enableControllerInput(false)
            })
            actionSheet.addAction(action)
            if idx == self.core.gameSpeed.rawValue {
                actionSheet.preferredAction = action
            }
        }
        present(actionSheet, animated: true, completion: { () -> Void in
            PVControllerManager.shared.iCadeController?.refreshListener()
        })
    }

    func showMoreInfo() {
        guard let moreInfoViewController = UIStoryboard(name: "Provenance", bundle: nil).instantiateViewController(withIdentifier: "gameMoreInfoVC") as? PVGameMoreInfoViewController else { return }
        moreInfoViewController.game = self.game
        moreInfoViewController.showsPlayButton = false

        #if os(iOS)
        moreInfoViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.hideMoreInfo))
        #endif

        let newNav = UINavigationController(rootViewController: moreInfoViewController)
        self.present(newNav, animated: true) { () -> Void in }
        self.isShowingMenu = false
        self.enableControllerInput(false)
    }

    typealias QuitCompletion = () -> Void

    func quit(optionallySave canSave: Bool = true, completion: QuitCompletion? = nil) {
		enableControllerInput(false)

        if canSave, PVSettingsModel.shared.autoSave, core.supportsSaveStates {
            autoSaveState { result in
                switch result {
                case .success:
                    break
                case let .error(error):
                    ELOG("Auto-save failed \(error.localizedDescription)")
                }
            }
        }

        core.stopEmulation()

		// Leave emulation loop first
        fpsTimer?.invalidate()
        fpsTimer = nil
        gameAudio.stop()

		self.willMove(toParent: nil)
		dismiss(animated: true, completion: completion)
		self.view?.removeFromSuperview()
		self.removeFromParent()

        updatePlayedDuration()
		staticSelf = nil
    }
}

// MARK: - PVAudioDelegate

extension PVEmulatorViewController {
    func audioSampleRateDidChange() {
        gameAudio.stop()
        gameAudio.start()
    }
}

// MARK: - Controllers

extension PVEmulatorViewController {
    func controllerPauseButtonPressed() {
        DispatchQueue.main.async(execute: { () -> Void in
            if !self.isShowingMenu {
                self.showMenu(self)
            } else {
                self.hideMenu()
            }
        })
    }

    @objc func controllerDidConnect(_ note: Notification?) {
        let controller = note?.object as? GCController
        // 8Bitdo controllers don't have a pause button, so don't hide the menu
        if !(controller is PViCade8BitdoController || controller is PViCade8BitdoZeroController) {
            menuButton?.isHidden = true
            // In instances where the controller is connected *after* the VC has been shown, we need to set the pause handler
            controller?.setupPauseHandler(onPause: controllerPauseButtonPressed)
            #if os(iOS)
                setNeedsUpdateOfHomeIndicatorAutoHidden()
            #endif
        }
    }

    @objc func controllerDidDisconnect(_: Notification?) {
        menuButton?.isHidden = false
        #if os(iOS)
            setNeedsUpdateOfHomeIndicatorAutoHidden()
        #endif
    }

    @objc func handleControllerManagerControllerReassigned(_: Notification?) {
        core.controller1 = PVControllerManager.shared.player1
        core.controller2 = PVControllerManager.shared.player2
        core.controller3 = PVControllerManager.shared.player3
        core.controller4 = PVControllerManager.shared.player4
        #if os(tvOS)
        PVControllerManager.shared.setSteamControllersMode(core.isRunning ? .gameController : .keyboardAndMouse)
        #endif
    }

    // MARK: - UIScreenNotifications

    @objc func screenDidConnect(_ note: Notification?) {
        ILOG("Screen did connect: \(note?.object ?? "")")
        if secondaryScreen == nil {
            secondaryScreen = UIScreen.screens[1]
            if let aBounds = secondaryScreen?.bounds {
                secondaryWindow = UIWindow(frame: aBounds)
            }
            if let aScreen = secondaryScreen {
                secondaryWindow?.screen = aScreen
            }
            glViewController.view?.removeFromSuperview()
            glViewController.removeFromParent()
            secondaryWindow?.rootViewController = glViewController
            glViewController.view?.frame = secondaryWindow?.bounds ?? .zero
            if let aView = glViewController.view {
                secondaryWindow?.addSubview(aView)
            }
            secondaryWindow?.isHidden = false
            glViewController.view?.setNeedsLayout()
        }
    }

    @objc func screenDidDisconnect(_ note: Notification?) {
        ILOG("Screen did disconnect: \(note?.object ?? "")")
        let screen = note?.object as? UIScreen
        if secondaryScreen == screen {
            glViewController.view?.removeFromSuperview()
            glViewController.removeFromParent()
            addChild(glViewController)

            if let aView = glViewController.view, let aView1 = controllerViewController?.view {
                view.insertSubview(aView, belowSubview: aView1)
            }

            glViewController.view?.setNeedsLayout()
            secondaryWindow = nil
            secondaryScreen = nil
        }
    }
}

extension PVEmulatorViewController {
    func showSwapDiscsMenu() {
        guard let core = self.core as? (PVEmulatorCore & DiscSwappable) else {
            presentError("Internal error: No core found.")
            isShowingMenu = false
            enableControllerInput(false)
            return
        }

        let numberOfDiscs = core.numberOfDiscs
        guard numberOfDiscs > 1 else {
            presentError("Game only supports 1 disc.")
            core.setPauseEmulation(false)
            isShowingMenu = false
            enableControllerInput(false)
            return
        }

        // Add action for each disc
        let actionSheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

        for index in 1 ... numberOfDiscs {
            actionSheet.addAction(UIAlertAction(title: "\(index)", style: .default, handler: { [unowned self] _ in

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: {
                    core.swapDisc(number: index)
                })

                core.setPauseEmulation(false)
                self.isShowingMenu = false
                self.enableControllerInput(false)
            }))
        }

        // Add cancel action
        actionSheet.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [unowned self] _ in
            core.setPauseEmulation(false)
            self.isShowingMenu = false
            self.enableControllerInput(false)
        }))

        // Present
        if traitCollection.userInterfaceIdiom == .pad {
            actionSheet.popoverPresentationController?.sourceView = menuButton
            actionSheet.popoverPresentationController?.sourceRect = menuButton?.bounds ?? .zero
        }

        present(actionSheet, animated: true) {
            PVControllerManager.shared.iCadeController?.refreshListener()
        }
    }
}

extension PVEmulatorViewController {
    func showCoreOptions() {
        let optionsVC = CoreOptionsViewController(withCore: type(of: core) as! CoreOptional.Type)
        let nav = UINavigationController(rootViewController: optionsVC)
        optionsVC.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissNav))
        present(nav, animated: true, completion: nil)
    }

    @objc
    func dismissNav() {
        presentedViewController?.dismiss(animated: true, completion: nil)
        core.setPauseEmulation(false)
        isShowingMenu = false
        enableControllerInput(false)
    }
}

// Extension to make gesture.allowedPressTypes and gesture.allowedTouchTypes sane.
extension NSNumber {
    static var menu: NSNumber {
        return NSNumber(pressType: .menu)
    }

    static var playPause: NSNumber {
        return NSNumber(pressType: .playPause)
    }

    static var select: NSNumber {
        return NSNumber(pressType: .select)
    }

    static var upArrow: NSNumber {
        return NSNumber(pressType: .upArrow)
    }

    static var downArrow: NSNumber {
        return NSNumber(pressType: .downArrow)
    }

    static var leftArrow: NSNumber {
        return NSNumber(pressType: .leftArrow)
    }

    static var rightArrow: NSNumber {
        return NSNumber(pressType: .rightArrow)
    }

    // MARK: - Private

    private convenience init(pressType: UIPress.PressType) {
        self.init(integerLiteral: pressType.rawValue)
    }
}

extension NSNumber {
    static var direct: NSNumber {
        return NSNumber(touchType: .direct)
    }

    static var indirect: NSNumber {
        return NSNumber(touchType: .indirect)
    }

    // MARK: - Private

    private convenience init(touchType: UITouch.TouchType) {
        self.init(integerLiteral: touchType.rawValue)
    }
}

extension GCController {
    func setupPauseHandler(onPause: @escaping () -> Void) {
        // Using buttonMenu is the recommended way for iOS/tvOS13 and later
        if let buttonMenu = buttonMenu {
            buttonMenu.pressedChangedHandler = { _, _, isPressed in
                if isPressed {
                    onPause()
                }
            }
        } else {
            // Fallback to the old method
            controllerPausedHandler = { _ in onPause()
			}
        }
    }

    private var buttonMenu: GCControllerButtonInput? {
        if #available(iOS 13.0, tvOS 13.0, *) {
            if let microGamepad = microGamepad {
                return microGamepad.buttonMenu
            } else if let extendedGamepad = extendedGamepad {
                return extendedGamepad.buttonMenu
            }
        }
        return nil
    }
}
