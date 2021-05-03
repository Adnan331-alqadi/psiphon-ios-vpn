/*
 * Copyright (c) 2021, Psiphon Inc.
 * All rights reserved.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

import Foundation
import WebKit
import PsiApi
import Utilities
import ReactiveSwift

final class WebViewController: ReactiveViewController {
    
    private struct ObservedState: Equatable {
        let webViewLoading: Pending<ErrorEvent<WebViewFailure>?>
        let tunnelStatus: TunnelProviderVPNStatus
        let lifeCycle: ViewControllerLifeCycle
    }
    
    private enum WebViewFailure: HashableError {
        case didFail(SystemError<Int>)
        case didFailProvisionalNavigation(SystemError<Int>)
        case httpError(ErrorMessage)
    }
    
    private let (lifetime, token) = Lifetime.make()
    private let tunnelProviderRefSignal: SignalProducer<TunnelConnection?, Never>
    
    private let baseURL: URL
    
    private let webView: WKWebView
    private var containerView: ViewBuilderContainerView<
        EitherView<PlaceholderView<WKWebView>, BlockerView>>!
    
    // Close button.
    private var closeButton: BlockerView.DisplayOption.ButtonOption!
    
    // State model
    @State private var webViewLoading: Pending<ErrorEvent<WebViewFailure>?> = .pending
    
    init(
        baseURL: URL,
        feedbackLogger: FeedbackLogger,
        tunnelStatusSignal: SignalProducer<TunnelProviderVPNStatus, Never>,
        tunnelProviderRefSignal: SignalProducer<TunnelConnection?, Never>,
        onDismissed: @escaping () -> Void
    ) {
        
        self.baseURL = baseURL
        self.tunnelProviderRefSignal = tunnelProviderRefSignal
        
        self.webView = WKWebView(frame: .zero)
        
        super.init(onDismissed: onDismissed)
        
        mutate(self.webView) {
            $0.uiDelegate = self
            $0.navigationDelegate = self
        }
        
        self.containerView = ViewBuilderContainerView(
            EitherView(
                PlaceholderView(),
                BlockerView()
            )
        )
        
        self.closeButton = BlockerView.DisplayOption.ButtonOption(
            title: UserStrings.Close_button_title(),
            handler: BlockerView.Handler { [unowned self] () -> Void in
                self.dismiss(animated: true, completion: nil)
            }
        )
        
        // Stops the webview from loading of all resources
        // if the tunnel status is not connected.
        // No-op if nothing is loading.
        self.lifetime += tunnelStatusSignal
            .skipRepeats()
            .startWithValues { [unowned self] tunnelProviderVPNStatus in
                
                guard case .connected = tunnelProviderVPNStatus.tunneled else {
                    self.webView.stopLoading()
                    return
                }
                
            }
        
        self.lifetime += SignalProducer.combineLatest(
            self.$webViewLoading.signalProducer,
            tunnelStatusSignal,
            self.$lifeCycle.signalProducer
        ).map(ObservedState.init)
        .skipRepeats()
        .filter { observed in
            observed.lifeCycle.viewDidLoadOrAppeared
        }
        .startWithValues { [unowned self] observed in
            
            if Debugging.mainThreadChecks {
                guard Thread.isMainThread else {
                    fatalError()
                }
            }
            
            // Even though the reactive signal has a filter on
            // `!observed.lifeCycle.viewWillOrDidDisappear`, due to async nature
            // of the signal it is ambiguous if this closure is called when
            // `self.lifeCycle.viewWillOrDidDisappear` is true.
            // Due to this race-condition, the source-of-truth (`self.lifeCycle`),
            // is checked for whether view will or did disappear.
            guard !self.lifeCycle.viewWillOrDidDisappear else {
                return
            }
            
            switch observed.tunnelStatus.tunneled {
            
            case .notConnected:
                
                self.containerView.bind(
                    .right(
                        BlockerView.DisplayOption(
                            animateSpinner: false,
                            buttonLabel: .labelAndButton(
                                labelText: UserStrings.Psiphon_is_not_connected(),
                                buttonOptions: [ self.closeButton ]))))
                
            case .connecting:
                
                self.containerView.bind(
                    .right(
                        BlockerView.DisplayOption(
                            animateSpinner: true,
                            buttonLabel: .labelAndButton(
                                labelText: UserStrings.Connecting_to_psiphon(),
                                buttonOptions: [ self.closeButton ]))))
                
            case .disconnecting:
                
                self.containerView.bind(
                    .right(
                        BlockerView.DisplayOption(
                            animateSpinner: false,
                            buttonLabel: .labelAndButton(
                                labelText: UserStrings.Psiphon_is_not_connected(),
                                buttonOptions: [self.closeButton] ))))
                
            case .connected:
                
                switch observed.webViewLoading {
                case .pending:

                    // Loading
                    feedbackLogger.immediate(.info, "loading")
                    
                    self.containerView.bind(
                        .right(
                            BlockerView.DisplayOption(
                                animateSpinner: true,
                                buttonLabel: .labelAndButton(
                                    labelText: UserStrings.Loading(),
                                    buttonOptions: [ self.closeButton ]))))
                    
                case .completed(.none):
                    
                    // Load is complete
                    feedbackLogger.immediate(.info, "load completed")
                    
                    self.containerView.bind(.left(self.webView))
                    
                case .completed(.some(let errorEvent)):
                    
                    // Load failed
                    feedbackLogger.immediate(.info, "load failed: \(errorEvent)")
                    
                    switch errorEvent.error {
                    
                    case .didFail(_), .didFailProvisionalNavigation(_):
                        
                        // Retries to load the baseURL again.
                        let retryButton = BlockerView.DisplayOption.ButtonOption(
                            title: UserStrings.Tap_to_retry(),
                            handler: BlockerView.Handler { [unowned self] () -> Void in
                                self.load(url: baseURL)
                            }
                        )
                        
                        self.containerView.bind(
                            .right(
                                .init(animateSpinner: false,
                                      buttonLabel: .labelAndButton(
                                        labelText: UserStrings.Loading_failed(),
                                        buttonOptions: [ retryButton, self.closeButton ]
                                      ))))
                        
                    case .httpError(_):
                        
                        let labelText = """
                            \(UserStrings.Loading_failed())\n\(UserStrings.Please_try_again_later())
                            """
                        
                        self.containerView.bind(
                            .right(
                                .init(animateSpinner: false,
                                      buttonLabel: .labelAndButton(
                                        labelText: labelText,
                                        buttonOptions: [ self.closeButton ]))))
                    }
                    
                }
                
            }
            
        }
        
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        if let navigationBar = navigationController?.navigationBar {
            
            mutate(navigationBar) {
                $0.barStyle = .default
                $0.titleTextAttributes = [ .font: AvenirFont.bold.customFont(FontSize.h3.rawValue) ]
            }
            
        }
        
        self.view.addSubview(self.containerView.view)
        
        // Setup Auto Layout
        self.containerView.view.activateConstraints {
            $0.matchParentConstraints()
        }
        
        // Starts loading of baseURL
        self.load(url: baseURL)
        
    }
    
    // Only use this function for loading or relading a url.
    // Do not directly call `self.webView`.
    // TODO: Abstract webview and it's state handling into a wrapper class.
    private func load(url: URL) {
        self.webViewLoading = .pending
        self.webView.load(URLRequest(url: url))
    }
    
}

extension WebViewController: WKUIDelegate {
    
    func webViewDidClose(_ webView: WKWebView) {
        self.dismiss(animated: true, completion: nil)
    }
    
}

extension WebViewController: WKNavigationDelegate {
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Tells the delegate that an error occurred during navigation.
        let systemError = SystemError<Int>.make(error as NSError)
        self.webViewLoading = .completed(ErrorEvent(.didFail(systemError), date: Date()))
    }
    
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        
        // This is always called after webView(_:decidePolicyFor:decisionHandler).
        // If no value has been set by webView(_:decidePolicyFor:decisionHandler),
        // then updates `self.webViewLoading` state value with the given error.
        if case .pending = self.webViewLoading {
            // Tells the delegate that an error occurred during the early navigation process.
            let systemError = SystemError<Int>.make(error as NSError)
            self.webViewLoading = .completed(ErrorEvent(.didFailProvisionalNavigation(systemError),
                                                        date: Date()))
        }
        
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Tells the delegate that navigation is complete.
        self.webViewLoading = .completed(.none)
    }
    
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        
        // Asks the delegate for permission to navigate to new content
        // after the response to the navigation request is known.
        
        let httpStatus =
            HTTPStatusCode(rawValue: (navigationResponse.response as! HTTPURLResponse).statusCode)!
        
        // If recieved client or server http status error code,
        // cancels navigation, and updates `self.webViewLoading`.
        // The webview is expected to be blocked with an error message at this point.
        switch httpStatus.responseType {
        case .clientError, .serverError:
            let message = ErrorMessage("received HTTP status \(httpStatus.rawValue)")
            self.webViewLoading = .completed(ErrorEvent(.httpError(message), date: Date()))
            decisionHandler(.cancel)
            
        default:
            decisionHandler(.allow)
        }
        
    }
    
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        
        // If delegate object implements the
        // webView(_:decidePolicyFor:preferences:decisionHandler:) method,
        // the web view doesn’t call this method.
        
        // Navigation action is allowed only if the tunnel is connected.
        
        tunnelProviderRefSignal
            .take(first: 1)
            .startWithValues { tunnelConnection in
                
                switch tunnelConnection?.tunneled {
                case .connected:
                    decisionHandler(.allow)
                default:
                    decisionHandler(.cancel)
                }
                
            }
        
    }
    
}