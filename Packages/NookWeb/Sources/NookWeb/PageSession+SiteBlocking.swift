// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+SiteBlocking.swift
//  NookWeb
//
//  Where the site blocker meets a page: the policy decision of every navigation in every frame,
//  and an address a page changes by itself without loading. Tabs, popups, Peek, split panes,
//  mini windows, private windows and background reader pages are all PageSessions, so this is
//  the one place they pass through. A blocked main-frame address shows the error page with no
//  way past it; the page under it, if any, stays where it was.
//

import Foundation
import NookBlocker
import WebKit

extension PageLoadError {
    /// The page shown in place of a site the blocker stopped.
    init(blocked url: URL, by verdict: SiteBlockVerdict) {
        self.url = url
        kind = .blocked
        message = verdict.pageMessage
    }
}

extension PageSession {
    /// Site blocking's say on a navigation. True when it took the decision: the address is
    /// blocked, or it is a search that was restarted with the engine's strict filter on.
    func siteBlockingDecides(
        _ navigationAction: WKNavigationAction, in webView: WKWebView,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) -> Bool {
        guard let url = navigationAction.request.url else { return false }
        let blocker = SiteBlocker.shared

        if let verdict = blocker.verdict(for: url) {
            decisionHandler(.cancel)
            // No target frame is a link that wanted a new tab or window: nothing opens, and the
            // page that asked says why. A blocked subframe is just left out of its page.
            if navigationAction.targetFrame?.isMainFrame != false {
                showSiteBlocked(url, verdict, in: webView)
            }
            return true
        }

        // Past three rewrites the server is redirecting the filter away again; let it load
        // rather than loop. Back and Forward keep their place in history.
        if navigationAction.targetFrame?.isMainFrame == true, navigationRewrites < 3,
           navigationAction.navigationType != .backForward,
           (navigationAction.request.httpMethod ?? "GET") == "GET",
           let filtered = blocker.safeSearchURL(for: url)
        {
            navigationRewrites += 1
            decisionHandler(.cancel)
            let nookBegan = nookBeganNavigation
            webView.load(URLRequest(url: filtered))
            nookBeganNavigation = nookBegan
            return true
        }
        return false
    }

    /// Puts the blocked page up. WebKit reports nothing for a navigation cancelled before it
    /// started, so this also does what a failed load would: the loading state ends and the
    /// address goes back to the page still showing underneath.
    private func showSiteBlocked(_ url: URL, _ verdict: SiteBlockVerdict, in webView: WKWebView) {
        let blocked = PageLoadError(blocked: url, by: verdict)
        loadError = blocked
        nookBeganNavigation = false
        if loadingState.isLoading { loadingState = .didFailProvisionalNavigation(URLError(.cancelled)) }
        // Until the cancel has gone through, the view still gives the blocked address as its own.
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, let webView, self.loadError == blocked, !webView.isLoading else { return }
            if let committed = webView.url, committed != self.url, SiteBlocker.shared.verdict(for: committed) == nil {
                self.url = committed
                self.controller?.tabEvents?.tabPropertiesChanged(self, properties: [.URL])
                self.controller?.pageCommitted(itemID: self.itemID, url: committed)
            }
            self.updateNavigationStateEnhanced(source: "siteBlocked")
        }
    }

    /// A page that changed its own address with the History API never asks for a policy
    /// decision; YouTube opens a Short this way. True when the change was to a blocked address,
    /// which is undone, or to an unfiltered search, which is reloaded filtered.
    func siteBlockingTakesBackAddressChange(to url: URL, in webView: WKWebView) -> Bool {
        let blocker = SiteBlocker.shared
        let view = ObjectIdentifier(webView)
        if let verdict = blocker.verdict(for: url) {
            loadError = PageLoadError(blocked: url, by: verdict)
            // WebKit and the page's own observer both report one change; it is undone once.
            guard blocker.isFirstReport(of: url, in: view, within: 2) else { return true }
            let previous = self.url
            if webView.backForwardList.backItem?.url == previous {
                webView.goBack()
            } else if previous != url, blocker.verdict(for: previous) == nil {
                // The page replaced its history entry, so there is nothing to go back to.
                webView.load(URLRequest(url: previous))
            }
            return true
        }
        // Not twice in a row: a site that strips the parameter again after loading would
        // otherwise reload forever.
        if let filtered = blocker.safeSearchURL(for: url), blocker.isFirstReport(of: filtered, in: view, within: 10) {
            webView.load(URLRequest(url: filtered))
            return true
        }
        return false
    }
}

/// For the few web views that are not a PageSession's: an extension's options page and its
/// popup window, which have no navigation delegate of their own. It refuses blocked addresses
/// and allows the rest; there is no blocked page to show in those windows.
@MainActor
public final class SiteBlockingNavigationGuard: NSObject, WKNavigationDelegate {
    public static let shared = SiteBlockingNavigationGuard()

    public func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url, SiteBlocker.shared.verdict(for: url) != nil {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
