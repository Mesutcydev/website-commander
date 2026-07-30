import Foundation
import WebKit

// MARK: - Inspector data types

struct ConsoleLog: Identifiable {
    let id = UUID()
    let level: Level
    let text: String
    let timestamp: Date

    enum Level: String {
        case log, info, warn, error

        var icon: String {
            switch self {
            case .log: return "chevron.right"
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }
}

struct NetworkRequest: Identifiable {
    let id = UUID()
    let method: String
    let url: String
    var status: Int?
    var durationMs: Int?
    var sizeBytes: Int?
    let timestamp: Date

    var host: String { URL(string: url)?.host ?? url }
    var path: String { URL(string: url)?.path ?? url }
}

struct PerformanceMetrics: Equatable {
    var loadTimeMs: Int?
    var domReadyMs: Int?
    var transferKB: Int?
}

struct InspectedElement: Equatable {
    var tag: String
    var elementID: String
    var classes: String
    var selector: String
    var xpath: String
    var styles: String
}

// MARK: - Inspector model

/// Collects console, network, performance, and element-inspection data streamed
/// from the preview web view.
@MainActor
final class WebInspectorModel: ObservableObject {
    @Published var consoleLogs: [ConsoleLog] = []
    @Published var networkRequests: [NetworkRequest] = []
    @Published var performance = PerformanceMetrics()
    @Published var inspectedElement: InspectedElement?
    @Published var inspectMode = false
    @Published var consoleFilter: ConsoleFilter = .all

    enum ConsoleFilter: String, CaseIterable, Identifiable {
        case all = "All", logs = "Logs", warnings = "Warnings", errors = "Errors"
        var id: String { rawValue }
    }

    var filteredLogs: [ConsoleLog] {
        switch consoleFilter {
        case .all: return consoleLogs
        case .logs: return consoleLogs.filter { $0.level == .log || $0.level == .info }
        case .warnings: return consoleLogs.filter { $0.level == .warn }
        case .errors: return consoleLogs.filter { $0.level == .error }
        }
    }

    var errorCount: Int { consoleLogs.filter { $0.level == .error }.count }
    var warnCount: Int { consoleLogs.filter { $0.level == .warn }.count }

    func reset() {
        consoleLogs = []
        networkRequests = []
        performance = PerformanceMetrics()
        inspectedElement = nil
    }

    /// Route a decoded message dictionary from the page.
    func ingest(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "console":
            let level = ConsoleLog.Level(rawValue: (message["level"] as? String) ?? "log") ?? .log
            consoleLogs.append(ConsoleLog(level: level,
                                          text: (message["text"] as? String) ?? "",
                                          timestamp: Date()))
        case "network":
            networkRequests.append(NetworkRequest(
                method: (message["method"] as? String) ?? "GET",
                url: (message["url"] as? String) ?? "",
                status: message["status"] as? Int,
                durationMs: message["duration"] as? Int,
                sizeBytes: message["size"] as? Int,
                timestamp: Date()))
        case "performance":
            performance = PerformanceMetrics(
                loadTimeMs: message["loadTime"] as? Int,
                domReadyMs: message["domReady"] as? Int,
                transferKB: message["transferKB"] as? Int)
        case "element":
            inspectedElement = InspectedElement(
                tag: (message["tag"] as? String) ?? "",
                elementID: (message["id"] as? String) ?? "",
                classes: (message["classes"] as? String) ?? "",
                selector: (message["selector"] as? String) ?? "",
                xpath: (message["xpath"] as? String) ?? "",
                styles: (message["styles"] as? String) ?? "")
        default:
            break
        }
    }
}

// MARK: - Message handler bridge

/// Bridges WKScriptMessageHandler callbacks into the main-actor inspector model.
final class InspectorMessageHandler: NSObject, WKScriptMessageHandler {
    private let model: WebInspectorModel

    init(model: WebInspectorModel) {
        self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "wcInspector",
              let body = message.body as? [String: Any] else { return }
        Task { @MainActor in
            model.ingest(body)
        }
    }
}

// MARK: - Injected JavaScript

/// The page-side instrumentation: captures console, network, performance, and
/// element inspection, forwarding everything to `window.webkit.messageHandlers`.
enum InspectorScript {

    static let source: String = #"""
    (function() {
      if (window.__wcInstalled) { return; }
      window.__wcInstalled = true;
      var send = function(obj) {
        try { window.webkit.messageHandlers.wcInspector.postMessage(obj); } catch (e) {}
      };
      var stringify = function(args) {
        return Array.prototype.map.call(args, function(a) {
          if (typeof a === 'object') { try { return JSON.stringify(a); } catch (e) { return String(a); } }
          return String(a);
        }).join(' ');
      };

      // Console capture
      ['log','info','warn','error'].forEach(function(level) {
        var original = console[level];
        console[level] = function() {
          send({ type: 'console', level: level, text: stringify(arguments) });
          if (original) { original.apply(console, arguments); }
        };
      });
      window.addEventListener('error', function(e) {
        send({ type: 'console', level: 'error', text: (e.message || 'error') + ' @ ' + (e.filename || '') + ':' + (e.lineno || '') });
      });

      // Fetch capture
      var originalFetch = window.fetch;
      window.fetch = function(input, init) {
        var url = (typeof input === 'string') ? input : (input && input.url) || '';
        var method = (init && init.method) || (typeof input === 'object' && input.method) || 'GET';
        var start = Date.now();
        return originalFetch.apply(this, arguments).then(function(resp) {
          var size = null;
          try { size = parseInt(resp.headers.get('content-length')) || null; } catch (e) {}
          send({ type: 'network', method: method, url: url, status: resp.status, duration: Date.now() - start, size: size });
          return resp;
        }).catch(function(err) {
          send({ type: 'network', method: method, url: url, status: 0, duration: Date.now() - start });
          throw err;
        });
      };

      // XHR capture
      var originalOpen = XMLHttpRequest.prototype.open;
      var originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__wc = { method: method, url: url, start: 0 };
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        var self = this;
        if (self.__wc) {
          self.__wc.start = Date.now();
          self.addEventListener('loadend', function() {
            var size = null;
            try { size = parseInt(self.getResponseHeader('content-length')) || null; } catch (e) {}
            send({ type: 'network', method: self.__wc.method, url: self.__wc.url, status: self.status, duration: Date.now() - self.__wc.start, size: size });
          });
        }
        return originalSend.apply(this, arguments);
      };

      // Performance capture
      var reportPerf = function() {
        try {
          var nav = performance.getEntriesByType('navigation')[0];
          var loadTime, domReady, transfer = null;
          if (nav) {
            loadTime = Math.round(nav.loadEventEnd - nav.startTime);
            domReady = Math.round(nav.domContentLoadedEventEnd - nav.startTime);
            transfer = nav.transferSize ? Math.round(nav.transferSize / 1024) : null;
          } else if (performance.timing) {
            var t = performance.timing;
            loadTime = t.loadEventEnd - t.navigationStart;
            domReady = t.domContentLoadedEventEnd - t.navigationStart;
          }
          send({ type: 'performance', loadTime: loadTime, domReady: domReady, transferKB: transfer });
        } catch (e) {}
      };
      if (document.readyState === 'complete') { setTimeout(reportPerf, 0); }
      else { window.addEventListener('load', function() { setTimeout(reportPerf, 0); }); }

      // Element inspection
      var inspectOn = false;
      var overlay = null;
      var ensureOverlay = function() {
        if (!overlay) {
          overlay = document.createElement('div');
          overlay.style.cssText = 'position:fixed;pointer-events:none;border:2px solid #33b8c7;background:rgba(51,184,199,0.15);z-index:2147483647;transition:all 0.05s;display:none;';
          document.documentElement.appendChild(overlay);
        }
        return overlay;
      };
      var selectorFor = function(el) {
        if (el.id) { return '#' + el.id; }
        var path = [];
        while (el && el.nodeType === 1 && el.tagName !== 'HTML') {
          var seg = el.tagName.toLowerCase();
          if (el.className && typeof el.className === 'string') { seg += '.' + el.className.trim().split(/\s+/).slice(0,2).join('.'); }
          path.unshift(seg);
          el = el.parentElement;
        }
        return path.join(' > ');
      };
      var xpathFor = function(el) {
        if (el.id) { return '//*[@id="' + el.id + '"]'; }
        var parts = [];
        while (el && el.nodeType === 1) {
          var index = 1;
          var sib = el.previousElementSibling;
          while (sib) { if (sib.tagName === el.tagName) { index++; } sib = sib.previousElementSibling; }
          parts.unshift(el.tagName.toLowerCase() + '[' + index + ']');
          el = el.parentElement;
        }
        return '/' + parts.join('/');
      };
      var onMove = function(e) {
        var o = ensureOverlay();
        var r = e.target.getBoundingClientRect();
        o.style.display = 'block';
        o.style.left = r.left + 'px'; o.style.top = r.top + 'px';
        o.style.width = r.width + 'px'; o.style.height = r.height + 'px';
      };
      var onClick = function(e) {
        e.preventDefault(); e.stopPropagation();
        var el = e.target;
        var cs = window.getComputedStyle(el);
        var styles = 'display:' + cs.display + '; position:' + cs.position + '; color:' + cs.color + '; background:' + cs.backgroundColor + '; font:' + cs.fontSize + ' ' + cs.fontFamily + '; margin:' + cs.margin + '; padding:' + cs.padding + ';';
        send({ type: 'element', tag: el.tagName.toLowerCase(), id: el.id || '', classes: (typeof el.className === 'string' ? el.className : ''), selector: selectorFor(el), xpath: xpathFor(el), styles: styles });
      };
      window.__wcSetInspect = function(on) {
        inspectOn = on;
        if (on) {
          document.addEventListener('mousemove', onMove, true);
          document.addEventListener('click', onClick, true);
        } else {
          document.removeEventListener('mousemove', onMove, true);
          document.removeEventListener('click', onClick, true);
          var o = ensureOverlay(); o.style.display = 'none';
        }
      };
    })();
    """#
}
